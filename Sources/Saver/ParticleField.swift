//
//  ParticleField.swift — closed-form HDR particle system (celebrations + finale)
//  Module maturity: PROTOTYPE (slice GS-4)
//
//  PROVENANCE
//  ----------
//  Adapted from the ZapZap donor (/Users/apple/Documents/Xcodes/ZapZap,
//  "ZapZap Shared/MESHES/ParticleEffects.swift", class Particle — 104 lines):
//  the burst-of-quads-with-velocity-and-lifetime concept, HDR per-particle
//  colour, gravity/dispersion, and lifetime fade.
//
//  DELIBERATE DEVIATION (recorded, and the reason it is a rewrite not a copy):
//  the donor integrates each particle STATEFULLY, once per frame (object pool +
//  attractor + friction; `position += speed` every draw). This renderer replays
//  the ENTIRE schedule STATELESSLY from an absolute time on every frame — GS-3's
//  architecture, exercised by `renderFrameSynchronously`, which renders a single
//  cold frame deterministically for verify.sh/thumbnail. A stateful pool cannot
//  be reconstructed from one time sample. So every particle here is CLOSED-FORM:
//  given its spawn (origin, velocity, birth, life) under constant gravity,
//     position(age) = origin + velocity·age + ½·g·age²,   age = local − birth
//     alpha(age)    = (1 − age/life)²                    (ease-out to black)
//  and the spawn events are themselves deterministic (SplitMix64 seeded per burst
//  / per emitter), so the field at time `t` is a PURE function of
//  (layout, clock, local, seed). Same schedule ⇒ same particles every frame.
//
//  ONE system, TWO users (deliverable 1's earned justification):
//    - `letterBursts`  — 25 gold sparks per completed letter (game.rs:795-803);
//    - `dissolveField` — sparks emitted along the ink polylines during the finale
//      dissolve, coloured like the ignited ink (VISION §6, fireworks-like). Its
//      emission SCHEDULE is the pure, tested `FinaleDissolve` (GlyphCore); the
//      geometry sampling + closed-form sim are here (judged visually).
//
//  ABSTRACTION LEDGER: `ParticleQuad` is a raw value DTO (world centre + world
//  half-size + HDR rgba) handed to ZapRenderer, which uploads the array VERBATIM
//  as the per-instance buffer for an INSTANCED unit-quad draw (Shaders.metal
//  `ParticleInstance` mirrors this layout exactly; particle_vertex builds the quad
//  per instance). No protocol: one concrete producer, two call sites. Rejected
//  simpler: emitting vertices directly from the producers — that would fuse the
//  sim with the tessellation and hide the deterministic, reviewable spawn logic.
//

import Foundation
import CoreGraphics
import simd

/// One live particle at the current instant: a world-space quad with an HDR
/// colour whose alpha already carries the lifetime fade.
struct ParticleQuad {
    var center: SIMD2<Float>    // world coords (y-down), camera-transformed at draw
    var halfSize: Float         // world half-extent of the quad
    var color: SIMD4<Float>     // rgb = HDR (may exceed 1); a = fade alpha
}

enum ParticleField {

    // MARK: Letter burst (game.rs:795-803)

    /// Game-cited constants, applied literally (review-0: the game values are the
    /// ratified values, not a tuning start point). `spawn_particles(center, 25,
    /// 15.0, 5.0, 1.5)` — game.rs:796-802 / effects/mod.rs:91-98: count 25, speed
    /// 15, size 5, lifetime 1.5. We treat SPEED as world u/s and SIZE as the quad
    /// world half-size in this 600-unit world.
    static let letterBurstCount = 25                     // game.rs:797
    static let letterBurstLifetime: CGFloat = 1.5        // game.rs:802
    static let letterBurstSpeed: Float = 15              // game.rs:799 (speed_limit)
    static let letterBurstSize: Float = 5                // game.rs:800 (width)

    /// Gold spark colour: the game's celebration gold light hue (game.rs:551
    /// [1.0, 0.85, 0.3]) lifted into HDR so the sparks self-glow in the additive
    /// pass. Magnitude is a tuned constant (visual).
    static let goldSparkColor = SIMD3<Float>(1.0, 0.85, 0.3)
    static let goldSparkHDR: Float = 3.5

    /// Burst gravity (world u/s², +y DOWN). UNCITED — the game has no gravity (it
    /// uses an attractor + friction, effects/mod.rs); this is render-layer latitude
    /// (particles judged visually). Set to 2× `letterBurstSpeed` so the burst keeps
    /// the previously-approved fountain ARC at the now-ratified speed 15 (the old
    /// 130/260 pair had the same 2× ratio); leaving the old 260 with speed 15 would
    /// make sparks plummet straight down instead of dispersing.
    static let letterBurstGravity: Float = 30

    /// Dissolve-firework gravity (world u/s², +y DOWN) — fireworks fall as they
    /// fade. Uncited visual constant; unchanged from the reviewer-approved dissolve.
    static let dissolveGravity: Float = 260

    // MARK: Dissolve field (VISION §6)

    static let dissolveEmitterSpacing: Float = 18        // MINIMUM arc length between emitters (see sampleEmitters: emitters snap to vertices, so actual spacing ≥ this). Operator note 2026-08-12: DENSITY raised (was 34) so the dissolve reads as a fuller fireworks shower — ~2× the emitter count along each stroke. Uncited visual constant.
    static let dissolveParticleLife: CGFloat = 1.0       // s — last-born (at emissionWindow) dies at dissolve end
    static let dissolveTangentSpeed: Float = 70          // random pop, world u/s
    static let dissolveOutwardSpeed: Float = 55          // outward along stroke normal, world u/s
    static let dissolveParticleSize: Float = 8

    /// Per-particle size jitter (operator note 2026-08-12): each spark's world
    /// half-size is scaled by a seeded factor in this range so the burst/shower
    /// is not a grid of identical discs. ±40% around 1.0. Uncited visual constant;
    /// drawn from the SAME deterministic stream as the particle's angle/speed, so
    /// the field stays a pure function of the seed.
    static let sizeJitterRange: ClosedRange<Float> = 0.6 ... 1.4

    // MARK: Producers

    /// Gold bursts for every letter currently within its 1.2 s celebration window
    /// (game.rs:795-803). Deterministic: each letter's 25 sparks are seeded from
    /// `(proverbSeed, glyphIndex)`, so the same frame reproduces the same burst.
    static func letterBursts(layout: ProverbLayout.Layout,
                             clock: WritingClock,
                             local: CGFloat,
                             proverbSeed: UInt64) -> [ParticleQuad] {
        // Completion time per glyph = the max endTime among its drawable strokes.
        var completeByGlyph: [Int: CGFloat] = [:]
        for s in clock.strokes {
            completeByGlyph[s.glyphIndex] = max(completeByGlyph[s.glyphIndex] ?? 0, s.endTime)
        }
        let base = goldSparkColor * goldSparkHDR
        var quads: [ParticleQuad] = []
        for (gi, complete) in completeByGlyph {
            let age = Float(local - complete)
            guard age >= 0, age < Float(letterBurstLifetime) else { continue }
            let c = layout.glyphs[gi].center
            let origin = SIMD2<Float>(Float(c.x), Float(c.y))
            var rng = SplitMix64(seed: proverbSeed ^ (UInt64(bitPattern: Int64(gi)) &* 0x9E37_79B9_7F4A_7C15 &+ 0x51))
            for _ in 0..<letterBurstCount {
                let angle = Float.random(in: 0 ..< (2 * Float.pi), using: &rng)
                let speed = Float.random(in: 0.2 ... 1.0, using: &rng) * letterBurstSpeed
                let jitter = Float.random(in: sizeJitterRange, using: &rng)
                let v = SIMD2<Float>(cos(angle) * speed, sin(angle) * speed)
                if let q = integrate(origin: origin, velocity: v, age: age,
                                     life: Float(letterBurstLifetime), color: base,
                                     size: letterBurstSize * jitter, gravity: letterBurstGravity) {
                    quads.append(q)
                }
            }
        }
        return quads
    }

    /// Fireworks emitted along the ink polylines during the finale dissolve,
    /// coloured like the ignited ink. Emitter i (of n, arc-length-ordered) is born
    /// at `FinaleDissolve.emitterBirthProgress(i, n)` into the dissolve (the pure,
    /// tested schedule) and lives `dissolveParticleLife`. Deterministic per
    /// emitter; the RNG is advanced for EVERY emitter (before the liveness guard)
    /// so each emitter's velocity is stable regardless of which are currently live.
    static func dissolveField(layout: ProverbLayout.Layout,
                              clock: WritingClock,
                              local: CGFloat,
                              igniteColor: IgniteColor,
                              proverbSeed: UInt64) -> [ParticleQuad] {
        let emitters = sampleEmitters(layout: layout)
        let n = emitters.count
        guard n > 0 else { return [] }

        let dissolveStart = clock.writingDuration + clock.holdDuration + clock.igniteDuration
        let color = SIMD3<Float>(Float(igniteColor.r), Float(igniteColor.g), Float(igniteColor.b))
        var rng = SplitMix64(seed: proverbSeed ^ 0xD1_5501_5E_D1_5501)
        var quads: [ParticleQuad] = []
        quads.reserveCapacity(n)
        for i in 0..<n {
            // Advance the stream for every emitter (deterministic order) — angle,
            // speed, AND size jitter drawn before the liveness guard so each
            // emitter's spark is stable regardless of which are currently live.
            let angle = Float.random(in: 0 ..< (2 * Float.pi), using: &rng)
            let speed = Float.random(in: 0.3 ... 1.0, using: &rng) * dissolveTangentSpeed
            let jitter = Float.random(in: sizeJitterRange, using: &rng)

            let birthProgress = FinaleDissolve.emitterBirthProgress(i, of: n)
            let birth = Float(dissolveStart) + Float(birthProgress) * Float(clock.dissolveDuration)
            let age = Float(local) - birth
            guard age >= 0, age < Float(dissolveParticleLife) else { continue }

            let e = emitters[i]
            let v = SIMD2<Float>(cos(angle) * speed, sin(angle) * speed) + e.normal * dissolveOutwardSpeed
            if let q = integrate(origin: e.position, velocity: v, age: age,
                                 life: Float(dissolveParticleLife), color: color,
                                 size: dissolveParticleSize * jitter, gravity: dissolveGravity) {
                quads.append(q)
            }
        }
        return quads
    }

    // MARK: Sim + sampling

    /// Closed-form particle at `age` seconds after birth, or nil if not alive.
    private static func integrate(origin: SIMD2<Float>, velocity: SIMD2<Float>,
                                  age: Float, life: Float,
                                  color: SIMD3<Float>, size: Float,
                                  gravity: Float) -> ParticleQuad? {
        guard age >= 0, age < life, life > 0 else { return nil }
        let cx = origin.x + velocity.x * age
        let cy = origin.y + velocity.y * age + 0.5 * gravity * age * age   // gravity pulls +y (down)
        let fade = 1 - age / life
        let alpha = fade * fade                                            // ease-out to black
        return ParticleQuad(center: SIMD2<Float>(cx, cy), halfSize: size,
                            color: SIMD4<Float>(color.x, color.y, color.z, alpha))
    }

    /// Ordered emitter positions (+ stroke normals) along every drawable stroke.
    ///
    /// ACTUAL SAMPLING CONTRACT (reviewer-corrected — this is VERTEX-QUANTIZED,
    /// not evenly resampled): walking each stroke vertex to vertex, an arc-length
    /// accumulator sums segment lengths; the first vertex at which it reaches
    /// `dissolveEmitterSpacing` gets an emitter (placed at that END vertex `b`,
    /// with `b`'s incoming-segment normal), then the accumulator resets to 0 —
    /// the OVERSHOOT past the threshold is DISCARDED, not carried forward. So:
    ///   - emitters land ON polyline vertices (never interpolated mid-segment);
    ///   - the spacing between successive emitters is ≥ `dissolveEmitterSpacing`
    ///     (each interval is filled to the threshold and then rounded UP to the
    ///     next vertex; discarding overshoot means intervals never run short);
    ///   - the accumulator is PRE-SEEDED to `dissolveEmitterSpacing`, so the very
    ///     first segment always crosses the threshold ⇒ the first emitter of each
    ///     stroke is its SECOND vertex (`stroke[1]`), not the start point;
    ///   - a stroke shorter than one segment past threshold yields NO emitter for
    ///     its tail (the residual `acc` is dropped at the stroke boundary).
    /// Deterministic order: glyph order → stroke order → along the path. The exact
    /// spacing is an uncited VISUAL constant (particles judged by eye), so this
    /// endpoint-quantized approximation of even spacing is intentional and cheap;
    /// no interpolation contract is promised.
    private static func sampleEmitters(layout: ProverbLayout.Layout)
        -> [(position: SIMD2<Float>, normal: SIMD2<Float>)] {
        var out: [(SIMD2<Float>, SIMD2<Float>)] = []
        for glyph in layout.glyphs {
            for stroke in glyph.strokes where stroke.count >= 2 {
                // Pre-seed to spacing so the first crossed vertex (stroke[1]) emits.
                var acc: Float = dissolveEmitterSpacing
                for i in 1..<stroke.count {
                    let a = stroke[i - 1], b = stroke[i]
                    let dx = Float(b.x - a.x), dy = Float(b.y - a.y)
                    let len = (dx * dx + dy * dy).squareRoot()
                    guard len > 1e-6 else { continue }
                    acc += len
                    if acc >= dissolveEmitterSpacing {
                        acc = 0                              // discard overshoot (vertex-quantized)
                        let normal = SIMD2<Float>(-dy / len, dx / len)
                        out.append((SIMD2<Float>(Float(b.x), Float(b.y)), normal))
                    }
                }
            }
        }
        return out
    }
}
