//
//  CelebrationScheduleTests.swift — the letter-celebration SCHEDULE, proven pure
//  Module maturity: PROTOTYPE (slice GS-4)
//
//  Deliverable 4 / review-1 item 4: make the verify.sh "t=19.3 s CELEBRATION"
//  claim VERIFIABLE from the pure schedule, not from a script comment or a
//  visual guess. The render layer's `ParticleField.letterBursts` fires a glyph's
//  25-spark burst while `local ∈ [complete, complete + letterBurstLifetime)`
//  where `complete` = the max stroke endTime of that glyph (its last stroke
//  finishing). Both the completion times and that window are decided ENTIRELY by
//  pure GlyphCore (WritingClock over the laid-out proverb), so the exact frame
//  the verify gate captures is reproducible headlessly here.
//
//  The completion schedule is VIEWPORT-INDEPENDENT: WritingClock stroke
//  durations are (pointCount − 1) / speed, and layout only transforms the baked
//  points' coordinates — it never resamples, so pointCount (hence every
//  completion time) is the same at any viewport. We still lay out at the
//  verify.sh world (960×600) so the reproduced glyph indices match the gate.
//

import XCTest
import CoreGraphics
@testable import GlyphCore

final class CelebrationScheduleTests: XCTestCase {

    // The verify.sh pin (scripts/verify.sh: GLYPHSAVER_SEED=7, t=19.3 s).
    private static let pinnedSeed: UInt64 = 7
    private static let verifyWorld = CGSize(width: 960, height: 600)   // aspect 1.6 (1280×800 ×2)
    private static let celebrationTime: CGFloat = 19.3

    // Mirror of the render-layer celebration windows so the pure test pins the
    // exact numbers the renderer/ParticleField use (game.rs:29 / game.rs:802).
    private static let goldFloodDuration: CGFloat = 1.2       // CELEBRATE_DURATION game.rs:29
    private static let burstLifetime: CGFloat = 1.5           // spawn_particles life game.rs:802
    private static let burstCount = 25                        // game.rs:797

    /// Reproduce the pinned schedule exactly as ZapRenderer.scheduled does for a
    /// small absolute time: seed the ProverbSequence, take the first pick.
    private func pinnedFirstProverb() throws -> (index: Int, layout: ProverbLayout.Layout, clock: WritingClock, text: String) {
        let glyphs = try GlyphSet(data: TestData.glyphsBakedJSON())
        let sayings = try TestData.sayings()
        var seq = ProverbSequence(seed: Self.pinnedSeed)
        let index = seq.next(count: sayings.count)
        let text = sayings[index]
        let layout = ProverbLayout.layout(proverb: text, glyphs: glyphs,
                                          viewport: Self.verifyWorld)
        return (index, layout, WritingClock(layout: layout), text)
    }

    /// Per-glyph completion time = max endTime over its drawable strokes — the
    /// exact key ParticleField.letterBursts builds (glyphIndex → max endTime).
    private func completionByGlyph(_ clock: WritingClock) -> [Int: CGFloat] {
        var out: [Int: CGFloat] = [:]
        for s in clock.strokes { out[s.glyphIndex] = max(out[s.glyphIndex] ?? 0, s.endTime) }
        return out
    }

    /// The pin itself: seed 7's first proverb is index 12, "Better late than
    /// never" (documents what verify.sh's two frames are frames OF). If the
    /// seedable RNG or sayings.json changes, this fails loudly — the gate's
    /// pinned times would no longer mean what the comment says.
    func testPinnedProverb_isBetterLateThanNever() throws {
        let p = try pinnedFirstProverb()
        XCTAssertEqual(p.index, 12, "seed-7 first pick changed — verify.sh pin is stale")
        XCTAssertEqual(p.text, "Better late than never")
    }

    /// THE VERIFY CLAIM, made checkable: at the pinned t=19.3 s a letter's gold
    /// flood AND its 25-spark burst are BOTH live, i.e. some glyph completed in
    /// (19.3 − 1.2, 19.3]. Prints the active glyph + its window so the reviewer
    /// can read exactly which letter the celebration frame shows.
    func testCelebrationFrame_hasLiveGoldFloodAndBurst() throws {
        let p = try pinnedFirstProverb()
        let completion = completionByGlyph(p.clock)
        let t = Self.celebrationTime

        // Gold flood live: local ∈ [complete, complete + 1.2).
        let flooding = completion.filter { t >= $0.value && t < $0.value + Self.goldFloodDuration }
        // Burst live: local ∈ [complete, complete + 1.5). (Superset of flooding.)
        let bursting = completion.filter { t >= $0.value && t < $0.value + Self.burstLifetime }

        XCTAssertFalse(bursting.isEmpty,
            "no glyph's 25-spark burst is live at t=\(t) — verify.sh's celebration frame claim is wrong")
        XCTAssertFalse(flooding.isEmpty,
            "no glyph's gold flood is live at t=\(t)")

        for (gi, complete) in bursting.sorted(by: { $0.key < $1.key }) {
            let ch = p.layout.glyphs[gi].character
            let age = t - complete
            print(String(format:
                "  celebration@%.2fs: glyph[%d]='%@' completed@%.4fs age=%.4fs " +
                "goldFlood=[%.4f,%.4f) burst(%d)=[%.4f,%.4f)",
                Double(t), gi, String(ch), Double(complete), Double(age),
                Double(complete), Double(complete + Self.goldFloodDuration),
                Self.burstCount, Double(complete), Double(complete + Self.burstLifetime)))
        }
    }

    /// The verify.sh comment states "a letter completed at 19.00 s". Pin that
    /// exact completion so the script's documented reasoning is enforced, not
    /// merely asserted in prose: some glyph completes within ±0.05 s of 19.00.
    func testVerifyComment_letterCompletesNear19_00() throws {
        let p = try pinnedFirstProverb()
        let completion = completionByGlyph(p.clock)
        let near = completion.values.contains { abs($0 - 19.00) < 0.05 }
        XCTAssertTrue(near,
            "no glyph completes near 19.00 s — verify.sh's t=19.3 rationale is stale; " +
            "completions=\(completion.values.sorted().map { String(format: "%.3f", Double($0)) })")
    }

    /// The two verify.sh frames land in DIFFERENT phases (celebration during
    /// writing; finale during dissolve) — the pure ground for "the frames must
    /// differ" gate. t=19.3 is `.writing`; t=51.6 is `.dissolving`.
    func testVerifyFrames_areInDistinctPhases() throws {
        let p = try pinnedFirstProverb()
        XCTAssertEqual(p.clock.phase(at: 19.3), .writing)
        if case .dissolving = p.clock.phase(at: 51.6) {} else {
            XCTFail("t=51.6 s expected .dissolving, got \(p.clock.phase(at: 51.6)) " +
                    "(writingDuration=\(p.clock.writingDuration))")
        }
    }
}
