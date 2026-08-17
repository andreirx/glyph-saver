#!/usr/bin/env bash
# test.sh — the `swift test` gate for GlyphCore (slice GS-2, deliverable per
# OPERATOR_NOTE 2026-08-12).
# Module maturity: PROTOTYPE
#
# WHY THIS WRAPPER EXISTS (operator-verified environment fact):
# `xcode-select` on this machine points at the Command Line Tools, whose
# toolchain ships NEITHER XCTest NOR swift-testing — a bare `swift test` FAILS
# (or, worse, reports "0 tests in 0 suites", a false green). The full Xcode at
# /Applications/Xcode.app DOES carry both frameworks. Rather than switch the
# global toolchain (`sudo xcode-select -s …`, a machine-wide side effect), we
# scope Xcode to THIS command only via DEVELOPER_DIR, which `swift`/`xcrun`
# honor as an override of the selected developer dir. Nothing else on the
# machine changes.
#
# Run BARE and check the exit code — never pipe this gate (CLAUDE.md Gates).
# Extra args pass through (e.g. scripts/test.sh --filter GlyphSetTests).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# PORTABILITY (2026-08-17): resolve a toolchain that carries XCTest instead of
# hardcoding this machine's Xcode path. Order: explicit $DEVELOPER_DIR wins;
# else the xcode-selected dir IF it is a full Xcode (has Platforms/ — the CLT
# does not); else the conventional /Applications/Xcode.app; else fail loudly.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    sel="$(xcode-select -p 2>/dev/null || true)"
    if [ -n "$sel" ] && [ -d "$sel/Platforms" ]; then
        DEVELOPER_DIR="$sel"
    elif [ -d "/Applications/Xcode.app/Contents/Developer/Platforms" ]; then
        DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    else
        echo "ERROR: 'swift test' needs a full Xcode toolchain (XCTest); the" >&2
        echo "Command Line Tools alone are not enough. Install Xcode, or set" >&2
        echo "DEVELOPER_DIR to a full Xcode's Contents/Developer." >&2
        exit 1
    fi
fi

exec env DEVELOPER_DIR="$DEVELOPER_DIR" swift test "$@"
