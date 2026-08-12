#!/usr/bin/env bash
# build.sh — compile Sources/Saver into build/GlyphSaver.saver
# Module maturity: PROTOTYPE (slice GS-1)
#
# Shaders are shipped as SOURCE and compiled at RUNTIME (see docs/PLAN.md).
# This script MUST NOT invoke the `metal` tool — it is not on PATH here.
set -euo pipefail

# Resolve repo root from this script's location (scripts/..).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="build/GlyphSaver.saver"
MACOS="$OUT/Contents/MacOS"
RES="$OUT/Contents/Resources"

echo "==> Clean bundle tree"
rm -rf "$OUT"
mkdir -p "$MACOS" "$RES"

echo "==> Compile Sources/Saver/*.swift + Sources/GlyphCore/*.swift -> $MACOS/GlyphSaver"
# The pure core (Sources/GlyphCore) is an SPM library for `swift test`, but the
# saver is built by swiftc (no build-time Metal toolchain, PLAN.md), so the same
# core sources are compiled straight into the GlyphSaver module here.
swiftc -emit-library \
	-o "$MACOS/GlyphSaver" \
	Sources/Saver/*.swift \
	Sources/GlyphCore/*.swift \
	-module-name GlyphSaver \
	-framework ScreenSaver \
	-framework AppKit \
	-framework Metal \
	-framework MetalKit \
	-framework QuartzCore \
	-framework CoreGraphics \
	-target arm64-apple-macos14

echo "==> Copy Info.plist"
cp Sources/Saver/Info.plist "$OUT/Contents/Info.plist"

echo "==> Copy shader source, textures, data into Resources"
cp Sources/Saver/Shaders.metal "$RES/"
cp assets/vbg_1024.jpg "$RES/"
cp assets/vbg_1024_normals.png "$RES/"
cp data/*.json "$RES/"

# --- Thumbnail (deliverable 7): the Settings grid shows a STATIC bundle asset
#     (GS-1 field finding), but a brand-true one — rendered from the real view.
#     Render one frame from the just-built bundle in-process (same load path as
#     verify_host; NOT ScreenSaverEngine), then downsample with `sips`.
echo "==> Generate thumbnail.png / thumbnail@2x.png from a rendered frame"
THUMB_HOST="build/thumbnail_host"
THUMB_SRC="build/thumbnail-src.png"
clang -fobjc-arc -O2 \
	-framework Foundation \
	-framework AppKit \
	-framework ScreenSaver \
	-framework CoreGraphics \
	-framework ImageIO \
	-o "$THUMB_HOST" scripts/thumbnail_host.m
"$THUMB_HOST" "$OUT" "$THUMB_SRC" 2.0
# 16:10 tiles: @2x = 320×200, @1x = 160×100 (sips -z is height then width).
sips -z 200 320 "$THUMB_SRC" --out "$RES/thumbnail@2x.png" >/dev/null
sips -z 100 160 "$THUMB_SRC" --out "$RES/thumbnail.png"    >/dev/null

echo "==> Verify required artifacts exist"
for f in \
	"$MACOS/GlyphSaver" \
	"$OUT/Contents/Info.plist" \
	"$RES/Shaders.metal" \
	"$RES/vbg_1024.jpg" \
	"$RES/vbg_1024_normals.png" \
	"$RES/glyphs_baked.json" \
	"$RES/sayings.json" \
	"$RES/thumbnail.png" \
	"$RES/thumbnail@2x.png"; do
	if [[ ! -f "$f" ]]; then
		echo "BUILD FAILED: missing $f" >&2
		exit 1
	fi
done

echo "==> Built $OUT"
