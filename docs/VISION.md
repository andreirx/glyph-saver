# Glyph Saver — Vision

## What this is

A native macOS screensaver (`.saver` bundle) that writes proverbs on screen in
**handwriting** — an invisible pen draws each letter stroke by stroke, letter by
letter, until the whole proverb stands on screen, holds, then a new random
proverb begins.

It is the contemplative, non-interactive form of **Glypher**
(`zap-engine/examples/glypher`), the tracing game where the player writes each
letter by hand. The screensaver keeps Glypher's soul — the hand-authored glyph
strokes, the cursive flow between letters, the ink-and-glow aesthetic — and
removes the player. The machine writes; you watch.

## What it is NOT

- **Not a port of zap-engine.** No Rust, no WASM, no WebGPU, no web view. The
  engine is irrelevant to this effect; only the *data* and the *aesthetic*
  carry over. (Ratified 2026-08-11: stroke-drawn handwriting chosen over a
  Core Text typewriter precisely because the data ports and the engine doesn't
  need to.)
- **Not a generic quote screensaver.** If it rendered text with a font it would
  not be this product. The letters are *drawn*, along the same stroke paths a
  player would trace in the game.
- **Not configurable (v1).** No configure sheet, no options. One saver, one
  proverb set, one look.
- **Not distributed (v1).** Personal use on the author's machine. No signing,
  no notarization, no universal binary. All three are named extension points,
  not requirements.

## Source lineage (files of record)

| File | Origin | Contract |
|------|--------|----------|
| `data/glyphs_baked.json` | Exported by the zap-engine glyph editor ("Download Baked"), copied 2026-08-11 from `zap-engine/examples/glypher/data/`. | **Generated artifact — never hand-edit.** Changes go through the glyph editor and a re-export. Format: per-character stroke polylines with entry variants (`Baseline`/`High`), exit types, and width classes (0 narrow / 1 standard / 2 wide). Covers exactly `a–z A–Z 0–9` — 62 glyphs, no punctuation, no diacritics. |
| `data/sayings.json` | Copied 2026-08-11 from the same place. | Flat JSON array of 31 proverbs, authored to be renderable by the 62-glyph set (letters + spaces only). Kept verbatim, including the one French tongue-twister — game parity. Hand-editable: any added proverb must use only covered characters. |

The behavioral reference is the game source itself:
`zap-engine/examples/glypher/src/{glyphs.rs, game.rs}` — variant selection,
width classes, word-gap, and the celebration look are *specified by that code*,
not by memory of it. Key facts, verified 2026-08-11:

- Glyph box: 600 × 480 units; width classes scale box width ×0.5 / ×1.0 / ×1.3.
- Word gap: 0.5 × a standard character advance. Spaces are gaps, not glyphs.
- Cursive variant rule: lowercase letters have `Baseline` and `High` entry
  variants; the *previous* letter's exit type picks the entry
  (`glyphs.rs::variant_for`). High-exit letters: `b o v w`. Override: at word
  start, `m n v w` use `High` (`game.rs::effective_variant`).
- Pen speed in the game: `GUIDE_SPEED = 60` world-units/s in an 800×600 world.
- Ink colors are HDR-ish values that rely on the engine's bloom
  (traced ink `(0.2, 2.5, 0.5)`, gold completion pulse `(8t, 6.8t, 2.4t)` with
  stroke width animating 8→20). The saver must *translate* this look to plain
  CoreGraphics, not copy the numbers.

## Experience (the ratified behavior)

1. Screen goes dark (near-black background, as in the game).
2. A random proverb is picked (no immediate repeat of the previous one).
3. The proverb is laid out as a centered block, wrapped to lines by word,
   using the glyph width classes.
4. An invisible pen writes it: letter by letter, each letter stroke by stroke
   in authored stroke order, the pen tip moving at constant speed along each
   path. Completed letters stay as settled ink.
5. Each completed letter gets a brief gold pulse (the game's celebration,
   translated to SDR).
6. When the proverb is complete, it holds on screen (order of ~10 s, matching
   the game's 12 s saying-celebration dwell), then fades and the next proverb
   begins.
7. Runs identically on every attached screen and, scaled down, in the System
   Settings preview.

## Constraints

1. **Self-contained bundle.** Everything the saver needs (code, both JSON
   files) lives inside `GlyphSaver.saver`. No network, no reads outside the
   bundle, no writes anywhere.
2. **Core stays headless.** Glyph model, layout, and the writing timeline are
   pure Swift (Foundation + CoreGraphics types only — no AppKit, no
   ScreenSaver framework) and are exercised by `swift test` without a GUI
   host. Only the thin view layer touches ScreenSaver/AppKit.
3. **Files are the system of record.** The repo's tracked files fully
   determine the built saver. No generated state outside `build/`.
4. **Name honesty.** Identifiers ported from the game keep the game's
   verified semantics or get renamed to match what they actually do here.

## Named extension points (deferred, not designed for)

- **GS-RO — Romanian proverbs.** Requires authoring `ă â î ș ț` (and any
  punctuation) in the zap-engine glyph editor and re-exporting
  `glyphs_baked.json`. This is a human authoring session, not agent work.
  Ratified 2026-08-11: v1 is English-only; diacritic stripping was rejected as
  a rendered defect.
- **Universal binary / distribution.** `lipo` + codesign + notarize when the
  saver leaves this machine. Trivial build-script extension; not before then.
- **Configure sheet.** Only if a real second user or a real second preference
  appears.
