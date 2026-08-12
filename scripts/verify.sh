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
#   (c) render 2 frames THROUGH the real GlyphSaverView instance (its @objc
#       verification seam) into build/*.png. GS-4: the schedule seed is PINNED
#       (GLYPHSAVER_SEED) so the two frames land on KNOWN content of the first
#       proverb ("Better late than never", seed 7, 960×600 world):
#         t=19.3 s — CELEBRATION: a letter completed at 19.00 s, so its gold flood
#                    + 25-spark burst are active (0.3 s into the 1.2 s window);
#         t=51.6 s — FINALE DISSOLVE: dissolve window is [50.70, 53.20), so the
#                    ignited HDR ink is fading while fireworks emit along the
#                    stroke paths.
#       (Times derived from the pure WritingClock/finale schedule; see the GS-4
#        build report. The live saver is unpinned — random per session.)
#   (d) fail if the two schedule frames are byte-identical (writing vs finale must
#       differ).
#   NOTE: the former width-pair artifact (verify-width28.png) is RETIRED — it was
#   decision evidence; the human picked 28u on 2026-08-12 and 28 is now the
#   default (see PLAN). The width-override seam remains in verify_host for any
#   future width question.
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

rm -f "$OUT1" "$OUT2" build/verify-width28.png

echo "==> (b) Loadtest the installed bundle; (c) render a celebration frame (t=19.3 s)"
echo "        and a finale-dissolve frame (t=51.6 s), schedule seed PINNED to 7."
GLYPHSAVER_SEED=7 "$HOST_BIN" "$SAVER" "$OUT1" "$OUT2" 19.3 51.6

echo "==> (c) Assert both frames were written"
if [[ ! -s "$OUT1" || ! -s "$OUT2" ]]; then
	echo "VERIFY FAILED: a frame is missing/empty ($OUT1, $OUT2)" >&2
	exit 1
fi

echo "==> (d) Assert the two schedule frames differ (writing progressed / camera moved)"
if cmp -s "$OUT1" "$OUT2"; then
	echo "VERIFY FAILED: $OUT1 and $OUT2 are byte-identical — the writing did not advance" >&2
	exit 1
fi


echo "==> VERIFY OK: loadtest passed; $OUT1 and $OUT2 differ."
echo "    Operator judges these PNGs + the installed saver in System Settings >"
echo "    Screen Saver (preview + full screen)."
