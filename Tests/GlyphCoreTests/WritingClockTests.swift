//
//  WritingClockTests.swift — the pen timeline + proverb selection
//  Module maturity: PROTOTYPE (slice GS-3)
//
//  Proves the pure writing timeline against the real data artifacts: exact phase
//  boundaries (game.rs pacing constants), monotonic ink progress, pen-position
//  continuity within a stroke, and no-immediate-repeat seeded selection.
//

import XCTest
import CoreGraphics
@testable import GlyphCore

final class WritingClockTests: XCTestCase {

    private func realGlyphs() throws -> GlyphSet {
        try GlyphSet(data: TestData.glyphsBakedJSON())
    }

    private func realLayout(_ proverb: String = "Good things come to those who wait")
        throws -> ProverbLayout.Layout {
        try ProverbLayout.layout(proverb: proverb, glyphs: realGlyphs(),
                                 viewport: CGSize(width: 960, height: 600))
    }

    // MARK: Phase machine — exact boundaries (game.rs:26/31, VISION §6)

    func testPhaseTransitions_atExactBoundaries() throws {
        let clock = try WritingClock(layout: realLayout())
        let w = clock.writingDuration
        let h = clock.holdDuration
        let f = clock.fadeDuration
        XCTAssertGreaterThan(w, 0)
        XCTAssertEqual(h, 12, accuracy: 1e-9)   // SAYING_CELEBRATE_DURATION game.rs:31
        XCTAssertEqual(f, 1,  accuracy: 1e-9)

        // Left-half-open boundaries: exactly at a boundary the NEXT phase holds.
        XCTAssertEqual(clock.phase(at: w - 1e-4), .writing)
        XCTAssertEqual(clock.phase(at: w),         .holding)
        XCTAssertEqual(clock.phase(at: w + h - 1e-4), .holding)
        XCTAssertEqual(clock.phase(at: w + h),        .fading(alpha: 1))
        XCTAssertEqual(clock.phase(at: w + h + f/2),  .fading(alpha: 0.5))
        XCTAssertEqual(clock.phase(at: w + h + f - 1e-6).isFading, true)
        XCTAssertEqual(clock.phase(at: w + h + f),    .done)
        XCTAssertEqual(clock.phase(at: clock.totalDuration + 100), .done)
    }

    func testStrokeTiming_speedIsSixtyPointsPerSecond() throws {
        let clock = try WritingClock(layout: realLayout())
        XCTAssertEqual(clock.speed, 60, accuracy: 1e-9)   // GUIDE_SPEED game.rs:26
        // Each stroke's duration is exactly (pointCount − 1) / 60.
        for s in clock.strokes {
            XCTAssertEqual(s.duration, CGFloat(s.pointCount - 1) / 60, accuracy: 1e-9)
        }
        // Strokes are contiguous and start-ordered (no gaps, no overlaps).
        for i in 1..<clock.strokes.count {
            XCTAssertEqual(clock.strokes[i].startTime, clock.strokes[i-1].endTime, accuracy: 1e-9)
        }
        XCTAssertEqual(clock.strokes.first?.startTime, 0)
        XCTAssertEqual(clock.strokes.last?.endTime ?? -1, clock.writingDuration, accuracy: 1e-9)
    }

    // MARK: Ink progress is monotonic and reaches exactly pointCount at endTime

    func testInkedPointCount_monotonicAndBounded() throws {
        let clock = try WritingClock(layout: realLayout())
        let s = try XCTUnwrap(clock.strokes.first(where: { $0.pointCount >= 3 }))
        var prev: CGFloat = -1
        // Sample across the whole stroke lifetime plus margins.
        var t = s.startTime - 0.1
        while t <= s.endTime + 0.1 {
            let inked = clock.inkedPointCount(s, at: t)
            XCTAssertGreaterThanOrEqual(inked, prev - 1e-9, "ink went backwards at t=\(t)")
            XCTAssertGreaterThanOrEqual(inked, 0)
            XCTAssertLessThanOrEqual(inked, CGFloat(s.pointCount) + 1e-9)
            prev = inked
            t += 0.01
        }
        XCTAssertEqual(clock.inkedPointCount(s, at: s.startTime - 0.001), 0)
        XCTAssertEqual(clock.inkedPointCount(s, at: s.startTime), 1, accuracy: 1e-9)
        XCTAssertEqual(clock.inkedPointCount(s, at: s.endTime), CGFloat(s.pointCount), accuracy: 1e-9)
        XCTAssertEqual(clock.inkedPointCount(s, at: s.endTime + 5), CGFloat(s.pointCount), accuracy: 1e-9)
    }

    // MARK: Pen position — continuous within a stroke, resets across boundaries

    func testPen_continuousWithinStroke_and_advancesInOrder() throws {
        let clock = try WritingClock(layout: realLayout())
        XCTAssertNotNil(clock.pen(at: 0))
        XCTAssertNil(clock.pen(at: clock.writingDuration))        // writing finished
        XCTAssertNil(clock.pen(at: clock.writingDuration + 1))

        // Ordinal is non-decreasing over time; pointPosition is continuous while
        // the ordinal is unchanged (no jump inside a stroke).
        var prevOrdinal = -1
        var prevPos: CGFloat = 0
        var t: CGFloat = 0
        let dt: CGFloat = 1.0 / 120.0
        while t < clock.writingDuration {
            let pen = try XCTUnwrap(clock.pen(at: t))
            XCTAssertGreaterThanOrEqual(pen.strokeOrdinal, prevOrdinal)
            if pen.strokeOrdinal == prevOrdinal {
                // Same stroke: the pen advanced by ~dt·speed, never jumped.
                XCTAssertGreaterThanOrEqual(pen.pointPosition, prevPos - 1e-9)
                XCTAssertLessThanOrEqual(pen.pointPosition - prevPos, dt * clock.speed + 1e-6)
            }
            let s = clock.strokes[pen.strokeOrdinal]
            XCTAssertGreaterThanOrEqual(pen.pointPosition, 0)
            XCTAssertLessThanOrEqual(pen.pointPosition, CGFloat(s.pointCount - 1) + 1e-9)
            prevOrdinal = pen.strokeOrdinal
            prevPos = pen.pointPosition
            t += dt
        }
        XCTAssertEqual(prevOrdinal, clock.strokes.count - 1)   // reached the last stroke
    }

    // MARK: Proverb selection — no immediate repeat, seeded & reproducible

    func testProverbSequence_neverImmediatelyRepeats() {
        var seq = ProverbSequence(seed: 0xABCD_1234)
        let count = 31
        var prev = -1
        for _ in 0..<5000 {
            let i = seq.next(count: count)
            XCTAssertTrue((0..<count).contains(i))
            XCTAssertNotEqual(i, prev, "immediate repeat is forbidden")
            prev = i
        }
    }

    func testProverbSequence_isDeterministicForASeed() {
        var a = ProverbSequence(seed: 42)
        var b = ProverbSequence(seed: 42)
        var c = ProverbSequence(seed: 43)
        var sameCount = 0, diffSeen = false
        for _ in 0..<1000 {
            let ia = a.next(count: 31), ib = b.next(count: 31), ic = c.next(count: 31)
            XCTAssertEqual(ia, ib)                 // same seed → identical stream
            if ia == ic { sameCount += 1 } else { diffSeen = true }
        }
        XCTAssertTrue(diffSeen, "a different seed should produce a different stream")
        XCTAssertLessThan(sameCount, 1000)
    }

    func testProverbSequence_coversTheWholeSet() {
        var seq = ProverbSequence(seed: 7)
        var seen = Set<Int>()
        for _ in 0..<20000 { seen.insert(seq.next(count: 31)) }
        XCTAssertEqual(seen.count, 31, "every proverb index should be reachable")
    }

    func testProverbSequence_singleElementIsStable() {
        var seq = ProverbSequence(seed: 1)
        for _ in 0..<10 { XCTAssertEqual(seq.next(count: 1), 0) }
    }

    /// GROSS-DISTRIBUTION SANITY CHECK — NOT proof of unbiasedness (review GS-3
    /// iter-1 #2). The stationary marginal of a uniform, no-immediate-repeat chain
    /// is uniform, so over many draws every index should be hit ≈ N/count times;
    /// with N=310_000, count=31 the expected per-bucket count is 10_000 (≈98 σ), so
    /// a ±5 % band is ~5σ and a fixed seed passes deterministically. What this
    /// catches is a GROSSLY broken sampler — one that clusters, skips indices, or
    /// truncates the range — NOT modulo bias.
    ///
    /// The ACTUAL unbiased-selection evidence is that `next(count:)` draws via
    /// `Int.random(in:using:)`, the standard library's rejection-sampled bounded
    /// generator. The rejected `rng.next() % 31` had modulo bias, but it is
    /// undetectable here: 2^64 ≡ 16 (mod 31), so the 16 low buckets are
    /// over-represented by only 31/2^64 ≈ 1.7e-18 relative — ~16 orders of
    /// magnitude below this test's ±5 % (or any finite-sample) resolution. This
    /// test therefore does NOT, and cannot, distinguish the biased reducer from the
    /// unbiased sampler; it only guards against gross malfunction.
    func testProverbSequence_isUniform() {
        let count = 31
        let n = 310_000
        var seq = ProverbSequence(seed: 0xABCD_EF01)
        var buckets = [Int](repeating: 0, count: count)
        for _ in 0..<n { buckets[seq.next(count: count)] += 1 }
        let expected = Double(n) / Double(count)
        for (i, c) in buckets.enumerated() {
            let dev = abs(Double(c) - expected) / expected
            XCTAssertLessThan(dev, 0.05,
                "index \(i) count \(c) deviates \(dev * 100)% from uniform")
        }
    }
}

private extension WritingClock.Phase {
    var isFading: Bool { if case .fading = self { return true }; return false }
}
