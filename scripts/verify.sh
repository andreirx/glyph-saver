#!/usr/bin/env bash
# verify.sh — GS-1 layered evidence gate (replaces the retired smoke.sh)
# Module maturity: PROTOTYPE (slice GS-1)
#
# The ratified acceptance for GS-1 (docs/PLAN.md "Test hosts", operator note
# 2026-08-12: layered evidence). This script does NOT launch ScreenSaverEngine
# and does NOT call `screencapture` — both are unusable on macOS 26 here (direct
# engine exec is SIGKILLed by launch constraints; any human input dismisses a
# LaunchServices-launched saver). Instead:
#
#   (a) install the freshly-built bundle;
#   (b) LOADTEST — Bundle(path:)-load the INSTALLED bundle, resolve the
#       principal class, and instantiate it via -initWithFrame:isPreview:
#       (the engine's exact dyld/class/init path), all in scripts/verify_host.m;
#   (c) render >=2 frames a few animation-seconds apart THROUGH the real
#       GlyphSaverView instance (its @objc verification seam) into build/*.png;
#   (d) fail if the two frames are byte-identical (the light must have moved).
#
# Exit nonzero on any failure; the operator then judges the two PNGs and the
# installed saver in System Settings preview (the surfaces automation cannot
# reach). Run bare, check the exit code — never pipe this gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SAVER="$HOME/Library/Screen Savers/GlyphSaver.saver"
HOST_SRC="scripts/verify_host.m"
HOST_BIN="build/verify_host"
OUT1="build/verify-1.png"
OUT2="build/verify-2.png"

echo "==> (a) Install the freshly-built bundle"
scripts/install.sh
if [[ ! -d "$SAVER" ]]; then
	echo "VERIFY FAILED: installed bundle not found at $SAVER" >&2
	exit 1
fi

echo "==> Compile the loadtest+capture host ($HOST_SRC)"
mkdir -p build
clang -fobjc-arc -O2 \
	-framework Foundation \
	-framework AppKit \
	-framework ScreenSaver \
	-framework CoreGraphics \
	-framework ImageIO \
	-o "$HOST_BIN" "$HOST_SRC"

rm -f "$OUT1" "$OUT2"

echo "==> (b) Loadtest the installed bundle; (c) render two frames through the real view"
"$HOST_BIN" "$SAVER" "$OUT1" "$OUT2"

echo "==> (c) Assert both frames were written"
if [[ ! -s "$OUT1" || ! -s "$OUT2" ]]; then
	echo "VERIFY FAILED: one or both frames missing/empty ($OUT1, $OUT2)" >&2
	exit 1
fi

echo "==> (d) Assert the two frames differ (moving guide light)"
if cmp -s "$OUT1" "$OUT2"; then
	echo "VERIFY FAILED: $OUT1 and $OUT2 are byte-identical — the light did not move" >&2
	exit 1
fi

echo "==> VERIFY OK: loadtest passed; $OUT1 and $OUT2 differ."
echo "    Operator judges these two PNGs + the installed saver in"
echo "    System Settings > Screen Saver (preview + full screen)."
