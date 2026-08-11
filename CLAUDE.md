# Glyph Saver — Project Instructions

## Read order

1. `docs/VISION.md` — what this is, ratified behavior, source lineage, constraints
2. `docs/PLAN.md` — architecture, slices, gates (the ratified implementation plan)
3. This file — execution rules

## Hard constraints

1. **Core stays headless.** `Sources/GlyphCore/` imports Foundation and
   CoreGraphics ONLY — never AppKit, never ScreenSaver. All layout, glyph, and
   timing logic lives there and is proven by `swift test`. Only
   `Sources/Saver/GlyphSaverView.swift` may touch AppKit/ScreenSaver.
2. **`data/glyphs_baked.json` is a generated artifact — never hand-edit.** It
   is exported by the zap-engine glyph editor. If it seems wrong, stop and
   surface it; do not patch it.
3. **Behavioral reference is the game source**, not memory of it:
   `../zap-engine/examples/glypher/src/{glyphs.rs, game.rs}`. When porting a
   rule (variant selection, widths, word gap, celebration), read the Rust and
   cite the line in your build report. VISION.md lists the verified facts.
4. **Self-contained bundle.** The built `.saver` contains everything it needs.
   No network, no file access outside the bundle at runtime.
5. **No new abstractions without the plan naming them.** The architecture in
   PLAN.md (GlyphCore + one view file) is the whole design. A renderer
   protocol, a config layer, a second module — any of these is out of scope
   unless a ratified slice adds it.
6. **Do not commit.** The operator commits deliverables after review approval.

## Gates (run bare, check each exit code — never pipe a gate)

```
swift test
scripts/build.sh        # must produce build/GlyphSaver.saver
```

Install for visual verification (operator step):

```
scripts/install.sh      # cp to ~/Library/Screen Savers + killall legacyScreenSaver ScreenSaverEngine
```

## Module maturity

Everything starts PROTOTYPE. A slice's modules move to MATURE when the
operator commits its approved deliverable. Declare maturity in each file's
header comment.

## Storage

Tracked: `Sources/`, `Tests/`, `data/`, `docs/`, `scripts/`, `Package.swift`.
Gitignored: `build/`, `.build/`, `.agent-manager/` (relay working state),
`.DS_Store`.
