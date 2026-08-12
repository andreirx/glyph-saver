#!/usr/bin/env bash
# install.sh — install build/GlyphSaver.saver for visual verification
# Module maturity: PROTOTYPE (slice GS-1)
#
# Operator step. macOS 26 hosts third-party savers via legacyScreenSaver;
# killing the host processes forces a reload of the freshly copied bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC="build/GlyphSaver.saver"
DEST_DIR="$HOME/Library/Screen Savers"

if [[ ! -d "$SRC" ]]; then
	echo "install FAILED: $SRC not found — run scripts/build.sh first" >&2
	exit 1
fi

mkdir -p "$DEST_DIR"
rm -rf "$DEST_DIR/GlyphSaver.saver"
cp -R "$SRC" "$DEST_DIR/"
echo "==> Installed to $DEST_DIR/GlyphSaver.saver"

killall legacyScreenSaver ScreenSaverEngine 2>/dev/null || true
echo "==> Reloaded screen saver host processes"
