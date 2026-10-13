// swift-tools-version:5.9

import PackageDescription

/// Dynamic frameworks built by `make build platform=ios` + `scripts/make-dynamic.sh`.
let frameworks = [
    "Libmpv",
    "Libavcodec", "Libavfilter", "Libavformat", "Libavutil", "Libswresample", "Libswscale",
    "Libass", "Libdovi", "Libshaderc_combined", "MoltenVK",
]

let package = Package(
    name: "SpectaCommonLibraries",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "SpectaCommonLibraries", targets: frameworks),
    ],
    targets: frameworks.map { .binaryTarget(name: $0, path: "dist/dynamic/\($0).xcframework") }
)
