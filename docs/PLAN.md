# Glyph Saver — Implementation Plan

Status: RATIFIED 2026-08-11 (rendering approach + proverb set ratified by human;
slice structure ratified with the plan). This is the `sliceDoc` for slices
GS-1…GS-4 — implementation slices reference this pre-ratified plan; they do not
re-open its decisions.

## Toolchain (verified on this machine, 2026-08-11)

- macOS 26.6.1, arm64. Swift 6.2.3 via Command Line Tools
  (`/Library/Developer/CommandLineTools`). `lipo`, `codesign` present (unused
  in v1). No full Xcode needed — manual `swiftc` build.
- Deployment target: `arm64-apple-macos14`. arm64-only (v1 runs on this
  machine only; universal is a named extension, not built).
- macOS 26 hosts third-party savers via `legacyScreenSaver`; after each
  install: `killall legacyScreenSaver ScreenSaverEngine` to drop the mmap'd
  old bundle.

## Architecture (minimal, earned)

Two layers, one boundary:

```
GlyphCore  (SPM library target — pure Swift, Foundation + CoreGraphics only)
  GlyphSet      parse data/glyphs_baked.json; variant/exit/width queries
                (port of glyphs.rs semantics, verified against source)
  ProverbLayout wrap a proverb into positioned, variant-resolved glyphs
                (width classes ×0.5/×1.0/×1.3, word gap 0.5, centered block)
  WritingClock  pure timeline: (elapsed time) → (which strokes are fully
                inked, current stroke, pen arc-length progress, phase:
                writing|holding|fading)

GlyphSaverView (single file, AppKit + ScreenSaver — NOT in the SPM test path)
  ScreenSaverView subclass: owns a WritingClock, renders GlyphCore output
  with CoreGraphics in draw(_:), advances in animateOneFrame.
```

- **The boundary is earned by the test seam**: business logic (layout, variant
  selection, timing) must be provable by `swift test` with no GUI host
  (VISION constraint 2). SPM exists *only* to make the core testable; the
  `.saver` bundle itself is produced by `scripts/build.sh` compiling
  GlyphCore sources + `GlyphSaverView.swift` with one `swiftc` invocation.
  Axis of variation: none claimed — this is a seam, not a plug point.
  Simpler alternative rejected: one flat module with no tests (violates
  VISION constraint 2).
- No other abstractions. No renderer protocol (one renderer), no provider
  layer (no providers), no config layer (no config).

## Repository layout

```
glyph-saver/
  Package.swift            SPM: GlyphCore + GlyphCoreTests only
  Sources/GlyphCore/       pure core (see above)
  Sources/Saver/           GlyphSaverView.swift + Info.plist
  Tests/GlyphCoreTests/
  data/                    glyphs_baked.json, sayings.json (files of record)
  scripts/build.sh         swiftc → GlyphSaver.saver into build/
  scripts/install.sh       cp to ~/Library/Screen Savers + killall reload
  docs/                    VISION.md, PLAN.md (this file)
  build/                   gitignored output
```

## Gates (every slice)

Run bare — never piped — and checked individually:

1. `swift test` (GlyphCore)
2. `scripts/build.sh` exits 0 and produces `build/GlyphSaver.saver`
3. The slice's named **output surface** demonstrably renders (operator
   installs and looks — the saver preview in System Settings and/or full
   screen). Deep-vertical rule: no slice ships dormant capability.

## Slices

### GS-1 — Bundle skeleton: static strokes on screen (PROTOTYPE)

Everything mechanical, plus real data on screen. Deliverables:

- `Package.swift`, `GlyphSet` (Codable parse of `glyphs_baked.json` +
  `variant_for`/exit/width queries with the word-start-High override), tests
  for parse + variant rule (the cursive table from VISION is the test oracle).
- `Sources/Saver/GlyphSaverView.swift`: black background, draws ONE hardcoded
  proverb's strokes fully inked (no animation, naive layout: standard advance
  only, single line) as white CoreGraphics polylines.
- `Info.plist` (`NSPrincipalClass` = `GlyphSaverView`, `@objc(GlyphSaverView)`
  on the class), `scripts/build.sh`, `scripts/install.sh`.
- Data JSONs copied into the bundle's `Contents/Resources` by build.sh and
  loaded via `Bundle(for:)`.

Output surface: the installed saver shows the hardcoded proverb in System
Settings preview and full screen. Proves plist/principal-class/bundle/
resource-loading/install/reload end-to-end.

### GS-2 — Layout engine (PROTOTYPE → MATURE on approval)

- `ProverbLayout`: word-wrap by glyph advances (width classes ×0.5/×1.0/×1.3
  of 600-unit base box; word gap 0.5 × standard advance; no hyphenation —
  break only at spaces), lines centered as a block, block centered in view,
  uniform scale chosen so the widest line + margins fit the view.
- Variant resolution across the proverb (prev-exit chain + word-start rule)
  lives here, so the view never decides variants.
- Tests: advance arithmetic, wrap points, variant chain over real sayings;
  property: every character of all 31 sayings resolves to an existing glyph
  variant (coverage proof).
- View renders any saying statically correct.

Output surface: full proverbs, wrapped and centered, rendered statically.

### GS-3 — The writing animation (PROTOTYPE → MATURE on approval)

- `WritingClock`: pure function of elapsed time. Arc-length parameterize each
  stroke; pen advances at constant speed (start from the game's 60 units/s in
  glyph space, scaled; expose as one named constant). Strokes in authored
  order; letters in reading order. Phases: writing → holding (~10 s) →
  fade-out (~1 s) → next proverb (uniform random, no immediate repeat).
- View: partial-stroke rendering (ink up to pen position), pen-tip dot
  (game draws a bright tip circle), `animationTimeInterval = 1/30`.
- Tests: clock phase transitions, monotonic ink progress, no-repeat pick.

Output surface: the actual screensaver behavior — watchable writing loop.

### GS-4 — Ink aesthetic & polish (PROTOTYPE → MATURE on approval)

- Translate the game's HDR-bloom look to SDR CoreGraphics: layered stroking
  (wide, low-alpha halo pass under a narrow, bright core pass) — chosen over
  CGContext shadow blur (cost scales badly at full-screen stroke counts;
  operator decision, revisit only if the halo looks wrong).
- Gold completion pulse per letter (width 8→20-equivalent, ~1 s decay), the
  game's near-black background, settled-ink color.
- `isPreview` check: same rendering, layout already scale-invariant; verify
  the System Settings thumbnail is legible.

Output surface: side-by-side with the web game — the saver reads as Glypher.

### GS-RO — Romanian proverbs (DEFERRED — human authoring required)

Named extension, not scheduled. See VISION. Blocked on a glyph-editor
authoring session for `ă â î ș ț` (+ punctuation) and a re-export.

## Slice → relay mapping

Bootstrapped per the agent-manager target-owned-relay contract:
`.agent-manager/slices/GS-<n>/{selection.md,selection.json,status.json}`,
phase `implement`, builder claude / supervisor codex (defaults:
`claude-opus-4-8` high / `gpt-5.6-terra`). Run from agent-manager:

```
npm run relay-target -- ../glyph-saver --slice GS-1 --max-iter 3
```

`sliceDoc` for all GS slices = `docs/PLAN.md` (this pre-ratified plan) — these
are IMPL slices; the decision-review phase must NOT fire on them (they surface
no new ratification-class decisions; if one does, that is an `escalate`).
Checkpoint cadence: `--max-iter 3` per operator practice; operator reviews,
commits the deliverable, bootstraps the next slice.

## Deliberately deferred (recorded, not designed for)

- Universal binary, codesign/notarization (leaves-this-machine trigger).
- Configure sheet (second-user trigger).
- Proverb-set growth beyond `sayings.json` edits (any addition must pass the
  GS-2 coverage property test).
