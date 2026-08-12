//
//  GlyphSet.swift — parsed baked-glyph model + cursive queries
//  Module maturity: PROTOTYPE (slice GS-2)
//
//  Pure core (VISION constraint 2 / CLAUDE.md hard constraint 1): Foundation +
//  CoreGraphics value types ONLY. No AppKit / Metal / ScreenSaver. Proven by
//  `swift test`. In the SPM build this is its own module `GlyphCore`; in the
//  saver build the SAME files are compiled into the `GlyphSaver` module
//  alongside Sources/Saver (docs/PLAN.md deliverable 1) — hence `public`.
//
//  Ported semantics (behavioural reference is the game source, not memory —
//  CLAUDE.md hard constraint 3). Citations are to
//  ../zap-engine/examples/glypher/src/{glyphs.rs, game.rs}:
//    - exit_type default "Baseline"          glyphs.rs:48
//    - width default 1 (standard)            glyphs.rs:58
//    - get_strokes(ch, variant)              glyphs.rs:40
//    - variant_for (contextual alternate)    glyphs.rs:75
//    - effective_variant word-start override game.rs:288 + WORD_START_HIGH:49
//    - glyph_box_width ×0.5/×1.0/×1.3        game.rs:239 (GLYPH_BASE_W=600 :19)
//    - glyph_span 0.19/0.40/0.62             game.rs:570
//
//  ABSTRACTION LEDGER: the WidthClass/Variant/ExitType sum types replace the
//  game's stringly-typed "0/1/2" and "Baseline/High/Default" with closed
//  domain enums (mutually-exclusive states; CLAUDE.md domain-modeling rule).
//    - Users: GlyphSet queries + ProverbLayout (both concrete, this slice).
//    - Axis: variants FIXED, operations GROW → sum type + exhaustive `switch`.
//      Adding a width/variant deliberately breaks every switch (the feature).
//    - Rejected simpler: raw String/Int keys threaded through layout — no
//      compiler check that a variant/width is handled, name-not-semantics risk.
//

import Foundation
import CoreGraphics

/// Cursive entry variant for a glyph. JSON keys: "Baseline"/"High" (lowercase),
/// "Default" (uppercase & digits). glyphs.rs GlyphDef.variants.
public enum Variant: String, Sendable, Hashable, CaseIterable {
    case baseline = "Baseline"
    case high = "High"
    case `default` = "Default"
}

/// Exit type of a glyph — which entry variant the NEXT lowercase letter takes.
/// Absent in the data for uppercase/digits; queried as `.baseline` (glyphs.rs:48).
public enum ExitType: String, Sendable, Hashable {
    case baseline = "Baseline"
    case high = "High"
}

/// Character width class. game.rs glyph_box_width / glyph_span switch on 0/1/2.
public enum WidthClass: Int, Sendable, Hashable, CaseIterable {
    case narrow = 0     // e.g. i l t — 1efijltx in the shipped set
    case standard = 1
    case wide = 2       // M W m w

    /// Unknown raw values default to `.standard` (glyphs.rs:58 / game.rs:243 `_`).
    init(raw: Int) { self = WidthClass(rawValue: raw) ?? .standard }

    /// Box width in glyph units. GLYPH_BASE_W = 600 (game.rs:19); the class
    /// multiplies it ×0.5 / ×1.0 / ×1.3 (game.rs:239 glyph_box_width).
    public var boxWidthUnits: CGFloat {
        switch self {
        case .narrow:   return 600 * 0.5   // 300
        case .standard: return 600         // 600
        case .wide:     return 600 * 1.3   // 780
        }
    }

    /// Fraction of the [0,1] box the strokes actually span (game.rs:570
    /// glyph_span), derived by the game's authors from baked entry→exit extent.
    public var span: CGFloat {
        switch self {
        case .narrow:   return 0.19
        case .standard: return 0.40
        case .wide:     return 0.62
        }
    }
}

/// The baked glyph set: per-character strokes + cursive metadata, plus the
/// contextual-variant rules ported from the game. Value type; immutable after
/// parse. Coordinates are the raw normalized [0,1] glyph-box points from the
/// editor export (CGPoint, y-down: 0 = box top, 1 = box bottom).
public struct GlyphSet: Sendable {

    /// One parsed glyph.
    public struct Glyph: Sendable {
        public let width: WidthClass
        /// `nil` in the data for uppercase/digits (queried as `.baseline`).
        public let exit: ExitType?
        /// Variant → strokes → polyline of points.
        public let variants: [Variant: [[CGPoint]]]
    }

    private let glyphs: [Character: Glyph]

    /// meta.highExitLetters, kept for the parse oracle (the per-glyph `exit`
    /// field is the authority used by queries; this cross-checks the export).
    public let highExitLetters: Set<Character>

    // MARK: Parse

    public init(json: String) throws {
        guard let data = json.data(using: .utf8) else {
            throw GlyphSetError.notUTF8
        }
        try self.init(data: data)
    }

    public init(data: Data) throws {
        let raw = try JSONDecoder().decode(RawBaked.self, from: data)

        var parsed: [Character: Glyph] = [:]
        parsed.reserveCapacity(raw.glyphs.count)
        for (key, rg) in raw.glyphs {
            // Keys are single characters in the shipped set (a–z A–Z 0–9).
            guard key.count == 1, let ch = key.first else { continue }

            var variants: [Variant: [[CGPoint]]] = [:]
            for (vname, strokes) in rg.variants {
                guard let variant = Variant(rawValue: vname) else { continue }
                variants[variant] = strokes.map { stroke in
                    stroke.map { pair in
                        // Each point is [x, y]; ignore malformed shorter arrays.
                        CGPoint(x: pair.count > 0 ? CGFloat(pair[0]) : 0,
                                y: pair.count > 1 ? CGFloat(pair[1]) : 0)
                    }
                }
            }
            let exit = rg.exit.flatMap(ExitType.init(rawValue:))
            parsed[ch] = Glyph(width: WidthClass(raw: rg.width), exit: exit, variants: variants)
        }
        self.glyphs = parsed
        self.highExitLetters = Set(raw.meta.highExitLetters.compactMap { $0.first })
    }

    // MARK: Queries (glyphs.rs)

    /// Number of parsed glyphs (the parse oracle asserts 62 for the shipped set).
    public var count: Int { glyphs.count }

    /// glyphs.rs:67 has_char.
    public func hasChar(_ ch: Character) -> Bool { glyphs[ch] != nil }

    /// glyphs.rs:58 width — default `.standard` when the char is unknown.
    public func widthClass(_ ch: Character) -> WidthClass { glyphs[ch]?.width ?? .standard }

    /// glyphs.rs:48 exit_type — default `.baseline` (absent field / unknown char).
    public func exitType(_ ch: Character) -> ExitType { glyphs[ch]?.exit ?? .baseline }

    /// glyphs.rs:40 get_strokes — `nil` if the char or the variant is absent.
    public func strokes(for ch: Character, variant: Variant) -> [[CGPoint]]? {
        glyphs[ch]?.variants[variant]
    }

    /// The effective entry variant for `ch`, given the previous letter's exit
    /// and whether `ch` is the first letter of its word.
    ///
    /// This is game.rs:288 `effective_variant` composed with glyphs.rs:75
    /// `variant_for`:
    ///   1. word-start override — m/n/v/w at word start take `.high`
    ///      (game.rs:49 WORD_START_HIGH, :290);
    ///   2. otherwise lowercase follows `prevExit` (High→.high else .baseline);
    ///   3. uppercase & digits are always `.default`.
    ///
    /// DEVIATION from the slice's `variantFor(_:prevExit:)` signature: the
    /// word-start override is impossible to express from `prevExit` alone (a
    /// word-start letter and a mid-word letter can both follow a Baseline exit),
    /// so `atWordStart` is an explicit parameter. The stateful prev-exit CHAIN
    /// (tracking/resetting prevExit across a proverb) lives in ProverbLayout
    /// (slice deliverable 3); this is the per-letter RULE only.
    public func variantFor(_ ch: Character, prevExit: ExitType, atWordStart: Bool) -> Variant {
        if atWordStart && Self.wordStartHigh.contains(ch) { return .high }   // game.rs:290
        if Self.isASCIILowercase(ch) {                                        // glyphs.rs:76
            return prevExit == .high ? .high : .baseline
        }
        return .default                                                      // glyphs.rs:80
    }

    /// game.rs:49 WORD_START_HIGH — lowercase only (uppercase M/N/V/W stay
    /// `.default`; Character equality is case-sensitive so this holds).
    static let wordStartHigh: Set<Character> = ["m", "n", "v", "w"]

    /// Rust `char::is_ascii_lowercase` — a–z exactly (glyphs.rs:76).
    static func isASCIILowercase(_ ch: Character) -> Bool {
        guard let s = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        return s.value >= 0x61 && s.value <= 0x7A
    }
}

public enum GlyphSetError: Error, Sendable {
    case notUTF8
}

// MARK: - Raw Codable mirror of the editor export (glyphs.rs BakedGlyphs)

/// 1:1 with data/glyphs_baked.json. `width` here mirrors the per-glyph field
/// the game's `width()` reads (glyphs.rs:58) — verified equal to meta.widths in
/// the shipped export, so meta.widths is not consulted for width queries.
private struct RawBaked: Decodable {
    struct Meta: Decodable {
        let highExitLetters: [String]
    }
    struct Glyph: Decodable {
        let exit: String?
        let width: Int
        let variants: [String: [[[Double]]]]
    }
    let meta: Meta
    let glyphs: [String: Glyph]
}
