//
//  ProverbLayoutTests.swift — wrap/advance arithmetic, the coverage property,
//  and block-framing sanity.
//  Module maturity: PROTOTYPE (slice GS-2)
//
//  @testable to reach the internal wrap/advance helpers (no test-only public
//  surface). Arithmetic oracles are game.rs (glyph_box_width/glyph_span/
//  wrap_words_at_scale/word_gap).
//

import XCTest
import CoreGraphics
@testable import GlyphCore

final class ProverbLayoutTests: XCTestCase {

    private func loadReal() throws -> GlyphSet {
        try GlyphSet(data: TestData.glyphsBakedJSON())
    }

    // MARK: Advance / gap arithmetic (game.rs:581/591)

    func testCharAdvanceUnits_perWidthClass() throws {
        let gs = try loadReal()
        // standard 'a': 600 × 0.40 = 240
        XCTAssertEqual(ProverbLayout.charAdvanceUnits("a", in: gs), 240, accuracy: 1e-6)
        // narrow 'i': 300 × 0.19 = 57
        XCTAssertEqual(ProverbLayout.charAdvanceUnits("i", in: gs), 57, accuracy: 1e-6)
        // wide 'm': 780 × 0.62 = 483.6
        XCTAssertEqual(ProverbLayout.charAdvanceUnits("m", in: gs), 483.6, accuracy: 1e-4)
        // unknown char → standard default advance
        XCTAssertEqual(ProverbLayout.charAdvanceUnits("!", in: gs), 240, accuracy: 1e-6)
    }

    func testWordGapUnits() {
        // 600 × 0.40 × 0.5 = 120
        XCTAssertEqual(ProverbLayout.wordGapUnits, 120, accuracy: 1e-6)
    }

    // MARK: Wrap (game.rs:625 greedy) — synthetic widths for exact control

    func testWrapWords_greedyThresholds() {
        let w: [CGFloat] = [480, 480, 480]
        let gap: CGFloat = 120

        // tight: each word alone (480 + gap 120 + next 480 = 1080 > 480)
        XCTAssertEqual(ProverbLayout.wrapWords(w, gap: gap, maxUnits: 480), [[0], [1], [2]])
        // medium: two fit (1080 <= 1100), third breaks (1680 > 1100)
        XCTAssertEqual(ProverbLayout.wrapWords(w, gap: gap, maxUnits: 1100), [[0, 1], [2]])
        // wide: all one line (1680 <= 1700)
        XCTAssertEqual(ProverbLayout.wrapWords(w, gap: gap, maxUnits: 1700), [[0, 1, 2]])
    }

    func testWrapWords_overwideWordOccupiesOwnLine() {
        // A word wider than the limit still lands on its own line (Rust: breaks
        // only when the current line is non-empty).
        XCTAssertEqual(ProverbLayout.wrapWords([900], gap: 120, maxUnits: 400), [[0]])
        XCTAssertEqual(ProverbLayout.wrapWords([900, 200], gap: 120, maxUnits: 400), [[0], [1]])
    }

    func testLineWidthAndCandidateWidths() {
        let w: [CGFloat] = [480, 480]
        let gap: CGFloat = 120
        XCTAssertEqual(ProverbLayout.lineWidthUnits([0, 1], wordWidths: w, gap: gap), 1080, accuracy: 1e-6)
        XCTAssertEqual(ProverbLayout.lineWidthUnits([0], wordWidths: w, gap: gap), 480, accuracy: 1e-6)
        XCTAssertEqual(ProverbLayout.candidateWrapWidths(w, gap: gap), [480, 1080])
    }

    // MARK: Prev-exit CHAIN across the proverb (game.rs advance_letter)

    func testResolveVariants_chainsPrevExitWithinWord() throws {
        let gs = try loadReal()
        // "over": o starts the word (Baseline); o exits High → v uses High; v
        // exits High → e uses High; e exits Baseline → r uses Baseline.
        let r = ProverbLayout.resolveVariants(in: "over", glyphs: gs)
        XCTAssertEqual(r.map { $0.character }, ["o", "v", "e", "r"])
        XCTAssertEqual(r.map { $0.variant }, [.baseline, .high, .high, .baseline])
    }

    func testResolveVariants_resetsToBaselineAtWordStart() throws {
        let gs = try loadReal()
        // "ab ax": word 1 ends on 'b' (High exit). Word 2's first letter 'a' must
        // reset to Baseline (game.rs:392), NOT inherit 'b's High exit.
        let r = ProverbLayout.resolveVariants(in: "ab ax", glyphs: gs)
        let word2 = r.filter { $0.wordIndex == 1 }
        XCTAssertEqual(word2.first?.character, "a")
        XCTAssertEqual(word2.first?.variant, .baseline)
    }

    // MARK: The coverage property (slice deliverable 4)

    func testCoverage_everyNonSpaceCharOfEverySayingResolvesToAGlyphVariant() throws {
        let gs = try loadReal()
        let sayings = try TestData.sayings()
        XCTAssertEqual(sayings.count, 31)

        var checked = 0
        for saying in sayings {
            for rg in ProverbLayout.resolveVariants(in: saying, glyphs: gs) {
                XCTAssertTrue(gs.hasChar(rg.character),
                              "saying \"\(saying)\": no glyph for '\(rg.character)'")
                XCTAssertNotNil(gs.strokes(for: rg.character, variant: rg.variant),
                                "saying \"\(saying)\": '\(rg.character)' has no strokes for \(rg.variant)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    // MARK: Block framing (fit + centering)

    func testLayout_targetProverb_fitsAndCenters() throws {
        let gs = try loadReal()
        let proverb = "Good things come to those who wait"
        // 16:10 world viewport (renderer uses 600-tall world; width = 600×aspect).
        let viewport = CGSize(width: 960, height: 600)
        let margin: CGFloat = 0.06
        let layout = ProverbLayout.layout(proverb: proverb, glyphs: gs,
                                          viewport: viewport, marginFraction: margin)

        let nonSpace = proverb.filter { $0 != " " }.count
        XCTAssertEqual(layout.glyphs.count, nonSpace)
        XCTAssertGreaterThanOrEqual(layout.lineCount, 1)
        XCTAssertLessThanOrEqual(layout.lineCount, 7)          // ≤ word count
        XCTAssertGreaterThan(layout.scale, 0)

        // Every covered glyph produced ink.
        for g in layout.glyphs {
            XCTAssertFalse(g.strokes.isEmpty, "'\(g.character)' produced no strokes")
        }

        // The advance-block fits the margined viewport (fit-to-scale invariant).
        let availH = viewport.height * (1 - 2 * margin)
        let blockH = CGFloat(layout.lineCount) * ProverbLayout.lineHeightUnits * layout.scale
        XCTAssertLessThanOrEqual(blockH, availH + 1e-6)

        // Block is centered: the union of ink is centered on the viewport.
        // (Cursive box-overhang makes ink slightly exceed the advance block, so
        //  tolerances are loose; exact arithmetic is covered above.)
        XCTAssertFalse(layout.inkBounds.isNull)
        XCTAssertEqual(layout.inkBounds.midX, viewport.width / 2, accuracy: viewport.width * 0.06)
        XCTAssertEqual(layout.inkBounds.midY, viewport.height / 2, accuracy: viewport.height * 0.10)
    }

    func testLayout_emptyProverb_isEmpty() throws {
        let gs = try loadReal()
        let layout = ProverbLayout.layout(proverb: "   ", glyphs: gs,
                                          viewport: CGSize(width: 960, height: 600))
        XCTAssertEqual(layout.glyphs.count, 0)
        XCTAssertEqual(layout.lineCount, 0)
        XCTAssertTrue(layout.inkBounds.isNull)
    }
}
