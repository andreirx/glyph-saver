#!/usr/bin/env bash
# preview.sh — build & run the dev PreviewApp (slice GS-2, deliverable 6)
# Module maturity: PROTOTYPE
#
# DEV TOOL ONLY (docs/PLAN.md "Test hosts"): the same GlyphSaverView + ZapRenderer
# the saver ships, hosted in a resizable NSWindow for live watching. NOT shipped
# in the .saver, NOT acceptance evidence — the gates are `swift test`, build.sh,
# and verify.sh.
#
# Like build.sh, this compiles with swiftc and MUST NOT invoke the `metal` tool
# (shaders compile at runtime). Sources/GlyphCore is compiled straight in (it is
# an SPM library only for `swift test`). Bundle resources are staged next to the
# binary so GlyphSaverView's Bundle(for:) → Bundle.main resolves them exactly as
# it would inside the .saver.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mkdir -p build

echo "==> Stage bundle resources next to the preview binary"
cp Sources/Saver/Shaders.metal build/
cp assets/vbg_1024.jpg build/
cp assets/vbg_1024_normals.png build/
cp data/glyphs_baked.json data/sayings.json build/

echo "==> Compile PreviewApp + Sources/Saver + Sources/GlyphCore -> build/preview"
swiftc -O \
	-o build/preview \
	Sources/PreviewApp/main.swift \
	Sources/Saver/*.swift \
	Sources/GlyphCore/*.swift \
	-module-name GlyphSaverPreview \
	-framework ScreenSaver \
	-framework AppKit \
	-framework Metal \
	-framework MetalKit \
	-framework QuartzCore \
	-framework CoreGraphics \
	-target arm64-apple-macos14

echo "==> Run preview (close the window or Ctrl-C to quit)"
exec build/preview
