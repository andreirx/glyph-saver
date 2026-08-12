//
//  ProverbLayout.swift — proverb → positioned, variant-resolved stroke polylines
//  Module maturity: PROTOTYPE (slice GS-2)
//
//  Pure core (Foundation + CoreGraphics value types only). Produces the
//  "saying-complete" block: the whole proverb laid out large as a centered
//  multi-line block in a single world space, each glyph at its final position
//  and resolved cursive variant. GS-3's camera will animate over this fixed
//  layout; GS-2 renders it settled.
//
//  Ported from game.rs (behavioural reference, CLAUDE.md hard constraint 3):
//    - char advance = glyph_box_width(w) × glyph_span(w)      game.rs:581
//    - word gap = GLYPH_BASE_W × span(1) × WORD_GAP_FRACTION  game.rs:591 (:45)
//    - greedy word wrap                                       game.rs:625
//    - block: lines centered, block vertically centered,
//      line height = GLYPH_BASE_H × 1.1                       game.rs:705–757 (:726)
//    - glyph point → world: center + (p − 0.5) × boxScale     game.rs:610–614
//    - prev-exit chain, reset to Baseline at each word start  game.rs:382/392/283
//
//  DEVIATION from the game: the game FIXES scale (animates hint→0.30) against a
//  fixed max_width. GS-2 wants "the final block framing … uniform scale to fit a
//  given viewport with margins" (slice deliverable 3). Wrap width and absolute
//  scale are therefore not independent knobs here: we pick the word-wrap whose
//  uniform fit-scale is largest (best fill of the margined viewport) and derive
//  the scale from it. Same advance/gap/wrap/positioning arithmetic as the game;
//  only the choice of (line count, scale) is computed instead of animated.
//
//  Coordinate space: the renderer's world — y-down, origin top-left, viewport
//  == the lighting pass `projSize` (documented boundary convention; recorded so
//  the renderer maps ink/pen/lights identically). Core references no renderer.
//
//  ABSTRACTION LEDGER: no new type families beyond the plain result structs
//  below (positioned data crossing to the render layer = raw DTOs, CLAUDE.md
//  boundary rule). Wrap/advance helpers are `internal`, reached by tests via
//  `@testable import` — no test-only public surface.
//

import Foundation
import CoreGraphics

public enum ProverbLayout {

    // MARK: Constants (game.rs)

    static let glyphBaseHeight: CGFloat = 480        // GLYPH_BASE_H (game.rs:20)
    static let lineHeightFactor: CGFloat = 1.1       // game.rs:726
    static let wordGapFraction: CGFloat = 0.5        // WORD_GAP_FRACTION (game.rs:45)

    /// Word gap in glyph units: GLYPH_BASE_W × span(standard) × 0.5 (game.rs:591).
    static var wordGapUnits: CGFloat {
        WidthClass.standard.boxWidthUnits * WidthClass.standard.span * wordGapFraction
    }

    static var lineHeightUnits: CGFloat { glyphBaseHeight * lineHeightFactor }

    // MARK: Result DTOs

    /// One glyph placed in world space with its resolved variant. `strokes` is
    /// empty when the character has no data for the resolved variant (advance is
    /// still consumed, matching game.rs get_strokes==None → no strokes drawn).
    public struct PositionedGlyph: Sendable {
        public let character: Character
        public let variant: Variant
        public let strokes: [[CGPoint]]   // world coords, y-down
        public let center: CGPoint        // glyph box center in world coords
    }

    public struct Layout: Sendable {
        public let glyphs: [PositionedGlyph]
        public let scale: CGFloat
        public let lineCount: Int
        /// World-space bounding box of all inked points (`.null` if empty). The
        /// "final block framing" GS-3's camera converges to.
        public let inkBounds: CGRect
        public let viewport: CGSize
    }

    /// A glyph with its resolved variant, before positioning. `resolveVariants`
    /// is the prev-exit CHAIN (game.rs), exposed because GS-3 and the coverage
    /// test both need the resolved sequence without the geometry.
    public struct ResolvedGlyph: Sendable {
        public let character: Character
        public let variant: Variant
        public let wordIndex: Int
        public let letterIndex: Int
    }

    // MARK: Variant chain (game.rs prev_exit machine)

    /// Resolve each non-space character's cursive variant across the whole
    /// proverb: prev_exit starts Baseline and is set to exit_type(ch) after each
    /// letter (game.rs:382), and RESET to Baseline at every word start
    /// (game.rs:283/392). The word-start m/n/v/w→High override is applied per
    /// letter by GlyphSet.variantFor.
    public static func resolveVariants(in proverb: String, glyphs: GlyphSet) -> [ResolvedGlyph] {
        var out: [ResolvedGlyph] = []
        for (wi, word) in words(of: proverb).enumerated() {
            var prevExit: ExitType = .baseline           // reset at word start
            for (li, ch) in word.enumerated() {
                let variant = glyphs.variantFor(ch, prevExit: prevExit, atWordStart: li == 0)
                out.append(ResolvedGlyph(character: ch, variant: variant,
                                         wordIndex: wi, letterIndex: li))
                prevExit = glyphs.exitType(ch)
            }
        }
        return out
    }

    // MARK: Layout

    /// Lay out `proverb` as a centered multi-line block filling `viewport`
    /// (world units) inside a symmetric margin. `marginFraction` is the fraction
    /// of each axis reserved as margin on EACH side.
    public static func layout(proverb: String,
                              glyphs: GlyphSet,
                              viewport: CGSize,
                              marginFraction: CGFloat = 0.06) -> Layout {
        let wordList = words(of: proverb)
        guard !wordList.isEmpty, viewport.width > 0, viewport.height > 0 else {
            return Layout(glyphs: [], scale: 1, lineCount: 0,
                          inkBounds: .null, viewport: viewport)
        }

        // Per-word glyph groups (in reading order) and per-word advance widths.
        let resolved = resolveVariants(in: proverb, glyphs: glyphs)
        var byWord: [[ResolvedGlyph]] = Array(repeating: [], count: wordList.count)
        for r in resolved { byWord[r.wordIndex].append(r) }
        let wordWidths: [CGFloat] = byWord.map { group in
            group.reduce(0) { $0 + charAdvanceUnits($1.character, in: glyphs) }
        }

        let gap = wordGapUnits
        let availW = viewport.width * (1 - 2 * marginFraction)
        let availH = viewport.height * (1 - 2 * marginFraction)

        // Pick the word-wrap whose uniform fit-scale is largest. Candidate wrap
        // widths are the achievable contiguous-run widths; greedy wrap is
        // monotonic in the width, so these thresholds enumerate every distinct
        // partition. Tie → fewer lines (more readable).
        var best: (lines: [[Int]], scale: CGFloat)? = nil
        for maxUnits in candidateWrapWidths(wordWidths, gap: gap) {
            let lines = wrapWords(wordWidths, gap: gap, maxUnits: maxUnits)
            let blockW = lines.map { lineWidthUnits($0, wordWidths: wordWidths, gap: gap) }.max() ?? 0
            let blockH = CGFloat(lines.count) * lineHeightUnits
            guard blockW > 0, blockH > 0 else { continue }
            let scale = min(availW / blockW, availH / blockH)
            if let b = best {
                if scale > b.scale || (scale == b.scale && lines.count < b.lines.count) {
                    best = (lines, scale)
                }
            } else {
                best = (lines, scale)
            }
        }
        guard let chosen = best else {
            return Layout(glyphs: [], scale: 1, lineCount: 0,
                          inkBounds: .null, viewport: viewport)
        }

        let lines = chosen.lines
        let scale = chosen.scale

        // Vertical placement (game.rs:729–731): block centered in the viewport.
        let totalH = CGFloat(lines.count) * lineHeightUnits * scale
        let startCenterY = viewport.height / 2 - totalH / 2 + (lineHeightUnits * scale) / 2

        var placed: [PositionedGlyph] = []
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude

        for (row, line) in lines.enumerated() {
            let centerY = startCenterY + CGFloat(row) * lineHeightUnits * scale
            let lineW = lineWidthUnits(line, wordWidths: wordWidths, gap: gap) * scale
            var cursorX = (viewport.width - lineW) / 2   // line centered (game.rs:739)

            for wi in line {
                for rg in byWord[wi] {
                    let ch = rg.character
                    let wc = glyphs.widthClass(ch)
                    let advance = charAdvanceUnits(ch, in: glyphs) * scale
                    let centerX = cursorX + advance / 2

                    let boxWScaled = wc.boxWidthUnits * scale
                    let hScaled = glyphBaseHeight * scale
                    let center = CGPoint(x: centerX, y: centerY)

                    // glyph point → world (game.rs:610–614).
                    let worldStrokes: [[CGPoint]] =
                        (glyphs.strokes(for: ch, variant: rg.variant) ?? []).map { stroke in
                            stroke.map { p in
                                let wx = centerX + (p.x - 0.5) * boxWScaled
                                let wy = centerY + (p.y - 0.5) * hScaled
                                minX = min(minX, wx); maxX = max(maxX, wx)
                                minY = min(minY, wy); maxY = max(maxY, wy)
                                return CGPoint(x: wx, y: wy)
                            }
                        }
                    placed.append(PositionedGlyph(character: ch, variant: rg.variant,
                                                  strokes: worldStrokes, center: center))
                    cursorX += advance
                }
                cursorX += gap * scale
            }
        }

        let bounds = placed.contains(where: { !$0.strokes.isEmpty })
            ? CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            : .null

        return Layout(glyphs: placed, scale: scale, lineCount: lines.count,
                      inkBounds: bounds, viewport: viewport)
    }

    // MARK: Arithmetic helpers (internal — tested via @testable import)

    /// Character advance at scale 1 (glyph units): box width × span (game.rs:581).
    static func charAdvanceUnits(_ ch: Character, in glyphs: GlyphSet) -> CGFloat {
        let wc = glyphs.widthClass(ch)
        return wc.boxWidthUnits * wc.span
    }

    /// Greedy word wrap (game.rs:625 wrap_words_at_scale) — units in, partition
    /// of word indices out. A word wider than `maxUnits` still occupies its own
    /// line (it only breaks when the current line is non-empty), matching Rust.
    static func wrapWords(_ wordWidths: [CGFloat], gap: CGFloat, maxUnits: CGFloat) -> [[Int]] {
        var lines: [[Int]] = [[]]
        var widths: [CGFloat] = [0]
        for wi in wordWidths.indices {
            let ww = wordWidths[wi]
            let empty = lines[lines.count - 1].isEmpty
            let cur = widths[widths.count - 1]
            let needed = empty ? ww : gap + ww
            if cur + needed > maxUnits && !empty {
                lines.append([wi]); widths.append(ww)
            } else {
                lines[lines.count - 1].append(wi)
                widths[widths.count - 1] = cur + needed
            }
        }
        return lines
    }

    /// Width of a line (word indices) in glyph units: word advances + inter-word gaps.
    static func lineWidthUnits(_ line: [Int], wordWidths: [CGFloat], gap: CGFloat) -> CGFloat {
        guard !line.isEmpty else { return 0 }
        let sum = line.reduce(0) { $0 + wordWidths[$1] }
        return sum + gap * CGFloat(line.count - 1)
    }

    /// Distinct wrap-width thresholds: every achievable contiguous-run width
    /// plus the full single line. Greedy wrap is monotonic in the threshold, so
    /// evaluating these yields every distinct partition.
    static func candidateWrapWidths(_ wordWidths: [CGFloat], gap: CGFloat) -> [CGFloat] {
        var set = Set<CGFloat>()
        for i in wordWidths.indices {
            var run: CGFloat = 0
            for j in i..<wordWidths.count {
                run += wordWidths[j]
                if j > i { run += gap }
                set.insert(run)
            }
        }
        return set.sorted()
    }

    // MARK: Word split

    /// game.rs pick_saying: split_whitespace (drop empty runs).
    static func words(of proverb: String) -> [Substring] {
        proverb.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
    }

    private static func group_ch(_ rg: ResolvedGlyph) -> Character { rg.character }
}
