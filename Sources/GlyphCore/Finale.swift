//
//  Finale.swift — pure rules for the ignite→dissolve finale (VISION §6 / PLAN GS-4)
//  Module maturity: PROTOTYPE (slice GS-4)
//
//  Pure core (VISION constraint 2 / CLAUDE.md hard constraint 1): Foundation +
//  CoreGraphics value types ONLY. No AppKit / Metal / ScreenSaver. Proven by
//  `swift test`. Same files compiled into the `GlyphSaver` module for the saver
//  build (build.sh) — hence `public`.
//
//  WHAT THIS IS
//  -----------
//  The two *decidable* parts of the finale, factored out of the render layer so
//  they are unit-tested (deliverable 4) and reproduced identically by the
//  renderer each frame:
//    - `FinaleColor.ignite(seed:)` — the random VIBRANT HDR hue the settled ink
//      ramps to (VISION §6: "random FULL-SATURATION hue at 4×–8× HDR intensity;
//      never grey/white; seeded per proverb"). The particle *rendering* is judged
//      visually; the COLOUR RULE is a pure, tested function.
//    - `FinaleDissolve.emitterBirthProgress(_:of:)` — the dissolve emission
//      SCHEDULE (which sampled emitter fires when), the pure, monotone part the
//      renderer drives; the emitter geometry + particle sim live in the render
//      layer.
//
//  ABSTRACTION LEDGER:
//    - `IgniteColor` (struct): raw RGB DTO crossing to the render layer (channels
//      are LINEAR and may exceed 1 — the HDR band). No framework types (boundary
//      rule). Concrete users: ZapRenderer (consumes) + FinaleTests (pins the
//      rule). Rejected simpler: returning a bare tuple — a named DTO documents
//      that these are HDR-linear, not sRGB [0,1].
//    - `FinaleColor` / `FinaleDissolve` (namespace enums of pure functions):
//      earned by deliverable 4 (each rule is unit-tested directly) and by the
//      renderer's need to reproduce them deterministically. Axis: fixed
//      operations over value inputs → plain functions, no protocol. Rejected
//      simpler: inlining the HSV maths + schedule in the renderer, which loses
//      the required test seam.
//

import Foundation
import CoreGraphics

/// The finale ignite target colour: a full-saturation hue at HDR intensity.
/// LINEAR channels — the 4×–8× band means components routinely exceed 1.0 (the
/// panel presents the headroom; the renderer does NOT tone-map — human directive
/// 2026-08-12). Raw DTO to the render layer (CLAUDE.md boundary rule).
public struct IgniteColor: Sendable, Equatable {
    public let r: CGFloat
    public let g: CGFloat
    public let b: CGFloat
    public init(r: CGFloat, g: CGFloat, b: CGFloat) { self.r = r; self.g = g; self.b = b }

    /// The brightest channel (== the chosen HDR magnitude, since value == 1).
    public var peak: CGFloat { Swift.max(r, Swift.max(g, b)) }
    /// The dimmest channel — 0 for a full-saturation hue (the grey/white guard).
    public var floor: CGFloat { Swift.min(r, Swift.min(g, b)) }
}

public enum FinaleColor {

    /// HDR intensity band the ignited hue is scaled into (VISION §6 / PLAN GS-4:
    /// "4×–8× HDR intensity"). The unit hue (max channel 1) times a magnitude in
    /// this band ⇒ a peak channel of 4…8.
    public static let minIntensity: CGFloat = 4.0
    public static let maxIntensity: CGFloat = 8.0

    /// Deterministic, seeded ignite colour. A random hue at FULL saturation and
    /// unit value (so exactly one channel is 0 and one is 1 ⇒ never grey/white),
    /// scaled by a random HDR magnitude in [minIntensity, maxIntensity]. A pure
    /// function of `seed` (SplitMix64), so the renderer reproduces the same colour
    /// from the same per-proverb seed on every stateless-replay frame, and tests
    /// pin the rule.
    public static func ignite(seed: UInt64) -> IgniteColor {
        var rng = SplitMix64(seed: seed)
        // Draw the hue and magnitude with the stdlib bounded samplers over the
        // seeded generator (deterministic pure functions of the stream).
        let hue = CGFloat.random(in: 0 ..< 360, using: &rng)
        let intensity = CGFloat.random(in: minIntensity ... maxIntensity, using: &rng)
        let (r, g, b) = fullSaturationHueRGB(hue)   // s = 1, v = 1
        return IgniteColor(r: r * intensity, g: g * intensity, b: b * intensity)
    }

    /// HSV→RGB at saturation 1, value 1 — only the hue varies. Standard six-sextant
    /// formula; returns channels in [0,1] with `min == 0` and `max == 1` for every
    /// hue (this is exactly what makes the ignite colour a PURE colour, never
    /// grey/white). Internal — exposed to tests via `@testable import`.
    static func fullSaturationHueRGB(_ hueDegrees: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        // Wrap into [0,360) then into the sextant coordinate h ∈ [0,6).
        let wrapped = hueDegrees.truncatingRemainder(dividingBy: 360)
        let h = ((wrapped < 0 ? wrapped + 360 : wrapped)) / 60
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        switch Int(h) {   // h ∈ [0,6) ⇒ Int(h) ∈ 0…5
        case 0:  return (1, x, 0)
        case 1:  return (x, 1, 0)
        case 2:  return (0, 1, x)
        case 3:  return (0, x, 1)
        case 4:  return (x, 0, 1)
        default: return (1, 0, x)   // 5
        }
    }
}

public enum FinaleDissolve {

    /// Fraction of the dissolve over which emitters fire. Emission finishes at
    /// `emissionWindow`; the remaining tail (1 − emissionWindow) lets the last
    /// spawned particles fall and fade to black before the next proverb begins
    /// (VISION §6 "~2–3 s to black"). Named so the renderer sizes particle
    /// lifetimes against it.
    public static let emissionWindow: CGFloat = 0.6

    /// Dissolve progress ∈ [0, emissionWindow] at which emitter `i` (of `n`,
    /// ordered along the stroke polylines) is born. MONOTONE non-decreasing in
    /// `i`; emitter 0 fires at progress 0, emitter n−1 at `emissionWindow`. Pure —
    /// the renderer maps each sampled emitter position to a birth time via this;
    /// FinaleTests pins the monotonicity (deliverable 4). The cumulative born
    /// count #{ i : birthProgress(i) ≤ t } is therefore monotone in `t` for free.
    public static func emitterBirthProgress(_ i: Int, of n: Int) -> CGFloat {
        guard n > 1 else { return 0 }
        let clamped = Swift.min(Swift.max(i, 0), n - 1)
        let f = CGFloat(clamped) / CGFloat(n - 1)   // [0,1]
        return f * emissionWindow
    }
}
