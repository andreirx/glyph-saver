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

echo "==> Compile Sources/Saver/*.swift -> $MACOS/GlyphSaver"
swiftc -emit-library \
	-o "$MACOS/GlyphSaver" \
	Sources/Saver/*.swift \
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

echo "==> Verify required artifacts exist"
for f in \
	"$MACOS/GlyphSaver" \
	"$OUT/Contents/Info.plist" \
	"$RES/Shaders.metal" \
	"$RES/vbg_1024.jpg" \
	"$RES/vbg_1024_normals.png"; do
	if [[ ! -f "$f" ]]; then
		echo "BUILD FAILED: missing $f" >&2
		exit 1
	fi
done

echo "==> Built $OUT"
