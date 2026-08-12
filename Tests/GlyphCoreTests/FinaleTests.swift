//
//  FinaleTests.swift — the pure finale rules (ignite colour + dissolve schedule)
//  Module maturity: PROTOTYPE (slice GS-4)
//
//  Deliverable 4: the DECIDABLE parts of the finale, proven headless (particle
//  RENDERING is judged visually, not here):
//    - ignite colour rule: full-saturation floor (never grey/white), the 4×–8×
//      HDR magnitude band, and seeded determinism;
//    - dissolve emission schedule monotonicity (per-emitter birth order and the
//      cumulative born count in dissolve progress).
//

import XCTest
import CoreGraphics
@testable import GlyphCore

final class FinaleTests: XCTestCase {

    // MARK: Ignite colour — full saturation (grey/white excluded)

    /// For every seed the ignited colour is a PURE hue: the dimmest channel is
    /// exactly 0 and the brightest is strictly positive ⇒ r,g,b are never all
    /// equal ⇒ never grey and never white (VISION §6). Swept over many seeds.
    func testIgnite_isFullSaturation_neverGreyOrWhite() {
        for s in stride(from: UInt64(0), through: 20_000, by: 1) {
            let c = FinaleColor.ignite(seed: s)
            XCTAssertEqual(c.floor, 0, accuracy: 1e-9,
                "seed \(s): min channel must be 0 (saturation 1)")
            XCTAssertGreaterThan(c.peak, 0, "seed \(s): a colour must have a bright channel")
            // Grey/white ⇒ all three channels equal. Full saturation forbids it.
            XCTAssertNotEqual(c.peak, c.floor, "seed \(s): grey/white is excluded")
        }
    }

    /// The bright channel sits in the ratified 4×–8× HDR band (VISION §6). Because
    /// the unit hue has max channel exactly 1, `peak` equals the drawn magnitude.
    func testIgnite_peakIsInHDRBand() {
        for s in stride(from: UInt64(1), through: 20_000, by: 1) {
            let c = FinaleColor.ignite(seed: s)
            XCTAssertGreaterThanOrEqual(c.peak, FinaleColor.minIntensity - 1e-9,
                "seed \(s): peak \(c.peak) below 4×")
            XCTAssertLessThanOrEqual(c.peak, FinaleColor.maxIntensity + 1e-9,
                "seed \(s): peak \(c.peak) above 8×")
        }
    }

    /// Seeded ⇒ deterministic: the same seed reproduces the same colour (the
    /// renderer relies on this for stateless per-frame replay), and different
    /// seeds explore a range of hues (not a constant).
    func testIgnite_isDeterministicAndVaries() {
        for s in stride(from: UInt64(0), through: 500, by: 1) {
            XCTAssertEqual(FinaleColor.ignite(seed: s), FinaleColor.ignite(seed: s))
        }
        var hues = Set<Int>()
        for s in stride(from: UInt64(0), through: 2_000, by: 1) {
            let c = FinaleColor.ignite(seed: s)
            // Bucket by the argmax channel + a coarse ratio — a crude hue proxy;
            // a constant colour would collapse this to one bucket.
            let key = Int((c.r * 3 + c.g * 5 + c.b * 7) / max(c.peak, 1e-6) * 10)
            hues.insert(key)
        }
        XCTAssertGreaterThan(hues.count, 20, "ignite hue should vary widely across seeds")
    }

    /// The full-saturation HSV→RGB helper: min==0, max==1 at every hue, including
    /// the six primary/secondary vertices and wrap-around inputs.
    func testFullSaturationHueRGB_minZeroMaxOne() {
        for deg in stride(from: -720.0, through: 720.0, by: 1.0) {
            let (r, g, b) = FinaleColor.fullSaturationHueRGB(CGFloat(deg))
            XCTAssertEqual(min(r, min(g, b)), 0, accuracy: 1e-9, "hue \(deg): min not 0")
            XCTAssertEqual(max(r, max(g, b)), 1, accuracy: 1e-9, "hue \(deg): max not 1")
            for ch in [r, g, b] { XCTAssert(ch >= -1e-9 && ch <= 1 + 1e-9) }
        }
    }

    // MARK: Dissolve emission schedule — monotonicity

    /// Emitter birth progress is monotone non-decreasing in the emitter index,
    /// starts at 0, and ends at `emissionWindow` — the pure schedule the renderer
    /// drives (deliverable 4).
    func testEmitterBirthProgress_monotoneInIndex() {
        for n in [1, 2, 7, 64, 513] {
            var prev = -CGFloat.greatestFiniteMagnitude
            for i in 0..<n {
                let p = FinaleDissolve.emitterBirthProgress(i, of: n)
                XCTAssertGreaterThanOrEqual(p, prev - 1e-12, "n=\(n) i=\(i): went backwards")
                XCTAssertGreaterThanOrEqual(p, 0)
                XCTAssertLessThanOrEqual(p, FinaleDissolve.emissionWindow + 1e-12)
                prev = p
            }
            if n > 1 {
                XCTAssertEqual(FinaleDissolve.emitterBirthProgress(0, of: n), 0, accuracy: 1e-12)
                XCTAssertEqual(FinaleDissolve.emitterBirthProgress(n - 1, of: n),
                               FinaleDissolve.emissionWindow, accuracy: 1e-12)
            }
        }
    }

    /// The cumulative born count #{ i : birthProgress(i) ≤ t } is monotone
    /// non-decreasing as dissolve progress `t` advances, is 0 before t=0, and
    /// reaches the full emitter total once t ≥ emissionWindow.
    func testDissolveBornCount_monotoneInProgress() {
        let n = 200
        func bornCount(at t: CGFloat) -> Int {
            (0..<n).reduce(0) { $0 + (FinaleDissolve.emitterBirthProgress($1, of: n) <= t ? 1 : 0) }
        }
        XCTAssertEqual(bornCount(at: -0.001), 0)
        var prev = -1
        var t: CGFloat = 0
        while t <= 1.0 + 1e-9 {
            let c = bornCount(at: t)
            XCTAssertGreaterThanOrEqual(c, prev, "born count decreased at t=\(t)")
            prev = c
            t += 1.0 / 240.0
        }
        XCTAssertEqual(bornCount(at: FinaleDissolve.emissionWindow + 1e-6), n,
            "all emitters born once t ≥ emissionWindow")
        XCTAssertEqual(bornCount(at: 1.0), n)
    }
}
