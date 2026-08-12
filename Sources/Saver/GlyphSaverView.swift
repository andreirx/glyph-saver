//
//  GlyphSaverView.swift — ScreenSaverView host for the Metal renderer
//  Module maturity: PROTOTYPE (slice GS-1)
//
//  The principal class of the .saver bundle (Info.plist NSPrincipalClass =
//  "GlyphSaverView", matched by the @objc name below). It hosts a bare
//  CAMetalLayer (not an MTKView — a screensaver owns its NSView) configured for
//  EDR exactly as the ZapZap donor configures its layer
//  (ZapZap macOS/GameViewController.swift:32–39): .rgba16Float +
//  extendedLinearDisplayP3 + wantsExtendedDynamicRangeContent. On this machine's
//  panel (maximumPotentialEDR = 1.0) output is tone-limited SDR today; an XDR
//  display gets real headroom with no code change (VISION experience §8).
//
//  Timing: animationTimeInterval = 1/30; one frame rendered per animateOneFrame.
//  isPreview needs no special path — the smaller bounds give a smaller layer
//  and the same two-pass render.
//

import ScreenSaver
import Metal
import QuartzCore
import CoreGraphics
import Foundation

@objc(GlyphSaverView)
final class GlyphSaverView: ScreenSaverView {
    private let device: MTLDevice?
    private let metalLayer = CAMetalLayer()
    private var renderer: ZapRenderer?
    private var elapsed: CFTimeInterval = 0
    private var lastDrawableSize: CGSize = .zero

    override init?(frame: NSRect, isPreview: Bool) {
        self.device = MTLCreateSystemDefaultDevice()
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 30.0
        wantsLayer = true

        guard let device = device else {
            NSLog("GlyphSaverView: no Metal device")
            return
        }
        configureMetalLayer(device: device)
        layer?.addSublayer(metalLayer)
        renderer = ZapRenderer(device: device,
                               pixelFormat: .rgba16Float,
                               bundle: Bundle(for: GlyphSaverView.self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func configureMetalLayer(device: MTLDevice) {
        metalLayer.device = device
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
    }

    // ScreenSaverView is layer-backed; keep the metal layer sized to the view
    // and its drawable sized to the backing pixels.
    override func layout() {
        super.layout()
        updateLayerGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateLayerGeometry()
    }

    private func updateLayerGeometry() {
        let scale = window?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 0, size.height > 0, size != lastDrawableSize else { return }
        metalLayer.drawableSize = size
        renderer?.resize(size)
        lastDrawableSize = size
    }

    override func startAnimation() { super.startAnimation() }
    override func stopAnimation() { super.stopAnimation() }

    override func animateOneFrame() {
        if lastDrawableSize == .zero { updateLayerGeometry() }
        elapsed += animationTimeInterval
        renderer?.render(to: metalLayer, time: elapsed)
    }

    // Rendering is driven by animateOneFrame straight to the CAMetalLayer;
    // AppKit's draw(_:) has nothing to do.
    override func draw(_ rect: NSRect) {}

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

    // MARK: - Verification seam (scripts/verify.sh, PLAN.md "Test hosts" layer 2)
    //
    // Renders ONE frame through THIS view's own renderer, pixel format, and
    // backing size at an explicit animation time, and hands it back as a
    // CPU-side CGImage — no CAMetalLayer drawable, no window server, no file
    // writes (VISION constraint 1: the running saver writes nothing; the caller
    // owns the PNG, not this class).
    //
    // Why not just call animateOneFrame()? The live path presents to the
    // CAMetalLayer via nextDrawable(); an *unattached* layer's nextDrawable is
    // undocumented/flaky offscreen (the same reason ZapRenderer keeps a
    // renderFrameSynchronously seam). So offscreen capture routes through the
    // view's own `renderer` into a CPU-readable texture instead.
    //
    // This is NOT a renderer-only harness: the caller holds a real
    // GlyphSaverView built from the loaded .saver bundle via
    // initWithFrame:isPreview:, and everything below uses the view's own
    // `renderer`, `device`, .rgba16Float format, and backing geometry. Exposed
    // to Objective-C so scripts/verify_host.m can drive it without linking the
    // Swift module. Never called by the live saver.
    @objc(renderVerificationFrameAtTime:)
    func renderVerificationFrame(atTime t: Double) -> CGImage? {
        renderVerificationFrame(atTime: t, inkWidthGlyphUnits: 0)
    }

    // Width-override variant (operator note 2026-08-12): render the SAME frame at
    // a non-default ink width for the human width-legibility comparison
    // (verify-width28.png). `inkWidthGlyphUnits <= 0` means "use the ratified
    // default" so the plain seam above is a thin wrapper. Verification-only.
    @objc(renderVerificationFrameAtTime:inkWidthGlyphUnits:)
    func renderVerificationFrame(atTime t: Double, inkWidthGlyphUnits: Double) -> CGImage? {
        guard let renderer = renderer, let device = device else { return nil }
        let scale = window?.backingScaleFactor ?? 2.0
        let ptW = bounds.width  > 0 ? bounds.width  : frame.width
        let ptH = bounds.height > 0 ? bounds.height : frame.height
        let w = max(1, Int(ptW * scale))
        let h = max(1, Int(ptH * scale))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget]
        desc.storageMode = .shared   // Apple Silicon unified memory: CPU-readable render target.
        guard let target = device.makeTexture(descriptor: desc) else { return nil }

        let widthOverride: Float? = inkWidthGlyphUnits > 0 ? Float(inkWidthGlyphUnits) : nil
        renderer.renderFrameSynchronously(into: target, time: t, inkWidthGlyphUnits: widthOverride)
        return GlyphSaverView.cgImage(from: target)
    }

    /// Read an rgba16Float (extended-linear) texture back to the CPU and encode
    /// it as an 8-bit sRGB CGImage for a human-legible verification PNG. Values
    /// beyond 1.0 (EDR headroom) clamp to SDR; linear→sRGB is applied so the
    /// near-dark scene reads correctly to the eye. Verification-only.
    private static func cgImage(from tex: MTLTexture) -> CGImage? {
        let w = tex.width, h = tex.height
        let count = w * h * 4
        var half = [UInt16](repeating: 0, count: count)
        half.withUnsafeMutableBytes { buf in
            tex.getBytes(buf.baseAddress!,
                         bytesPerRow: w * 4 * MemoryLayout<UInt16>.size,
                         from: MTLRegionMake2D(0, 0, w, h),
                         mipmapLevel: 0)
        }
        func srgb(_ linear: Float) -> Float {
            let c = max(0, min(1, linear))
            return c <= 0.0031308 ? c * 12.92 : 1.055 * Float(pow(Double(c), 1.0 / 2.4)) - 0.055
        }
        var rgba8 = [UInt8](repeating: 255, count: count)
        var i = 0
        while i < count {
            for k in 0..<3 {   // R,G,B through sRGB; leave A at 255 (scene is opaque)
                let v = Float(Float16(bitPattern: half[i + k]))
                rgba8[i + k] = UInt8(srgb(v) * 255 + 0.5)
            }
            i += 4
        }
        guard let provider = CGDataProvider(data: Data(rgba8) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
