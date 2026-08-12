// swift-tools-version:5.9
//
//  Package.swift — SPM manifest for the pure headless core ONLY.
//  Module maturity: PROTOTYPE (slice GS-2)
//
//  Declares GlyphCore (library) + GlyphCoreTests (slice deliverable 1). The
//  render layer (Sources/Saver) and the dev preview host (Sources/PreviewApp)
//  are deliberately NOT SPM targets: they touch Metal/AppKit/ScreenSaver and are
//  compiled by scripts/build.sh (saver) and scripts/preview.sh (preview) via
//  swiftc, which also pulls in Sources/GlyphCore/*.swift so the same core
//  sources link into the GlyphSaver module. SPM only sees the declared target
//  paths, so those directories are ignored here.
//
//  Tests read the real data/ artifacts from disk (see TestSupport), so no
//  bundled resources are declared.
//

import PackageDescription

let package = Package(
    name: "GlyphCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GlyphCore", targets: ["GlyphCore"]),
    ],
    targets: [
        .target(name: "GlyphCore", path: "Sources/GlyphCore"),
        .testTarget(
            name: "GlyphCoreTests",
            dependencies: ["GlyphCore"],
            path: "Tests/GlyphCoreTests"
        ),
    ]
)
