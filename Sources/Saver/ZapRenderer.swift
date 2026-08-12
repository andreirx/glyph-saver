//
//  ZapRenderer.swift — Metal renderer for Glyph Saver
//  Module maturity: PROTOTYPE (slice GS-1)
//
//  PROVENANCE
//  ----------
//  Adapted from the ZapZap donor (/Users/apple/Documents/Xcodes/ZapZap,
//  "ZapZap Shared/"), same author. What was carried over vs. changed:
//    - Surface format .rgba16Float               ← Renderer.swift:186
//    - EDR layer setup (extendedLinearDisplayP3, ← GameViewController.swift:32–39
//      wantsExtendedDynamicRangeContent). Applied on the CAMetalLayer in
//      GlyphSaverView, not here (the donor uses an MTKView; a screensaver hosts
//      a bare CAMetalLayer instead).
//    - Linear sampler (min/mag linear)           ← Renderer.swift:188–195
//  DROPPED (donor game code left behind, per PLAN.md "adapt, don't wrap"):
//    the Screen/GraphicsLayer/mesh/button/tutorial/sound machinery. This slice
//    needs only two fullscreen passes.
//
//  The two-pass structure (offscreen scene color → fullscreen lighting) ports
//  the zap-web pipeline verified in VISION.md: lighting is a fullscreen
//  post-process that multiplies over the composed scene. GS-2 draws ink-stroke
//  ribbons into the scene color buffer; that ratified near-term requirement is
//  why the scene target is already separate from the drawable here.
//
//  ABSTRACTION LEDGER (this file adds none): no renderer protocol, no scene
//  graph, no material system. One concrete renderer, called only by
//  GlyphSaverView. Direct implementation inside the current slice.
//

import Metal
import MetalKit
import QuartzCore
import simd

// GPU mirrors — field order/size MUST match the MSL structs in Shaders.metal.

/// Mirror of MSL `PointLight` (8 × Float, 32 bytes).
private struct PointLightGPU {
    var x: Float = 0
    var y: Float = 0
    var r: Float = 0
    var g: Float = 0
    var b: Float = 0
    var intensity: Float = 0
    var radius: Float = 0
    var pad: Float = 0
}

/// Mirror of MSL `LightingUniforms` (two float4s, 32 bytes).
private struct LightingUniformsGPU {
    var ambientAndCount: SIMD4<Float> = .zero
    var projSizeFill: SIMD4<Float> = .zero
}

final class ZapRenderer {
    // Verified game facts (docs/VISION.md, ../zap-engine/examples/glypher/src).
    private static let worldHeight: Float = 600.0                 // game.rs:12 WORLD_H
    private static let ambient = SIMD3<Float>(0.12, 0.11, 0.10)   // VISION near-dark ambient
    private static let guideColor = SIMD3<Float>(0.5, 0.7, 1.0)   // game.rs:464
    private static let guideIntensity: Float = 3.0               // game.rs:464
    private static let guideRadius: Float = 280.0                // game.rs:464

    private let device: MTLDevice
    private let queue: MTLCommandQueue

    private let scenePipeline: MTLRenderPipelineState
    private let lightingPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    private let leather: MTLTexture
    private let normalMap: MTLTexture

    private var sceneColor: MTLTexture?
    private var sceneSize: CGSize = .zero

    /// Returns nil if Metal setup fails (device, shader compile, textures, or
    /// pipelines). GlyphSaverView renders nothing when the renderer is nil.
    init?(device: MTLDevice, pixelFormat: MTLPixelFormat, bundle: Bundle) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue

        // --- Runtime shader compile (no build-time `metal` tool; PLAN.md) ---
        guard let shaderURL = bundle.url(forResource: "Shaders", withExtension: "metal"),
              let source = try? String(contentsOf: shaderURL, encoding: .utf8) else {
            NSLog("ZapRenderer: Shaders.metal not found in bundle Resources")
            return nil
        }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            NSLog("ZapRenderer: shader compile failed: \(error)")
            return nil
        }
        guard let vfn = library.makeFunction(name: "fullscreen_vertex"),
              let sceneFn = library.makeFunction(name: "scene_fragment"),
              let lightFn = library.makeFunction(name: "lighting_fragment") else {
            NSLog("ZapRenderer: missing shader function(s)")
            return nil
        }

        // --- Pipelines (both fullscreen, no vertex buffer) ---
        let scenePD = MTLRenderPipelineDescriptor()
        scenePD.label = "ScenePass"
        scenePD.vertexFunction = vfn
        scenePD.fragmentFunction = sceneFn
        scenePD.colorAttachments[0].pixelFormat = .rgba16Float
        let lightPD = MTLRenderPipelineDescriptor()
        lightPD.label = "LightingPass"
        lightPD.vertexFunction = vfn
        lightPD.fragmentFunction = lightFn
        lightPD.colorAttachments[0].pixelFormat = pixelFormat
        do {
            self.scenePipeline = try device.makeRenderPipelineState(descriptor: scenePD)
            self.lightingPipeline = try device.makeRenderPipelineState(descriptor: lightPD)
        } catch {
            NSLog("ZapRenderer: pipeline creation failed: \(error)")
            return nil
        }

        // --- Sampler (linear, clamp — aspect-fill UVs stay inside [0,1]) ---
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sd) else { return nil }
        self.sampler = sampler

        // --- Textures. Leather as sRGB (sampling linearizes for linear
        //     lighting into the extended-linear target); normal map as raw data.
        let loader = MTKTextureLoader(device: device)
        let base: [MTKTextureLoader.Option: Any] = [
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            .generateMipmaps: NSNumber(value: false),
        ]
        guard let leatherURL = bundle.url(forResource: "vbg_1024", withExtension: "jpg"),
              let normalURL = bundle.url(forResource: "vbg_1024_normals", withExtension: "png") else {
            NSLog("ZapRenderer: background/normal texture missing from bundle")
            return nil
        }
        do {
            var colorOpts = base; colorOpts[.SRGB] = NSNumber(value: true)
            var normalOpts = base; normalOpts[.SRGB] = NSNumber(value: false)
            self.leather = try loader.newTexture(URL: leatherURL, options: colorOpts)
            self.normalMap = try loader.newTexture(URL: normalURL, options: normalOpts)
        } catch {
            NSLog("ZapRenderer: texture load failed: \(error)")
            return nil
        }
    }

    /// (Re)allocate the offscreen scene color target for a new drawable size.
    func resize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != sceneSize else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: Int(size.width), height: Int(size.height), mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        sceneColor = device.makeTexture(descriptor: desc)
        sceneSize = size
    }

    /// Render one frame into the layer's next drawable. `time` is monotonic
    /// elapsed seconds (drives the light path).
    func render(to layer: CAMetalLayer, time: Double) {
        let ds = layer.drawableSize
        guard ds.width > 0, ds.height > 0 else { return }
        if sceneColor == nil || ds != sceneSize { resize(ds) }
        guard let drawable = layer.nextDrawable(),
              let cmd = queue.makeCommandBuffer() else { return }
        encodeFrame(into: drawable.texture, time: time, cmd: cmd)
        cmd.present(drawable)
        cmd.commit()
    }

    /// Isolation test seam. Renders one frame into an arbitrary target texture
    /// and blocks until the GPU finishes, so an offscreen harness can validate
    /// the full pipeline (runtime shader compile, texture load, both passes,
    /// moving light) without a CAMetalLayer/drawable or the operator's
    /// screen-saver environment. Not used by the live saver.
    /// Seam rationale (ledger): render target varies between drawable (live) and
    /// offscreen texture (test); simpler alternative — vending drawables from an
    /// unattached CAMetalLayer — is undocumented/flaky, so rejected.
    func renderFrameSynchronously(into target: MTLTexture, time: Double) {
        let size = CGSize(width: target.width, height: target.height)
        if sceneColor == nil || size != sceneSize { resize(size) }
        guard let cmd = queue.makeCommandBuffer() else { return }
        encodeFrame(into: target, time: time, cmd: cmd)
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    /// Encode the scene pass (offscreen color) and the lighting pass (into
    /// `target`) onto `cmd`. Single source of pass logic for both entry points.
    private func encodeFrame(into target: MTLTexture, time: Double, cmd: MTLCommandBuffer) {
        guard let sceneColor = sceneColor else { return }
        let ds = CGSize(width: target.width, height: target.height)

        let aspect = Float(ds.width / ds.height)
        // Aspect-fill scale about UV centre: shrink the longer view axis.
        let fillScale = SIMD2<Float>(min(1.0, aspect), min(1.0, 1.0 / aspect))
        // World box: height fixed to the game's 600 units, width follows aspect
        // (radius 280 then reads as ~0.47 of the height, matching the game).
        let projSize = SIMD2<Float>(Self.worldHeight * aspect, Self.worldHeight)

        // ---- Scene pass → offscreen color buffer ----
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = sceneColor
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].storeAction = .store
        scenePass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let enc = cmd.makeRenderCommandEncoder(descriptor: scenePass) {
            enc.label = "ScenePass"
            enc.setRenderPipelineState(scenePipeline)
            enc.setFragmentTexture(leather, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            var fs = fillScale
            enc.setFragmentBytes(&fs, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // ---- Lighting pass → drawable ----
        var light = PointLightGPU()
        let lp = guideLightPosition(time: time, proj: projSize)
        light.x = lp.x; light.y = lp.y
        light.r = Self.guideColor.x; light.g = Self.guideColor.y; light.b = Self.guideColor.z
        light.intensity = Self.guideIntensity
        light.radius = Self.guideRadius

        var uniforms = LightingUniformsGPU()
        uniforms.ambientAndCount = SIMD4<Float>(Self.ambient.x, Self.ambient.y, Self.ambient.z, 1.0)
        uniforms.projSizeFill = SIMD4<Float>(projSize.x, projSize.y, fillScale.x, fillScale.y)

        let lightPass = MTLRenderPassDescriptor()
        lightPass.colorAttachments[0].texture = target
        lightPass.colorAttachments[0].loadAction = .clear
        lightPass.colorAttachments[0].storeAction = .store
        lightPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let enc = cmd.makeRenderCommandEncoder(descriptor: lightPass) {
            enc.label = "LightingPass"
            enc.setRenderPipelineState(lightingPipeline)
            enc.setFragmentTexture(sceneColor, index: 0)
            enc.setFragmentTexture(normalMap, index: 1)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<LightingUniformsGPU>.stride, index: 0)
            enc.setFragmentBytes(&light, length: MemoryLayout<PointLightGPU>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
    }

    /// Slow smooth Lissajous sweep across the world box. Two nearly-incommensurate
    /// low frequencies keep the path non-repeating and unhurried.
    private func guideLightPosition(time: Double, proj: SIMD2<Float>) -> SIMD2<Float> {
        let t = Float(time)
        let cx = proj.x * 0.5, cy = proj.y * 0.5
        let ax = proj.x * 0.36, ay = proj.y * 0.36
        let x = cx + ax * sin(0.13 * t)
        let y = cy + ay * sin(0.19 * t + 1.3)
        return SIMD2<Float>(x, y)
    }
}
