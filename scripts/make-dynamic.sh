#!/bin/bash
# Turns the static libraries produced by `make build platform=ios` into dynamic frameworks.
#
# Every LGPL component (FFmpeg, mpv, libplacebo, fribidi, uchardet) ends up inside a dynamic
# framework, so an app that links them can have them replaced with a rebuilt copy. Apache-2.0
# components (MoltenVK, shaderc) get frameworks of their own rather than being folded into
# LGPL-2.1 binaries.
#
# Output: dist/dynamic/<Name>.xcframework
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
OUT="$DIST/dynamic"
WORK="$DIST/dynamic-work"
MIN_IOS="15.0"
VERSION="${VERSION:-1.0.0}"

rm -rf "$OUT" "$WORK"
mkdir -p "$OUT" "$WORK/static"

# The static build leaves only the newest library's xcframework unzipped, so unpack the
# release zips to get every library's headers and module map.
for zip in "$DIST"/release/*.xcframework.zip; do
    unzip -q -o "$zip" -d "$WORK/static"
done

# platform → sdk, clang target, Info.plist platform, xcframework slice
sdk_for() { [ "$1" = ios ] && echo iphoneos || echo iphonesimulator; }
target_for() { [ "$1" = ios ] && echo "arm64-apple-ios$MIN_IOS" || echo "arm64-apple-ios$MIN_IOS-simulator"; }
plist_platform_for() { [ "$1" = ios ] && echo iPhoneOS || echo iPhoneSimulator; }
slice_for() { [ "$1" = ios ] && echo ios-arm64 || echo ios-arm64-simulator; }

# Static archive for library/platform, thinned to arm64 when the download is fat.
archive() {
    local library="$1" platform="$2" file="$3"
    local path="$DIST/$library/$platform/thin/arm64/lib/$file"
    [ -f "$path" ] || { echo "missing $path" >&2; exit 1; }
    if lipo -info "$path" | grep -q "Architectures in the fat file"; then
        local thin="$WORK/thin/$platform/$library-$file"
        mkdir -p "$(dirname "$thin")"
        [ -f "$thin" ] || lipo -thin arm64 "$path" -output "$thin"
        path="$thin"
    fi
    if [ "$library" = libshaderc ]; then
        # The prebuilt archive hides its C API; export it so libplacebo can link against it.
        local exported="$WORK/thin/$platform/exported-$file"
        mkdir -p "$(dirname "$exported")"
        if [ ! -f "$exported" ]; then
            python3 -I "$ROOT/scripts/export-symbols.py" "$path" "$exported" _shaderc_ >&2
            xcrun ranlib "$exported" 2>/dev/null
        fi
        path="$exported"
    fi
    echo "$path"
}

# Ad-hoc sign the bundle so the signing identifier matches CFBundleIdentifier; Xcode keeps the
# identifier when it re-signs embedded frameworks, and iOS rejects a mismatch at install.
sign_bundle() { codesign --force --sign - "$1" 2>&1 | grep -v "replacing existing signature" || true; }

write_plist() {
    local name="$1" platform="$2" dest="$3"
    cat > "$dest/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$name</string>
    <key>CFBundleIdentifier</key><string>app.specta.common.$(echo "$name" | tr -cd '[:alnum:]-')</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleSupportedPlatforms</key><array><string>$(plist_platform_for "$platform")</string></array>
    <key>MinimumOSVersion</key><string>$MIN_IOS</string>
</dict>
</plist>
EOF
}

# Headers and module map: reuse the ones the static build generated, or build an umbrella
# module over an include directory.
copy_headers() {
    local name="$1" platform="$2" dest="$3" headers="$4"
    case "$headers" in
        "") return ;;
        static)
            local xcf="$WORK/static/$name.xcframework" src
            if [ "$platform" = ios ]; then src="$xcf/ios-arm64/$name.framework"
            else src="$(ls -d "$xcf"/ios-*-simulator/"$name.framework" | head -1)"; fi
            cp -R "$src/Headers" "$dest/Headers"
            cp -R "$src/Modules" "$dest/Modules"
            ;;
        include:*)
            cp -R "$DIST/${headers#include:}/$platform/thin/arm64/include" "$dest/Headers"
            mkdir -p "$dest/Modules"
            printf 'framework module %s [system] {\n    umbrella "."\n    export *\n}\n' "$name" > "$dest/Modules/module.modulemap"
            ;;
    esac
}

# make_framework <Name> <headers> <archives: library:file ...> -- <dependent frameworks ...> -- <system link flags ...>
make_framework() {
    local name="$1" headers="$2"; shift 2
    local archives=() deps=() system=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do archives+=("$1"); shift; done; shift
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do deps+=("$1"); shift; done; shift
    system=("$@")

    local slices=()
    for platform in ios isimulator; do
        local fw="$WORK/$platform/$name.framework"
        mkdir -p "$fw"
        local load=()
        for spec in "${archives[@]}"; do
            load+=("-Wl,-force_load,$(archive "${spec%%:*}" "$platform" "${spec#*:}")")
        done
        local link=()
        for dep in ${deps[@]+"${deps[@]}"}; do link+=(-framework "$dep"); done

        echo "→ $name ($platform)"
        xcrun --sdk "$(sdk_for "$platform")" clang -dynamiclib \
            -target "$(target_for "$platform")" \
            -install_name "@rpath/$name.framework/$name" \
            -compatibility_version 1 -current_version "$VERSION" \
            -Wl,-headerpad_max_install_names -Wl,-dead_strip \
            -F "$WORK/$platform" \
            "${load[@]}" ${link[@]+"${link[@]}"} ${system[@]+"${system[@]}"} \
            -o "$fw/$name"
        xcrun strip -x "$fw/$name"
        write_plist "$name" "$platform" "$fw"
        copy_headers "$name" "$platform" "$fw" "$headers"
        sign_bundle "$fw"
        slices+=(-framework "$fw")
    done
    xcodebuild -create-xcframework "${slices[@]}" -output "$OUT/$name.xcframework" > /dev/null
}

# wrap_ffmpeg <Name>: FFmpeg's own shared build hides its internal ff_* symbols and duplicates
# the tables each library needs, so its dylibs are wrapped as-is rather than relinked.
wrap_ffmpeg() {
    local name="$1" lib="lib${1#Lib}"
    local slices=()
    for platform in ios isimulator; do
        local libdir="$DIST/FFmpeg/$platform/thin/arm64/lib"
        local fw="$WORK/$platform/$name.framework"
        mkdir -p "$fw"
        echo "→ $name ($platform)"
        cp -L "$libdir/$lib.dylib" "$fw/$name"
        chmod u+w "$fw/$name"
        install_name_tool -id "@rpath/$name.framework/$name" "$fw/$name"
        # Point references to sibling FFmpeg dylibs at their frameworks.
        otool -L "$fw/$name" | awk 'NR > 1 {print $1}' | { grep "^$libdir/" || true; } | while read -r dep; do
            local base="$(basename "$dep")"; base="${base%%.*}"
            local depName="Lib${base#lib}"
            install_name_tool -change "$dep" "@rpath/$depName.framework/$depName" "$fw/$name"
        done
        write_plist "$name" "$platform" "$fw"
        copy_headers "$name" "$platform" "$fw" static
        sign_bundle "$fw"
        slices+=(-framework "$fw")
    done
    xcodebuild -create-xcframework "${slices[@]}" -output "$OUT/$name.xcframework" > /dev/null
}

CXX=(-lc++)

# Leaves first: each framework may only link frameworks built before it.
make_framework MoltenVK "" vulkan:libMoltenVK.a -- -- \
    -framework CoreFoundation -framework CoreGraphics -framework Foundation -framework IOSurface \
    -framework Metal -framework QuartzCore -framework UIKit "${CXX[@]}"

make_framework Libshaderc_combined "" libshaderc:libshaderc_combined.a -- -- "${CXX[@]}"

make_framework Libdovi include:libdovi libdovi:libdovi.a -- -- -liconv

make_framework Libass "" \
    libass:libass.a libfreetype:libfreetype.a libfribidi:libfribidi.a \
    libharfbuzz:libharfbuzz.a libunibreak:libunibreak.a -- -- \
    -framework CoreText -framework CoreFoundation -framework CoreGraphics -liconv -lz -lbz2 "${CXX[@]}"

for name in Libavutil Libswresample Libswscale Libavcodec Libavformat Libavfilter; do
    wrap_ffmpeg "$name"
done

make_framework Libmpv static \
    libmpv:libmpv.a libplacebo:libplacebo.a lcms2:liblcms2.a libuchardet:libuchardet.a -- \
    Libavfilter Libavformat Libavcodec Libswscale Libswresample Libavutil Libass Libdovi Libshaderc_combined MoltenVK -- \
    -framework AVFoundation -framework AudioToolbox -framework CoreAudio -framework CoreMedia -framework CoreVideo \
    -framework CoreFoundation -framework Foundation -framework Metal -framework QuartzCore -framework UIKit \
    -framework OpenGLES -framework IOSurface -framework VideoToolbox -liconv -lz "${CXX[@]}"

echo
echo "Dynamic frameworks in $OUT:"
ls "$OUT"
