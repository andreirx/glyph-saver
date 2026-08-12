//
//  CameraPlan.swift — pure world→view camera for the writing pull-back
//  Module maturity: PROTOTYPE (slice GS-3)
//
//  Pure core (VISION constraint 2 / CLAUDE.md hard constraint 1): Foundation +
//  CoreGraphics value types ONLY. Proven by `swift test`. Same file compiled
//  into the `GlyphSaver` module for the saver build — hence `public`.
//
//  WHAT THIS IS
//  -----------
//  A pure function `camera(at:layout:clock:)` giving, for an elapsed time within
//  a proverb, a uniform world→view transform (scale + focus) that the renderer
//  applies to INK / PEN / LIGHTS only (the leather is screen-fixed — VISION §3,
//  ratified). It opens framed on the first letter (one huge letter), pulls back
//  MONOTONICALLY as letters are written, and converges EXACTLY to the static
//  ProverbLayout framing (identity) by proverb end, staying there through
//  hold/fade.
//
//  MECHANISM — anticipatory keyframes + C1 interpolation
//  -----------------------------------------------------
//  (ratified 2026-08-12, OPERATOR_NOTE resolving DECISION cam-smoothing;
//   docs/PLAN.md CameraPlan entry). This SUPERSEDES two rejected mechanisms:
//    - a stateful exponential *lag* — provably violates always-contain during a
//      zoom-OUT (the lagged frame trails the growing content, so the newest
//      active letter falls outside until the lag catches up). Builder-surfaced,
//      operator-accepted.
//    - a per-frame closed-form *envelope / lag toward the final framing*
//      recomputed from "letters started by now": its tracked region is
//      piecewise-constant (it changes only when a new letter starts), so
//      scale/focus STEP at every letter and line break. This is what the human
//      saw jump in the field.
//  Because the whole layout is known up front, the camera ANTICIPATES:
//
//    * One KEYFRAME per written letter, at that letter's authored start time
//      (from WritingClock pacing). Keyframe k frames the padded union of the
//      ink boxes of letters 0…min(k+1, last) — a ONE-LETTER LOOKAHEAD, so the
//      frame already contains the next letter before the pen reaches it.
//        - first keyframe (k=0) = the opening: letter 0's box at ~65 % view
//          height (VISION §3 "one huge letter");
//        - last keyframe = the full-block framing == GS-2 static framing
//          (identity: scale 1, focus = viewport centre).
//      Keyframe scales are then clamped monotone non-increasing (clamping a
//      scale DOWN only widens the view, so it never breaks containment).
//    * Between keyframes k and k+1, interpolate with a shared smoothstep
//      parameter τ ∈ [0,1] — but in the u = 1/scale domain, together with the
//      focus. This makes the four view-rect EDGES exact convex combinations of
//      the two keyframes' edges:
//          left(τ) = focus.x(τ) − vp.x·u(τ)/2 = lerp(leftₖ, leftₖ₊₁, τ),
//      and likewise right/top/bottom. So any letter contained by BOTH endpoint
//      frames is contained by every intermediate frame — CONTAINMENT IS A
//      THEOREM, not a tuned hope. The active letter on [tₖ, tₖ₊₁) is letter k,
//      which the lookahead puts inside both keyframe k (letters 0…k+1) and
//      keyframe k+1 (letters 0…k+2). See CameraPlanTests.
//    * MONOTONE ZOOM-OUT: u(τ) = lerp(1/scaleₖ, 1/scaleₖ₊₁, τ) with scaleₖ ≥
//      scaleₖ₊₁ (monotone keyframes) and τ monotone in t ⇒ scale monotone
//      non-increasing across the whole proverb.
//    * C1 (no velocity jump at keyframes): smoothstep has zero derivative at
//      both ends of each segment, so du/dt = 0 and dfocus/dt = 0 at every
//      keyframe time — the curve joins with matching (zero) velocity. The
//      anti-jump gate (CameraPlanTests) bounds the per-frame delta numerically.
//
//  ABSTRACTION LEDGER: `Camera` is a raw DTO (scale + focus + viewport) crossing
//  to the render layer — no framework types (CLAUDE.md boundary rule). No
//  protocol/registry: one concrete camera, one axis of use. `CameraPlan` is a
//  namespace enum of pure functions; the `Keyframe` struct is a private local
//  DTO (no external user) — rejected simpler alternative: inlining the transform
//  in the renderer, which loses the test seam the deliverable requires.
//

import Foundation
import CoreGraphics

/// A uniform world→view transform. `view = (world − focus)·scale + viewport/2`.
/// `scale == 1, focus == viewport centre` is the identity (== GS-2 static
/// framing, since ProverbLayout lays world coords directly into the viewport).
public struct Camera: Sendable, Equatable {
    public let scale: CGFloat
    public let focus: CGPoint       // world point mapped to the viewport centre
    public let viewport: CGSize

    public init(scale: CGFloat, focus: CGPoint, viewport: CGSize) {
        self.scale = scale; self.focus = focus; self.viewport = viewport
    }

    public static func identity(viewport: CGSize) -> Camera {
        Camera(scale: 1,
               focus: CGPoint(x: viewport.width / 2, y: viewport.height / 2),
               viewport: viewport)
    }

    /// World → view (screen) coordinates.
    public func project(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - focus.x) * scale + viewport.width / 2,
                y: (p.y - focus.y) * scale + viewport.height / 2)
    }

    /// The world-space rectangle currently visible (the viewport back-projected).
    public var visibleWorldRect: CGRect {
        let w = viewport.width / scale, h = viewport.height / scale
        return CGRect(x: focus.x - w / 2, y: focus.y - h / 2, width: w, height: h)
    }
}

public enum CameraPlan {

    /// Opening: the first letter's ink box fills ~65 % of the view height…
    public static let verticalFillFraction: CGFloat = 0.65
    /// …and at most ~90 % of the view width (guards very wide first letters).
    public static let horizontalFillFraction: CGFloat = 0.90
    /// Per-side world padding around each tracked region, as a fraction of the
    /// viewport — breathing room so the active letter never sits on the edge.
    public static let framePaddingFraction: CGFloat = 0.06

    /// One anticipatory keyframe: at `time`, frame the tracked region at `scale`
    /// centred on `focus`. Private DTO — the interpolator's only input.
    private struct Keyframe {
        let time: CGFloat
        let scale: CGFloat
        let focus: CGPoint
    }

    /// The world→view camera at `elapsed` seconds into this proverb.
    public static func camera(at elapsed: CGFloat,
                              layout: ProverbLayout.Layout,
                              clock: WritingClock) -> Camera {
        let vp = layout.viewport
        let identity = Camera.identity(viewport: vp)
        guard vp.width > 0, vp.height > 0,
              !clock.strokes.isEmpty, !layout.glyphs.isEmpty,
              !layout.inkBounds.isNull else { return identity }

        // Static framing once writing ends (holding / fading / done). The last
        // keyframe is already the identity, so this joins continuously.
        if elapsed >= clock.writingDuration { return identity }

        let keys = keyframes(layout: layout, clock: clock)
        // Need an opening and a destination to interpolate between; a
        // single-letter proverb has no pull-back to perform.
        guard keys.count >= 2 else { return identity }

        // Before the first keyframe: the opening. At/after the last: hold it
        // (== identity), covering the final letter's own writing time.
        if elapsed <= keys[0].time { return camera(of: keys[0], vp: vp) }
        if elapsed >= keys[keys.count - 1].time { return camera(of: keys[keys.count - 1], vp: vp) }

        // Segment [k, k+1] with keys[k].time ≤ elapsed < keys[k+1].time. Start
        // times are strictly increasing (every letter has ≥1 positive-duration
        // stroke), so the segment is unique.
        var k = 0
        for i in 0..<(keys.count - 1) where keys[i].time <= elapsed { k = i }
        let a = keys[k], b = keys[k + 1]

        let span = b.time - a.time
        let x = span > 1e-9 ? max(0, min(1, (elapsed - a.time) / span)) : 1
        let tau = smoothstep(x)

        // Interpolate u = 1/scale and focus with the SAME τ ⇒ view-rect edges
        // are convex combinations of the endpoints ⇒ containment is inherited
        // (see header). u linear in monotone τ, uₐ ≤ u_b ⇒ scale monotone.
        let ua = 1 / a.scale, ub = 1 / b.scale
        let u = ua + (ub - ua) * tau
        let scale = 1 / u
        let focus = CGPoint(x: a.focus.x + (b.focus.x - a.focus.x) * tau,
                            y: a.focus.y + (b.focus.y - a.focus.y) * tau)
        return Camera(scale: scale, focus: focus, viewport: vp)
    }

    // MARK: - Keyframe construction

    /// The anticipatory keyframes in time order. Pure function of the layout +
    /// clock pacing (the layout is fully known up front — the reason the camera
    /// CAN anticipate). See the header for the k / lookahead / clamp rules.
    private static func keyframes(layout: ProverbLayout.Layout,
                                  clock: WritingClock) -> [Keyframe] {
        let boxes = letterBoxes(layout: layout, clock: clock)
        let n = boxes.count
        guard n >= 1 else { return [] }

        let vp = layout.viewport
        let padX = framePaddingFraction * vp.width
        let padY = framePaddingFraction * vp.height
        func fit(_ r: CGRect) -> CGFloat {
            let w = r.width + 2 * padX, h = r.height + 2 * padY
            guard w > 0, h > 0 else { return 1 }
            return min(vp.width / w, vp.height / h)
        }

        // Prefix union of ink boxes: prefix[i] = box0 ∪ … ∪ boxi.
        var prefix: [CGRect] = []
        var acc = CGRect.null
        for entry in boxes { acc = acc.union(entry.box); prefix.append(acc) }

        var out: [Keyframe] = []
        out.reserveCapacity(n)
        for k in 0..<n {
            let time = boxes[k].start
            if k == n - 1 {
                // Destination = full-block static framing == identity (GS-2).
                out.append(Keyframe(time: time, scale: 1,
                                    focus: CGPoint(x: vp.width / 2, y: vp.height / 2)))
            } else if k == 0 {
                // Opening: letter 0 at ~65 % height / ≤90 % width, on its centre.
                let b0 = boxes[0].box
                let s = max(1, min(verticalFillFraction * vp.height / max(b0.height, 1),
                                   horizontalFillFraction * vp.width / max(b0.width, 1)))
                out.append(Keyframe(time: time, scale: s,
                                    focus: CGPoint(x: b0.midX, y: b0.midY)))
            } else {
                // Lookahead: fit the padded union of letters 0…k+1, but never
                // zoom out PAST identity (scale 1). Identity already frames all
                // ink (ProverbLayout places it inside a margin), so scale 1 with
                // this region's centre still contains the region; clamping the
                // fit up to 1 keeps every keyframe ≥ 1 and lets the sequence
                // converge to the exact identity destination. (Without this,
                // fit(region) can dip below 1 — the layout margin plus this
                // padding exceed the viewport for near-full regions — and the
                // monotone clamp below would then drag the identity keyframe
                // under 1, breaking both "scale ≥ 1" and "final == identity".)
                let region = prefix[min(k + 1, n - 1)]
                out.append(Keyframe(time: time, scale: max(1, fit(region)),
                                    focus: CGPoint(x: region.midX, y: region.midY)))
            }
        }

        // Enforce monotone non-increasing scale. Clamping a keyframe's scale
        // DOWN only widens its view around the same focus, so its region (and
        // hence the active letter) stays contained — monotonicity for free,
        // containment preserved. The last keyframe is scale 1 and fit(full) ≥ 1
        // (the block fits the viewport by construction in ProverbLayout), so the
        // clamp never disturbs the exact identity destination.
        for i in 1..<out.count where out[i].scale > out[i - 1].scale {
            out[i] = Keyframe(time: out[i].time, scale: out[i - 1].scale, focus: out[i].focus)
        }
        return out
    }

    /// (earliest start time, ink bounding box) per written glyph, in writing
    /// order. Box = the glyph's actual inked extent; start = its first stroke's
    /// `startTime`. Only glyphs that appear in the timeline (≥1 drawable stroke)
    /// are included, so this list and `clock.strokes` agree on which letters exist.
    private static func letterBoxes(layout: ProverbLayout.Layout,
                                    clock: WritingClock)
        -> [(start: CGFloat, box: CGRect)] {
        var startByGlyph: [Int: CGFloat] = [:]
        for s in clock.strokes where startByGlyph[s.glyphIndex] == nil {
            startByGlyph[s.glyphIndex] = s.startTime      // strokes are start-ordered
        }
        var out: [(CGFloat, CGRect)] = []
        for (gi, start) in startByGlyph.sorted(by: { $0.value < $1.value }) {
            var box = CGRect.null
            for stroke in layout.glyphs[gi].strokes {
                for p in stroke { box = box.union(CGRect(origin: p, size: .zero)) }
            }
            if !box.isNull { out.append((start, box)) }
        }
        return out
    }

    // MARK: - Helpers

    /// Camera for a bare keyframe (before the first / at & after the last).
    private static func camera(of k: Keyframe, vp: CGSize) -> Camera {
        Camera(scale: k.scale, focus: k.focus, viewport: vp)
    }

    /// Smoothstep on [0,1]: monotone, with zero derivative at both ends (⇒ C1
    /// joins between segments).
    private static func smoothstep(_ x: CGFloat) -> CGFloat { x * x * (3 - 2 * x) }
}
