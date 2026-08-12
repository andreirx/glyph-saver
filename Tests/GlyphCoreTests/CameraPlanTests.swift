//
//  CameraPlanTests.swift — the anticipatory keyframe pull-back camera
//  Module maturity: PROTOTYPE (slice GS-3)
//
//  The ratified GS-3 camera gates, asserted numerically against the real data:
//    (1) zoom-out is MONOTONIC (scale never increases);
//    (2) the ACTIVE letter's ink box is always inside the viewport — sampled at
//        every stroke/letter TRANSITION (± epsilon) plus a dense sweep, since the
//        invariant is all-times and transitions are the failure-prone instants;
//    (3) the FINAL frame equals the static ProverbLayout framing (identity);
//    (4) ANTI-JUMP — sampling camera(t) at 1/30 s across a full proverb, the max
//        per-frame |Δscale|/scale and |Δcentre| (in view units) are bounded well
//        below a single keyframe step. A stepped camera fails this as one huge
//        delta (OPERATOR_NOTE 2026-08-12: the human saw the old stepped camera
//        jump at every letter/line break).
//

import XCTest
import CoreGraphics
@testable import GlyphCore

final class CameraPlanTests: XCTestCase {

    private func realGlyphs() throws -> GlyphSet {
        try GlyphSet(data: TestData.glyphsBakedJSON())
    }

    private func fixture(_ proverb: String,
                         viewport: CGSize = CGSize(width: 960, height: 600))
        throws -> (ProverbLayout.Layout, WritingClock) {
        let layout = try ProverbLayout.layout(proverb: proverb, glyphs: realGlyphs(),
                                              viewport: viewport)
        return (layout, WritingClock(layout: layout))
    }

    /// Every proverb that must run through the camera in production.
    private func allSayings() throws -> [String] { try TestData.sayings() }

    /// A multi-line proverb (line breaks were the worst observed jumps) plus two
    /// others — the deliverable's "at least 3 sayings including a multi-line one".
    private let jumpProbeSayings = [
        "Good things come to those who wait",   // wraps to multiple lines
        "Actions speak louder than words",
        "The pen is mightier than the sword",
    ]

    // MARK: (1) Monotonic zoom-out

    func testZoomOut_isMonotonic_acrossAllSayings() throws {
        for saying in try allSayings() {
            let (layout, clock) = try fixture(saying)
            guard clock.writingDuration > 0 else { continue }
            var prevScale = CGFloat.greatestFiniteMagnitude
            var t: CGFloat = 0
            let dt = max(clock.totalDuration / 400, 1.0 / 60.0)
            while t <= clock.totalDuration {
                let cam = CameraPlan.camera(at: t, layout: layout, clock: clock)
                XCTAssertLessThanOrEqual(cam.scale, prevScale + 1e-6,
                    "scale increased (zoomed IN) at t=\(t) for \"\(saying)\"")
                XCTAssertGreaterThanOrEqual(cam.scale, 1 - 1e-9,
                    "scale went below identity (over-zoomed-out) for \"\(saying)\"")
                prevScale = cam.scale
                t += dt
            }
        }
    }

    func testOpening_isZoomedIn() throws {
        // A multi-line proverb must OPEN magnified (one huge letter), not at 1×.
        let (layout, clock) = try fixture("Good things come to those who wait")
        let open = CameraPlan.camera(at: 0, layout: layout, clock: clock)
        XCTAssertGreaterThan(open.scale, 1.5, "opening should be strongly zoomed in")
        // …and it should be framed on the first written letter, not the centre.
        let firstCenter = layout.glyphs.first!.center
        XCTAssertEqual(open.focus.x, firstCenter.x, accuracy: layout.viewport.width * 0.25)
    }

    // MARK: (2) Active letter box always inside the viewport — at every transition

    func testActiveLetterBox_alwaysInsideViewport_acrossAllSayings() throws {
        // The invariant is all-times, but the failure-prone instants are the
        // TRANSITIONS where the active stroke/letter changes (review GS-3 iter-0
        // #3). Sample every stroke boundary and an epsilon on either side, every
        // stroke's midpoint, AND a dense sweep, across every production saying —
        // not a fixed-count interval that can step over a boundary.
        let eps: CGFloat = 1e-4
        for saying in try allSayings() {
            let (layout, clock) = try fixture(saying)
            guard clock.writingDuration > 0 else { continue }
            let vp = layout.viewport

            var samples: [CGFloat] = []
            for s in clock.strokes {
                samples.append(s.startTime)
                samples.append(s.startTime - eps)          // previous letter still active
                samples.append(s.startTime + eps)          // new letter just became active
                samples.append(s.endTime - eps)            // stroke just before completion
                samples.append(s.startTime + s.duration / 2)   // mid-stroke
            }
            // Dense sweep for anything the boundaries miss.
            var t: CGFloat = 0
            let dt = max(clock.writingDuration / 400, 1.0 / 60.0)
            while t < clock.writingDuration { samples.append(t); t += dt }

            for st in samples where st >= 0 && st < clock.writingDuration {
                guard let pen = clock.pen(at: st) else { continue }
                let cam = CameraPlan.camera(at: st, layout: layout, clock: clock)
                // Every point of the active glyph's ink must project inside the
                // viewport (sub-pixel tolerance).
                for stroke in layout.glyphs[pen.glyphIndex].strokes {
                    for p in stroke {
                        let v = cam.project(p)
                        XCTAssert(v.x >= -0.5 && v.x <= vp.width + 0.5 &&
                                  v.y >= -0.5 && v.y <= vp.height + 0.5,
                            "active letter point \(v) left the viewport at t=\(st) for \"\(saying)\"")
                    }
                }
            }
        }
    }

    /// The opening frame already contains the whole first letter (the base case
    /// of the interpolation containment argument — keyframe 0 must contain letter
    /// 0). If this fails, "active letter inside" is no longer guaranteed at t=0.
    func testOpeningFrame_containsFirstLetter_acrossAllSayings() throws {
        for saying in try allSayings() {
            let (layout, clock) = try fixture(saying)
            guard !clock.strokes.isEmpty, !layout.inkBounds.isNull else { continue }
            let cam0 = CameraPlan.camera(at: 0, layout: layout, clock: clock)
            let firstGlyphIndex = clock.strokes.first!.glyphIndex
            let vp = layout.viewport
            for stroke in layout.glyphs[firstGlyphIndex].strokes {
                for p in stroke {
                    let v = cam0.project(p)
                    XCTAssert(v.x >= -0.5 && v.x <= vp.width + 0.5 &&
                              v.y >= -0.5 && v.y <= vp.height + 0.5,
                        "opening frame does not contain the first letter for \"\(saying)\"")
                }
            }
        }
    }

    // MARK: (3) Final frame equals the static ProverbLayout framing (identity)

    func testFinalFrame_equalsStaticFraming_acrossAllSayings() throws {
        for saying in try allSayings() {
            let (layout, clock) = try fixture(saying)
            let vp = layout.viewport
            // Sample during holding, during fading, and after done.
            for t in [clock.writingDuration,
                      clock.writingDuration + clock.holdDuration / 2,
                      clock.writingDuration + clock.holdDuration + clock.fadeDuration / 2,
                      clock.totalDuration + 10] {
                let cam = CameraPlan.camera(at: t, layout: layout, clock: clock)
                XCTAssertEqual(cam.scale, 1, accuracy: 1e-9, "not identity scale for \"\(saying)\"")
                // Identity transform: several world points map to themselves.
                for p in [CGPoint(x: 0, y: 0),
                          CGPoint(x: vp.width, y: vp.height),
                          CGPoint(x: vp.width / 2, y: vp.height / 2),
                          layout.inkBounds.origin] {
                    let v = cam.project(p)
                    XCTAssertEqual(v.x, p.x, accuracy: 1e-6)
                    XCTAssertEqual(v.y, p.y, accuracy: 1e-6)
                }
            }
        }
    }

    /// Scale converges to exactly 1 by the last letter (no pop into the hold):
    /// the last keyframe is the identity and is held through the final letter's
    /// own writing time.
    func testScale_convergesToOne_atEndOfWriting() throws {
        for saying in try allSayings() {
            let (layout, clock) = try fixture(saying)
            guard clock.writingDuration > 0 else { continue }
            let cam = CameraPlan.camera(at: clock.writingDuration - 1e-3,
                                        layout: layout, clock: clock)
            XCTAssertEqual(cam.scale, 1, accuracy: 1e-2,
                "scale should have reached ~1 by the last letter for \"\(saying)\"")
        }
    }

    // MARK: (4) ANTI-JUMP — bounded per-frame motion (the C1-interpolation gate)

    /// Sample camera(t) at 1/30 s across a full proverb's writing and assert the
    /// max per-frame relative scale change and centre motion (in view units) stay
    /// under named bounds. Anticipatory keyframes + smoothstep spread every
    /// keyframe transition across that segment's frames; a stepped camera would
    /// do the whole transition in ONE frame — hundreds of view units / tens of
    /// percent — and blow past these bounds. Bounds are set well below step
    /// magnitude and were verified empirically (see report).
    func testCamera_hasNoJumps_boundedPerFrameDelta() throws {
        // A frame = 1/30 s. A single keyframe step (the failure the human saw)
        // moves the content by a large fraction of the viewport in one frame —
        // hundreds of view units, tens of percent scale; a smooth ramp keeps each
        // frame's motion small. These bounds sit an order of magnitude below step
        // magnitude. Measured maxima on these sayings: |Δscale|/scale ≈ 0.0073,
        // |Δcentre| ≈ 5.0 view units; bounds are ≈3× that (headroom, not flaky).
        let maxScaleRelPerFrame: CGFloat = 0.02      // 2 % of current scale per frame
        let maxCentreViewPerFrame: CGFloat = 15.0    // view units (px at 960×600)
        let dt: CGFloat = 1.0 / 30.0

        for saying in jumpProbeSayings {
            let (layout, clock) = try fixture(saying)
            guard clock.writingDuration > 0 else { continue }
            var prev: Camera? = nil
            var t: CGFloat = 0
            while t <= clock.writingDuration {
                let cam = CameraPlan.camera(at: t, layout: layout, clock: clock)
                if let p = prev {
                    let dScaleRel = abs(cam.scale - p.scale) / max(p.scale, 1e-6)
                    // On-screen content motion = world focus shift × magnification.
                    let dFocus = hypot(cam.focus.x - p.focus.x, cam.focus.y - p.focus.y)
                    let dCentreView = dFocus * cam.scale
                    XCTAssertLessThan(dScaleRel, maxScaleRelPerFrame,
                        "scale jumped \(dScaleRel) at t=\(t) for \"\(saying)\"")
                    XCTAssertLessThan(dCentreView, maxCentreViewPerFrame,
                        "centre jumped \(dCentreView) view units at t=\(t) for \"\(saying)\"")
                }
                prev = cam
                t += dt
            }
        }
    }
}
