# Glyph Saver — Vision

## What this is

A native macOS screensaver (`.saver` bundle) that writes proverbs on screen in
**handwriting** — an invisible pen draws each letter stroke by stroke, letter by
letter, **in place at its final position**, until the whole proverb stands on
screen, holds, then a new random proverb begins.

It is the contemplative, non-interactive form of **Glypher**
(`zap-engine/examples/glypher`), the tracing game where the player writes each
letter by hand. The screensaver keeps Glypher's full look — the hand-authored
glyph strokes, the cursive flow between letters, the bump-mapped leather
background swept by moving lights, the particle celebrations — and removes the
player. The machine writes; you watch.

**Not the game's practice view** (one giant letter at a time in the center,
progress text small at the top). The saver writes at the scale of the game's
*saying-complete* screen: the whole proverb laid out large as a centered
multi-line block, each letter drawn where it will stay. (Amended 2026-08-11
from game screenshots + human direction.)

## What it is NOT

- **Not a port of zap-engine.** No Rust, no WASM, no WebGPU, no web view. The
  *data*, the *aesthetic*, and the *rendering architecture* carry over; the
  engine does not. The native renderer is adapted from **ZapZap**
  (`/Users/apple/Documents/Xcodes/ZapZap`, same author) — a proven custom
  Metal renderer already built for EDR/HDR.
- **Not a generic quote screensaver.** The letters are *drawn*, along the same
  stroke paths a player would trace in the game, over the same lit leather.
- **Not configurable (v1).** No configure sheet, no options.
- **Not distributed (v1).** Personal use on the author's machine. No signing,
  no notarization, no universal binary — named extension points only.

## Source lineage (files of record)

| File | Origin | Contract |
|------|--------|----------|
| `data/glyphs_baked.json` | Exported by the zap-engine glyph editor ("Download Baked"), copied 2026-08-11 from `zap-engine/examples/glypher/data/`. | **Generated artifact — never hand-edit.** Per-character stroke polylines of evenly-spaced points, entry variants (`Baseline`/`High`), exit types, width classes (0 narrow / 1 standard / 2 wide). Covers exactly `a–z A–Z 0–9` — 62 glyphs, no punctuation, no diacritics. |
| `data/sayings.json` | Same origin. | Flat JSON array of 31 proverbs authored for the 62-glyph set (letters + spaces only). Verbatim, game parity. Hand-editable; additions must use only covered characters. |
| `assets/vbg_1024.jpg` + `assets/vbg_1024_normals.png` | Copied 2026-08-11 from `zap-engine/examples/glypher/public/assets/` (per its `assets.json`: the single background atlas + its normal map). | The bump-mapped leather background. Generated art assets — replaced, never edited. |
| Renderer donor | `ZapZap Shared/` — `Renderer.swift`, `Shaders.metal`, `ParticleEffects.swift`, `Math.swift`, `GraphicsLayer.swift`. | Adapted (copied with provenance headers), not depended on. `.rgba16Float` surface + `extendedLinearDisplayP3` colorspace = EDR-ready. |

## Behavioral reference — verified facts (2026-08-11, from source)

From `examples/glypher/src/{glyphs.rs, game.rs}`:

- Glyph box: 600 × 480 units; width classes scale box width ×0.5 / ×1.0 / ×1.3.
- Word gap: 0.5 × a standard character advance. Spaces are gaps, not glyphs.
- Cursive variant rule: previous letter's exit (`Baseline`/`High`) picks the
  lowercase entry variant (`glyphs.rs::variant_for`); high-exit letters are
  `b o v w`; at word start `m n v w` use `High` (`game.rs::effective_variant`).
- Pen pacing: `GUIDE_SPEED = 60` **path points per second** (stroke points are
  evenly spaced — speed is effectively arc-length-constant per stroke).
- Lights (the game's inventory, `game.rs`):
  - moving guide light along the stroke: color `[0.5, 0.7, 1.0]`,
    intensity 3.0, radius 280 — this is what sweeps the leather;
  - green drawing light at the pen: `[0.3, 1.0, 0.4]`, 4.0, 250;
  - faint ambient at the letter: `[0.3, 0.3, 0.4]`, 4.0, 350;
  - letter-complete gold flood: strokes redrawn gold
    `(8t, 6.8t, 2.4t)` width 8→20 over 1.2 s + gold light
    `[1.0, 0.85, 0.3]`, intensity 14·t, radius 350;
  - saying-complete: central gold light `[1.0, 0.85, 0.3]`, 10·t, radius 400,
    over a 12 s dwell.
- Particles: letter completion spawns **25 particles** at the glyph center
  (speed 15, size 5, lifetime 1.5 s) — `game.rs` `spawn_particles`.
- Rendering architecture (from `zap-web/src/renderer/lighting.wgsl` +
  `composite.wgsl`): **lighting is a fullscreen post-process** — the scene
  (background sprite + vector strokes) is composed into a color buffer with a
  parallel normal buffer, then point lights with per-pixel normal-mapped
  shading and quadratic falloff `(1 − d/r)²` multiply the whole frame. Ink is
  lit by the same pass — that is why the leather relief shows through the
  strokes. **There is no bloom pass**; the glow is the lights themselves.
- The web engine's intermediate buffers are `rgba8unorm` — HDR-ish colors
  clamp. ZapZap's native pipeline (`rgba16Float`, extended linear P3) does
  not; the saver can match or exceed the web game's fidelity.

## Experience (ratified behavior, amended 2026-08-11)

1. The bump-mapped leather background, near-dark, ambient-lit.
2. A random proverb is picked (no immediate repeat).
3. The proverb is laid out as a large centered multi-line block — the
   saying-complete screen's scale — wrapped by word using glyph width classes.
   The layout is fixed; **the camera moves over it** (amended 2026-08-11):
   writing opens framed tight on the first letter — one huge letter filling
   the screen — and as letters complete, the camera **slowly, monotonically
   zooms out** to keep everything written plus the active letter in frame,
   converging exactly to the full boxed multi-line framing by the last
   letter. The leather is screen-fixed (the camera transforms ink, pen, and
   lights only — world-attached leather would magnify to blur, and the game
   treats the background as screen-space).
4. An invisible pen writes it in place: letter by letter, stroke by stroke in
   authored order, pen tip moving at constant arc-length speed. **The pen
   carries the light**: the guide/drawing lights sweep the leather as it
   writes. **The ink is Hello-style** (amended 2026-08-11, after the macOS
   "Hello" screensaver): a thick, uniform-width, round-capped, round-joined,
   **opaque warm-cream** stroke — a fat pen, not the game's thin glow line.
   Opacity is load-bearing: cursive loops self-overlap, and only opaque ink
   overlaps cleanly (translucent glow would double-brighten at crossings).
   The lighting pass still shades the ink, so the scene stays one world.
   Completed letters stay as settled cream ink.
5. Each completed letter: gold flood on its strokes + a particle burst +
   gold light pulse (the game's letter celebration, 1.2 s). Gold against
   cream ink is the chosen contrast (ratified 2026-08-11). The game's green
   pen light may be tuned warm to match the cream ink — operator latitude
   at checkpoints, not a re-ratification.
6. Proverb complete — the **finale** (amended 2026-08-12, human direction;
   deliberate divergence from game parity, whose saying-complete is only a
   dwell light): a short admiring dwell under the central gold light
   (~5 s), then the ink **ignites** — the settled cream ramps over ~1.5 s
   to a random VIBRANT hue at 4×–8× HDR intensity (full-saturation hue,
   never grey/white; on this SDR panel it tone-clamps to a vivid glow, on
   XDR it is real fire) — then the strokes **dissolve into particles**:
   HDR particles emitted along the stroke paths as the ink fades,
   fireworks-like (ZapZap particle heritage), falling/dispersing to black
   (~2–3 s). Then the next proverb begins from its first huge letter.
   Fallback knob (recorded, not built): quick fade-to-black if the
   dissolve disappoints at checkpoint.
7. Identical on every attached screen; scaled down in System Settings preview.
8. EDR: the surface is EDR-capable; on this machine's panel (verified
   `maximumPotentialEDR = 1.0`) output is tone-limited SDR today — an XDR
   display gets real headroom with no code change.

## Constraints

1. **Self-contained bundle.** Code, both JSONs, both textures, shader source —
   all inside `GlyphSaver.saver`. No network, no reads outside the bundle, no
   writes anywhere. Shaders compile at runtime (`makeLibrary(source:)`) — no
   Metal toolchain dependency at build time.
2. **Core stays headless.** Glyph model, layout, writing timeline: pure Swift
   (Foundation + CoreGraphics value types only — no AppKit, no ScreenSaver,
   no Metal), exercised by `swift test`. Only the render layer touches
   Metal/AppKit/ScreenSaver.
3. **Files are the system of record.** Tracked files fully determine the
   built saver. No generated state outside `build/`.
4. **Name honesty.** Ported identifiers keep verified semantics or are
   renamed to match actual behavior.

## Named extension points (deferred, not designed for)

- **GS-RO — Romanian proverbs.** Requires authoring `ă â î ș ț` (+
  punctuation) in the zap-engine glyph editor and re-export. Human authoring
  session. Ratified 2026-08-11: v1 English-only; diacritic stripping rejected.
- **XDR display.** Pipeline is EDR-ready; nothing to build until the hardware
  exists.
- **Universal binary / distribution.** `lipo` + codesign + notarize when the
  saver leaves this machine.
- **Configure sheet.** Only if a real second user or preference appears.
