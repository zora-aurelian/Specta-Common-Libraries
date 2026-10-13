# Specta-Common-Libraries

The LGPL media libraries used by Specta (mpv, FFmpeg and their dependencies), built as **dynamic
frameworks** for iOS and the iOS Simulator (arm64), with the scripts that produce them.

Forked from [MPVKit](https://github.com/mpvkit/MPVKit) 1.0.0, which in turn is based on
[kingslay/FFmpegKit](https://github.com/kingslay/FFmpegKit).

| Library | Version | Licence |
|---|---|---|
| mpv | 0.41.0 (`-Dgpl=false`) | LGPL-2.1-or-later |
| FFmpeg | n8.1.2 (shared, no `--enable-version3`) | LGPL-2.1-or-later |
| libplacebo | 7.360.1 | LGPL-2.1-or-later |
| libass (+ FreeType, FriBidi, HarfBuzz, libunibreak) | 0.17.5 | ISC (+ FTL, LGPL-2.1, MIT, zlib) |
| dav1d | 1.5.3 | BSD-2-Clause |
| Little CMS | 2.17 | MIT |
| uchardet | 0.0.8 | MPL-1.1 / GPL-2.0 / LGPL-2.1 |
| libdovi | 3.3.2 | MIT |
| MoltenVK | 1.4.2 | Apache-2.0 |
| shaderc | 2025.5.0 | Apache-2.0 |

## Differences from MPVKit

- Every library ships as a **dynamic** framework, so an app can use a rebuilt copy.
  Apache-2.0 components (MoltenVK, shaderc) are separate frameworks rather than folded into LGPL binaries.
- FFmpeg uses Apple's Secure Transport for TLS, so gnutls, nettle, gmp and OpenSSL are gone and
  FFmpeg stays LGPL-2.1-or-later.
- FFmpeg is patched to **verify TLS certificates by default** (`Sources/BuildScripts/patch/FFmpeg`).
- Removed: libbluray, uavs3d, libsmbclient, LuaJIT, libavdevice; FFmpeg's libass/libplacebo/Vulkan filters.
- iOS and Apple-silicon simulator only.

## Building

Requires Xcode, Homebrew, `meson ninja cmake nasm pkg-config wget`, and Rust (`rustup`).

```bash
make build platform=ios            # FFmpeg + mpv from source; other deps as prebuilt static libraries
./scripts/make-dynamic.sh          # → dist/dynamic/*.xcframework
```

`make build platform=ios skip-built` reuses libraries that are already built.

The root `Package.swift` exposes `dist/dynamic` as a local Swift package (`SpectaCommonLibraries`).

## Licence

The build scripts are LGPL-3.0 (inherited from MPVKit; see `LICENSE`). Each library keeps its own licence.
