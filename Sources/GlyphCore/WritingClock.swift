//
//  WritingClock.swift — pure timeline for the invisible pen
//  Module maturity: PROTOTYPE (slice GS-3)
//
//  Pure core (VISION constraint 2 / CLAUDE.md hard constraint 1): Foundation +
//  CoreGraphics value types ONLY. No AppKit / Metal / ScreenSaver. Proven by
//  `swift test`. Same files compiled into the `GlyphSaver` module for the saver
//  build (see build.sh) — hence `public`.
//
//  WHAT THIS IS
//  -----------
//  Given a laid-out proverb (ProverbLayout.Layout) and an elapsed-seconds value,
//  this answers, without any rendering or I/O:
//    - which strokes are fully inked, and how far (arc-length) the pen has
//      travelled along the currently-active stroke;
//    - the ordered stroke timeline (authored order within a letter, letters in
//      reading order);
//    - the phase of the per-proverb lifecycle. GS-4 replaces the bare
//      writing → holding → fading → done tail with the ratified FINALE
//      (VISION §6 / PLAN GS-4): writing → holding → igniting → dissolving → done.
//  ProverbSequence adds uniform-random, never-immediately-repeating proverb
//  selection over a seedable RNG.
//
//  PACING (behavioural reference — CLAUDE.md hard constraint 3; citations to
//  ../zap-engine/examples/glypher/src/game.rs):
//    - GUIDE_SPEED = 60 path points / second (game.rs:26). Baked stroke points
//      are EVENLY spaced, so a constant points/second rate is a constant
//      arc-length speed. This is the ONE named speed constant
//      (`guideSpeedPointsPerSecond`).
//    - The FINALE dwell/ignite/dissolve durations are VISION §6 / PLAN GS-4, NOT
//      the game's SAYING_CELEBRATE_DURATION (12 s). VISION §6 supersedes that
//      static 12 s dwell (recorded human field observation: the long static hold
//      read dull) with a ~5 s admiring dwell followed by the ignite→dissolve
//      finale — a deliberate divergence from the game, whose saying-complete is
//      only a dwell light. `holdDurationSeconds` (5) / `igniteDurationSeconds`
//      (1.5) / `dissolveDurationSeconds` (2.5) are those ratified constants.
//
//  DEVIATION from the game's state machine (recorded): the game is
//  PLAYER-driven — its `guide_time` is a looping *hint* animation
//  (`guide_time % (len+40)`, game.rs:456-458) and the pen only advances when the
//  human traces. The saver has no player: the pen writes autonomously at
//  GUIDE_SPEED, once, straight through every stroke in order. So this is NOT a
//  port of `GamePhase`; it is the saver's own writer timeline, using only the
//  game's *pacing constants* for writing and its own ratified finale afterwards.
//
//  ABSTRACTION LEDGER:
//    - `WritingClock` (struct): the per-proverb timeline. Users: ZapRenderer +
//      CameraPlan + tests (all concrete, this slice). Axis: fixed operations
//      over one data shape → plain value type, no protocol. Rejected simpler:
//      recomputing stroke offsets ad hoc in the renderer (untestable, duplicated
//      in CameraPlan).
//    - `Phase` (enum): mutually-exclusive lifecycle states, each carrying only
//      its valid data (igniting/dissolving carry their own 0→1 progress) — the
//      domain-modeling rule. Fixed variants, growing match sites → sum type +
//      exhaustive switch. Adding a finale phase deliberately breaks every switch
//      (the ZapRenderer phase switch is the site that must react — the feature).
//    - `ProverbSequence` + `SplitMix64`: a seedable deterministic RNG is
//      REQUIRED by the deliverable ("seedable RNG for tests") and by the
//      renderer's need to reproduce the same schedule for a given absolute time.
//      SystemRandomNumberGenerator is neither seedable nor deterministic →
//      rejected. SplitMix64 is the standard tiny seedable generator.
//

import Foundation
import CoreGraphics

// MARK: - Seedable RNG

/// Deterministic, seedable 64-bit generator (SplitMix64, Steele et al. 2014).
/// Tiny and self-contained; the ONLY thing in the core that produces randomness.
/// Concrete users: `ProverbSequence`, tests, and (seeded) the renderer schedule.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { self.state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Uniform-random proverb selection that never immediately repeats the previous
/// pick (VISION §Experience 2 / deliverable 1). Stateful and seedable: with a
/// fixed seed the sequence is fully reproducible, which is what lets the
/// renderer reconstruct the same schedule from an absolute time each frame.
public struct ProverbSequence: Sendable {
    private var rng: SplitMix64
    private var last: Int?

    public init(seed: UInt64) { self.rng = SplitMix64(seed: seed) }

    /// Next index in `0..<count`, uniform over the `count-1` values that are not
    /// the previous pick (so no immediate repeat). With `count == 1` the only
    /// value (0) is unavoidably returned.
    ///
    /// UNIFORMITY: draws use `Int.random(in:using:)`, the standard-library
    /// UNBIASED bounded sampler (rejection-sampled internally). The earlier
    /// `rng.next() % count` had modulo bias — the 2^64 generator domain is not a
    /// multiple of 31, so low indices were slightly over-represented. Reusing the
    /// stdlib sampler (rather than reimplementing rejection here) keeps the draw
    /// unbiased AND deterministic: `Int.random(in:using:)` is a pure function of
    /// the generator's output stream, so a fixed-seed `SplitMix64` still yields a
    /// fully reproducible sequence.
    public mutating func next(count: Int) -> Int {
        precondition(count > 0, "proverb count must be positive")
        guard let last = last else {
            let i = Int.random(in: 0..<count, using: &rng)
            self.last = i
            return i
        }
        if count == 1 { return 0 }
        // Draw uniformly from the count-1 non-`last` values, then re-inflate:
        // mapping r∈[0,count-1) to skip `last` preserves uniformity over the
        // count-1 admissible values.
        let r = Int.random(in: 0..<(count - 1), using: &rng)
        let i = r >= last ? r + 1 : r
        self.last = i
        return i
    }
}

// MARK: - Writing timeline

public struct WritingClock: Sendable {

    // Named pacing constants — the ONLY timing knobs.
    public static let guideSpeedPointsPerSecond: CGFloat = 60   // GUIDE_SPEED  game.rs:26
    // FINALE durations (VISION §6 / PLAN GS-4, superseding game.rs:31's 12 s dwell).
    public static let holdDurationSeconds: CGFloat = 5          // admiring gold dwell
    public static let igniteDurationSeconds: CGFloat = 1.5      // cream → HDR hue ramp
    public static let dissolveDurationSeconds: CGFloat = 2.5    // ink-out + fireworks (2–3 s band)

    /// One drawable stroke placed in the writing timeline. Only strokes with ≥2
    /// points appear (a 0/1-point stroke has no arc length to animate and no
    /// ribbon to draw). `glyphIndex`/`strokeIndex` index back into the layout so
    /// the renderer fetches the actual polyline.
    public struct StrokeRef: Sendable {
        public let glyphIndex: Int
        public let strokeIndex: Int
        public let pointCount: Int
        public let startTime: CGFloat
        /// (pointCount − 1) / speed — the time to travel this stroke end to end.
        public let duration: CGFloat
        public var endTime: CGFloat { startTime + duration }
    }

    /// The pen at an instant during writing: which stroke is active and the
    /// fractional point-index (arc-length position) the tip has reached.
    public struct Pen: Sendable, Equatable {
        public let strokeOrdinal: Int      // index into `strokes`
        public let glyphIndex: Int
        public let strokeIndex: Int
        public let pointPosition: CGFloat  // in [0, pointCount − 1]
    }

    /// Per-proverb lifecycle (VISION §6 finale). Mutually-exclusive; the two
    /// finale ramps each carry ONLY their own 0→1 progress:
    ///   - `writing`  — the pen is drawing.
    ///   - `holding`  — the ~5 s admiring gold dwell.
    ///   - `igniting` — `t` ∈ [0,1] across the ignite ramp (cream → HDR hue).
    ///   - `dissolving` — `t` ∈ [0,1] across the dissolve (ink-out + fireworks).
    ///   - `done`     — finished; the schedule moves to the next proverb.
    public enum Phase: Sendable, Equatable {
        case writing
        case holding
        case igniting(t: CGFloat)
        case dissolving(t: CGFloat)
        case done
    }

    public let strokes: [StrokeRef]     // authored order; letters in reading order
    public let speed: CGFloat
    public let holdDuration: CGFloat
    public let igniteDuration: CGFloat
    public let dissolveDuration: CGFloat
    /// Wall-clock seconds to write every stroke (0 for a proverb with no ink).
    public let writingDuration: CGFloat

    public var totalDuration: CGFloat {
        writingDuration + holdDuration + igniteDuration + dissolveDuration
    }

    public init(layout: ProverbLayout.Layout,
                speed: CGFloat = guideSpeedPointsPerSecond,
                holdDuration: CGFloat = holdDurationSeconds,
                igniteDuration: CGFloat = igniteDurationSeconds,
                dissolveDuration: CGFloat = dissolveDurationSeconds) {
        self.speed = max(speed, 0.0001)
        self.holdDuration = holdDuration
        self.igniteDuration = max(igniteDuration, 0.0001)
        self.dissolveDuration = max(dissolveDuration, 0.0001)

        var refs: [StrokeRef] = []
        var t: CGFloat = 0
        for (gi, glyph) in layout.glyphs.enumerated() {
            for (si, stroke) in glyph.strokes.enumerated() where stroke.count >= 2 {
                let dur = CGFloat(stroke.count - 1) / self.speed
                refs.append(StrokeRef(glyphIndex: gi, strokeIndex: si,
                                      pointCount: stroke.count,
                                      startTime: t, duration: dur))
                t += dur
            }
        }
        self.strokes = refs
        self.writingDuration = t
    }

    /// Phase at `elapsed` (seconds since this proverb began). Boundaries are
    /// half-open on the left: exactly at `writingDuration` the phase is
    /// `.holding` (writing is finished); exactly at the hold end it is
    /// `.igniting(t: 0)`; exactly at the ignite end it is `.dissolving(t: 0)`.
    public func phase(at elapsed: CGFloat) -> Phase {
        if elapsed < writingDuration { return .writing }
        let afterWrite = elapsed - writingDuration
        if afterWrite < holdDuration { return .holding }
        let afterHold = afterWrite - holdDuration
        if afterHold < igniteDuration {
            return .igniting(t: max(0, min(1, afterHold / igniteDuration)))
        }
        let afterIgnite = afterHold - igniteDuration
        if afterIgnite < dissolveDuration {
            return .dissolving(t: max(0, min(1, afterIgnite / dissolveDuration)))
        }
        return .done
    }

    /// Fractional number of inked points of `s` at `elapsed`, in `0 ... pointCount`.
    /// 0 before the stroke starts; 1 the instant it starts (the pen sits on
    /// point 0); `pointCount` at/after `endTime`. Monotonic non-decreasing in
    /// `elapsed` (the renderer draws the ribbon up to this many points).
    public func inkedPointCount(_ s: StrokeRef, at elapsed: CGFloat) -> CGFloat {
        if elapsed < s.startTime { return 0 }
        return min(CGFloat(s.pointCount), 1 + (elapsed - s.startTime) * speed)
    }

    /// The pen during writing, or `nil` once writing is finished (holding/
    /// igniting/dissolving/done) or when there is no ink. The active stroke is the last one
    /// whose `startTime ≤ elapsed`; strokes are contiguous so there are no gaps.
    public func pen(at elapsed: CGFloat) -> Pen? {
        guard !strokes.isEmpty, elapsed < writingDuration else { return nil }
        var ordinal = 0
        for (i, s) in strokes.enumerated() {
            if s.startTime <= elapsed { ordinal = i } else { break }
        }
        let s = strokes[ordinal]
        let pos = min(CGFloat(s.pointCount - 1),
                      max(0, (elapsed - s.startTime) * speed))
        return Pen(strokeOrdinal: ordinal, glyphIndex: s.glyphIndex,
                   strokeIndex: s.strokeIndex, pointPosition: pos)
    }
}
