# Glyph Saver — Implementation Plan

Status: RATIFIED 2026-08-11, AMENDED same day (human direction: in-place
writing at saying-complete scale; keep bump-mapped background, particles,
HDR; reuse the ZapZap Metal renderer). This is the `sliceDoc` for slices
GS-1…GS-4 — implementation slices reference this pre-ratified plan; they do
not re-open its decisions.

## Toolchain (verified on this machine, 2026-08-11)

- macOS 26.6.1, arm64. Swift 6.2.3 via Command Line Tools. `lipo`,
  `codesign` present (unused in v1).
- Full Xcode exists at `/Applications/Xcode.app` but `xcode-select` points at
  CLT, so the `metal` compiler is NOT on PATH. **Decision: shaders compile at
  runtime** via `MTLDevice.makeLibrary(source:)` from `.metal` source shipped
  in Resources — no build-time Metal toolchain, no global toolchain switch.
  (Donor shader is 52 lines; runtime compile cost is negligible at saver
  startup.)
- Deployment target `arm64-apple-macos14`, arm64-only (v1, this machine).
- macOS 26 hosts third-party savers via `legacyScreenSaver`; after each
  install: `killall legacyScreenSaver ScreenSaverEngine`.
- Display: built-in panel `maximumPotentialEDR = 1.0` (no HDR headroom).
  Pipeline is still built EDR-ready (see renderer).

## Renderer decision (amended)

CoreGraphics (original plan) cannot do per-frame normal-mapped lighting,
particles, or EDR. **Metal**, adapting the **ZapZap** donor
(`/Users/apple/Documents/Xcodes/ZapZap`, same author, proven in production):

- Surface: `CAMetalLayer`, `.rgba16Float`, `extendedLinearDisplayP3`
  (ZapZap's EDR setup, verbatim).
- Pass architecture ports the zap-web pipeline (verified in
  `lighting.wgsl`/`composite.wgsl`):
  1. **Scene pass** → offscreen color buffer: background quad
     (`vbg_1024.jpg`) + ink strokes as tessellated triangle-strip ribbons
     (polyline → ribbon in the render layer) — **Hello-style strokes**
     (amended 2026-08-11): thick, uniform width, round caps, round joins,
     opaque warm cream. Starting constants (tune at checkpoints): width 36
     glyph units (~7.5% of the 480-unit glyph box; the game's 6-unit guide
     line is NOT the reference — the macOS Hello saver is), color ≈
     (0.95, 0.91, 0.82). Opaque because cursive loops self-overlap and only
     opaque ink crosses cleanly. A parallel **normal buffer** holds the
     background's normal map; strokes do NOT write normals — the leather
     relief deliberately shows through via the lighting pass (verified
     engine behavior).
  2. **Lighting pass** (fullscreen): port of `lighting.wgsl` to MSL — point
     lights, per-pixel normal shading, quadratic falloff `(1 − d/r)²`,
     multiplied over the whole scene (ink included).
  3. **Particles**: instanced quads, adapted from ZapZap
     `ParticleEffects.swift` (104 lines).
  4. Present. No bloom pass — the engine has none; parity does not want one.
- Donor files are **copied into this repo with provenance headers**
  (self-contained bundle; no external project dependency). Adapt, don't
  wrap: dead donor code (game boards, sounds, StoreKit) stays behind.

Abstraction ledger (the only ones):
- `GlyphCore` SPM library — users: renderer + tests; axis: none claimed, it
  is the test seam required by VISION constraint 2; rejected simpler
  alternative: untested flat module.
- Everything else is direct implementation. No renderer protocol (one
  renderer), no scene graph, no config layer.

## Architecture

```
GlyphCore  (SPM library — pure Swift, Foundation + CG value types only)
  GlyphSet       parse glyphs_baked.json; strokes/variant/exit/width queries
                 (glyphs.rs semantics + game.rs word-start-High override)
  ProverbLayout  proverb → positioned, variant-resolved stroke polylines:
                 wrap by word (advances ×0.5/×1.0/×1.3 of 600-unit box, word
                 gap 0.5), lines centered as a block, uniform scale to fit
  WritingClock   pure timeline: elapsed → inked strokes, active stroke, pen
                 arc-length position, celebration timers, phase
                 (writing | letterCelebrate | holding | fading), next-pick
  CameraPlan     pure viewport: (inked + active letter bboxes) → padded
                 union target frame, exponentially smoothed; starts framed
                 on the first letter's box, monotonically zooms out, ends
                 exactly at the full-block framing. World→screen transform
                 applied to ink/pen/lights; background is screen-fixed.

Render layer  (Sources/Saver/ — Metal + AppKit + ScreenSaver, NOT under test)
  GlyphSaverView   ScreenSaverView hosting the CAMetalLayer, drives
                   WritingClock in animateOneFrame
  ZapRenderer      adapted ZapZap renderer: scene/lighting/particle passes,
                   ribbon tessellation, runtime shader compile
  Shaders.metal    scene + lighting + particle shaders (in Resources)
```

Light choreography (from the verified game inventory, VISION):
writing → guide light `[0.5,0.7,1.0] i3 r280` + green pen light
`[0.3,1.0,0.4] i4 r250` at the pen tip, faint ambient `[0.3,0.3,0.4] i4 r350`
at the active letter; letter complete → gold stroke flood (8t,6.8t,2.4t)
w8→20 + gold light i14t r350 + 25-particle burst (speed 15, size 5, life
1.5 s); saying complete → central gold light i10t r400, ~12 s dwell.

## Repository layout

```
glyph-saver/
  Package.swift            SPM: GlyphCore + GlyphCoreTests only
  Sources/GlyphCore/
  Sources/Saver/           GlyphSaverView, ZapRenderer, Shaders.metal, Info.plist
  Tests/GlyphCoreTests/
  data/                    glyphs_baked.json, sayings.json
  assets/                  vbg_1024.jpg, vbg_1024_normals.png
  scripts/build.sh         swiftc → build/GlyphSaver.saver (data+assets+shader → Resources)
  scripts/install.sh       cp to ~/Library/Screen Savers + killall reload
  docs/
  build/                   gitignored
```

## Gates (every slice; run bare, never piped, exit codes checked individually)

1. `swift test`
2. `scripts/build.sh` exits 0 and produces `build/GlyphSaver.saver`
3. The slice's named **output surface** demonstrably renders (operator
   installs and looks). Deep-vertical rule: no dormant capability.

## Test hosts (one engine, two shells — decided 2026-08-11)

The renderer + core are host-agnostic; only the CAMetalLayer's owner varies.

**Automated engine-capture is IMPOSSIBLE on this machine** (verified
2026-08-11, ratified 2026-08-12): direct exec of `ScreenSaverEngine` is
SIGKILLed by macOS 26 launch constraints (CODESIGNING violation, crash
reports on file), and the LaunchServices route (`open -a`) is dismissed by
ANY human input — with the human at the Mac, automated full-screen capture
is nondeterministic by construction. (This confounded cycle-1: the builder's
"dismissed during capture" and the operator's early probes were the human's
own mouse. The bundle itself is sound — verified by in-process load.)

The ratified **layered acceptance** (each layer covers what the previous
cannot):
1. `scripts/loadtest` (gate, automated) — loads the INSTALLED bundle
   in-process and instantiates the principal class via
   `initWithFrame:isPreview:` — the engine's exact dyld/class/init path.
2. Offscreen frames (gate, automated) — render N frames through the REAL
   `GlyphSaverView` (not a renderer-only harness) into `build/*.png`;
   frames must differ; the operator reviews them visually each checkpoint.
3. Human glance (checkpoint cadence) — System Settings → Screen Saver →
   "Other" (the `legacyScreenSaver.appex` sandbox) and the real idle-time
   run: the only surfaces automation cannot reach.
- **Preview app host** (`Sources/PreviewApp/main.swift`, tracked, lands
  GS-2) — the same renderer in an NSWindow for live watching. Dev tool,
  never shipped, never acceptance evidence.
Install stays per-user (`~/Library/Screen Savers`); `/Library/Screen
Savers` (all users) only when a real need appears.

## Slices

Ordering is riskiest-substrate-first: the saver-bundle + Metal-in-
`legacyScreenSaver` combination is the unknown; glyph logic is not.

### GS-1 — Metal saver skeleton: the living background (PROTOTYPE)

- `.saver` bundle mechanics: Info.plist (`NSPrincipalClass` GlyphSaverView,
  `@objc(GlyphSaverView)`), build.sh, install.sh.
- ZapRenderer minimum: CAMetalLayer in ScreenSaverView (rgba16Float,
  extended linear P3), runtime shader compile, scene pass drawing the
  leather quad + normal buffer, lighting pass with ONE point light sweeping
  slowly (any path), ambient near-dark.
- Adapted donor files land with provenance headers.
- No text yet. No SPM target needed yet if no core logic ships — but
  Package.swift may land here if convenient.

Output surface: the installed saver shows the lit, bump-mapped leather with
a moving light — in System Settings preview AND full screen. Proves
bundle + Metal-in-preview-host + texture/shader loading end-to-end (the
riskiest substrate, before any glyph work).

### GS-2 — GlyphCore + static proverb ink (PROTOTYPE → MATURE on approval)

- `GlyphSet` (parse + variant/exit/width queries incl. word-start-High) and
  `ProverbLayout` (wrap/center/scale at saying-complete block scale), with
  tests: variant-rule oracle from VISION, advance/wrap arithmetic, and the
  coverage property — every character of all 31 sayings resolves to an
  existing glyph variant.
- Promote the preview app host to tracked code
  (`Sources/PreviewApp/main.swift` + `scripts/preview.sh` — see Test
  hosts), replacing the cycle-0 improvised harness.
- Ribbon tessellation in the render layer: round joins + round caps,
  uniform width, opaque cream (constants above); one full proverb rendered
  as settled ink over the GS-1 background, lit by the ambient. Overlap
  correctness (loops in e/o/l cross without artifacts) is part of the
  slice's visual acceptance.

Output surface: any proverb, statically complete, Hello-style fat ink at
the winning-screen scale over the living background.

### GS-3 — The writing (PROTOTYPE → MATURE on approval)

- `WritingClock`: arc-length pen at GUIDE_SPEED-equivalent pacing (60 path
  points/s over evenly-spaced points; one named constant), strokes in
  authored order, letters in reading order; phases writing → holding
  (~12 s) → fading → next proverb (uniform random, no immediate repeat).
  Tests: phase transitions, monotonic ink progress, no-repeat.
- `CameraPlan` (amended 2026-08-11): opens framed on the first letter's
  glyph box (~65% of screen height), target = padded union bbox of inked +
  active letter, exponential smoothing (~1 s time constant), ends at the
  full-block framing. Tests: zoom-out monotonic, active letter always in
  frame, final frame equals the GS-2 static framing.
- Render: partial-stroke ribbons up to pen position; pen tip dot; the pen
  carries the guide + green lights along the actual stroke path; camera
  transform applied to ink/pen/lights, leather screen-fixed.

Output surface: the saver writes proverbs in place, letter by letter, the
camera pulling back from one huge letter to the full boxed proverb — the
product's defining behavior, watchable.

### GS-4 — Celebrations & parity (PROTOTYPE → MATURE on approval)

- Letter-complete: gold stroke flood (8t,6.8t,2.4t; width 8→20; 1.2 s) +
  gold light + 25-particle burst (ZapZap ParticleEffects adaptation).
- Saying-complete: central gold dwell light (i10t, r400) through the hold.
- `isPreview` legibility check; multi-screen check.
- Parity review: side-by-side with the web game's saying-complete screen.

Output surface: the finished look — celebrations firing, judged against the
game.

### GS-RO — Romanian proverbs (DEFERRED — human authoring required)

Named extension, not scheduled. Glyph-editor session for `ă â î ș ț` +
punctuation, then re-export. See VISION.

## Slice → relay mapping

`.agent-manager/slices/GS-<n>/{selection.md,selection.json,status.json}`,
phase `implement`, builder claude (`claude-opus-4-8`, high) / supervisor
codex (`gpt-5.6-terra`) — the defaults. From agent-manager:

```
npm run relay-target -- ../glyph-saver --slice GS-1 --max-iter 3
```

`sliceDoc` = `docs/PLAN.md` for all GS slices — IMPL slices against this
pre-ratified plan; decision-review must NOT fire (a surfaced
ratification-class decision is an `escalate`). Checkpoint cadence
`--max-iter 3`; operator reviews, commits deliverable, advances.

## Deliberately deferred (recorded, not designed for)

- Universal binary, codesign/notarization (leaves-this-machine trigger).
- Configure sheet (second-user trigger).
- XDR output verification (no EDR-capable display on this machine).
- Proverb additions beyond `sayings.json` edits (must pass the GS-2
  coverage property).
