//
//  GlyphSetTests.swift — parse oracle + variant/exit/width rule oracle
//  Module maturity: PROTOTYPE (slice GS-2)
//
//  Oracles are the game source (glyphs.rs/game.rs) and the verified data facts
//  in docs/VISION.md. @testable to reach the internal ASCII helper.
//

import XCTest
@testable import GlyphCore

final class GlyphSetTests: XCTestCase {

    private func loadReal() throws -> GlyphSet {
        try GlyphSet(data: TestData.glyphsBakedJSON())
    }

    // MARK: Parse oracle (slice deliverable 4)

    func testParsesRealGlyphs_62_withHighExitExactlyBOVW() throws {
        let gs = try loadReal()

        // 62 glyphs: a–z A–Z 0–9 exactly.
        XCTAssertEqual(gs.count, 62)
        let expected = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        for ch in expected { XCTAssertTrue(gs.hasChar(ch), "missing glyph \(ch)") }
        XCTAssertFalse(gs.hasChar(" "))
        XCTAssertFalse(gs.hasChar("!"))

        // meta.highExitLetters is exactly {b,o,v,w}…
        XCTAssertEqual(gs.highExitLetters, Set("bovw"))
        // …and the per-glyph exit field (the query authority) agrees: exit ==
        // .high for exactly b,o,v,w across the whole set (VISION verified fact).
        let highExit = expected.filter { gs.exitType($0) == .high }
        XCTAssertEqual(highExit, Set("bovw"))
    }

    func testWidthClasses_matchShippedData() throws {
        let gs = try loadReal()
        // Verified from data (build report): width-0 = 1efijltx, width-2 = MWmw.
        for ch in "1efijltx" { XCTAssertEqual(gs.widthClass(ch), .narrow, "\(ch)") }
        for ch in "MWmw"     { XCTAssertEqual(gs.widthClass(ch), .wide, "\(ch)") }
        // A representative standard letter and the unknown-char default.
        XCTAssertEqual(gs.widthClass("a"), .standard)
        XCTAssertEqual(gs.widthClass(" "), .standard)   // unknown → default 1
    }

    func testStrokesLookup_lowercaseHasBothVariants_uppercaseOnlyDefault() throws {
        let gs = try loadReal()
        XCTAssertNotNil(gs.strokes(for: "a", variant: .baseline))
        XCTAssertNotNil(gs.strokes(for: "a", variant: .high))
        XCTAssertNil(gs.strokes(for: "a", variant: .default))

        XCTAssertNotNil(gs.strokes(for: "A", variant: .default))
        XCTAssertNil(gs.strokes(for: "A", variant: .baseline))
        XCTAssertNil(gs.strokes(for: "A", variant: .high))

        XCTAssertNil(gs.strokes(for: " ", variant: .baseline)) // unknown char
    }

    // MARK: Variant-rule oracle (glyphs.rs variant_for + game.rs effective_variant)

    func testVariantOracle_contextualAndWordStart() throws {
        let gs = try loadReal()

        // after high-exit → High (lowercase, mid-word)
        XCTAssertEqual(gs.variantFor("a", prevExit: .high, atWordStart: false), .high)
        // after baseline → Baseline
        XCTAssertEqual(gs.variantFor("a", prevExit: .baseline, atWordStart: false), .baseline)

        // uppercase → Default regardless of prevExit / word position
        XCTAssertEqual(gs.variantFor("A", prevExit: .high, atWordStart: false), .default)
        XCTAssertEqual(gs.variantFor("A", prevExit: .baseline, atWordStart: true), .default)
        // digit → Default
        XCTAssertEqual(gs.variantFor("7", prevExit: .high, atWordStart: false), .default)

        // word-start m/n/v/w → High even after a Baseline reset (game.rs:290)
        for ch in "mnvw" {
            XCTAssertEqual(gs.variantFor(ch, prevExit: .baseline, atWordStart: true), .high, "\(ch)")
        }
        // …but the same letters mid-word after Baseline follow the chain → Baseline
        for ch in "mnvw" {
            XCTAssertEqual(gs.variantFor(ch, prevExit: .baseline, atWordStart: false), .baseline, "\(ch)")
        }
        // a non-override letter at word start (after Baseline reset) → Baseline
        XCTAssertEqual(gs.variantFor("a", prevExit: .baseline, atWordStart: true), .baseline)
        // uppercase word-start letter is NOT overridden (case-sensitive set)
        XCTAssertEqual(gs.variantFor("M", prevExit: .baseline, atWordStart: true), .default)
    }

    func testASCIILowercaseHelper() {
        XCTAssertTrue(GlyphSet.isASCIILowercase("a"))
        XCTAssertTrue(GlyphSet.isASCIILowercase("z"))
        XCTAssertFalse(GlyphSet.isASCIILowercase("A"))
        XCTAssertFalse(GlyphSet.isASCIILowercase("7"))
        XCTAssertFalse(GlyphSet.isASCIILowercase(" "))
    }
}
