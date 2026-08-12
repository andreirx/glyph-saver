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
//  GS-2 additions:
//    - Ink: the fixed proverb is laid out by GlyphCore.ProverbLayout (pure,
//      tested) into world-space stroke polylines, tessellated here into
//      round-capped/round-joined opaque-cream geometry, and drawn into the
//      scene color buffer after the leather (before lighting). The ribbon
//      tessellation adapts the ZapZap donor SegmentStripeMesh.swift pattern
//      (perpendicular half-width offset per segment) but replaces its
//      miter/square joins with a CAPSULE UNION (segment quad + a round disc at
//      every vertex) — round joins + round caps in one pass, artifact-free for
//      opaque ink that self-overlaps (cursive loops). Provenance: donor
//      SegmentStripeMesh.swift:88–183; deviation is the join/cap method.
//      EMISSION (GS-2 review-0 required change): every convex piece (each
//      segment quad, each disc) is emitted in TRIANGLE-STRIP vertex order
//      (a two-pointer zig-zag that strip-triangulates a convex polygon), and
//      the pieces are joined into ONE connected strip by degenerate bridges
//      (last-vertex-of-prev + first-vertex-of-next repeated). Drawn with a
//      single `.triangleStrip` primitive. Degenerate (zero-area) triangles
//      never rasterize; the ink pipeline sets no cull mode (default `.none`),
//      so strip winding parity is irrelevant to the opaque fill.
//
//  ABSTRACTION LEDGER (this file adds none): no renderer protocol, no scene
//  graph, no material system, no mesh class. One concrete renderer, called only
//  by GlyphSaverView; GlyphCore is the sole (pure) collaborator. Direct
//  implementation inside the current slice.
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

/// Mirror of MSL `InkUniforms` (one float2).
private struct InkUniformsGPU {
    var projSize: SIMD2<Float> = .zero
}

final class ZapRenderer {
    // Verified game facts (docs/VISION.md, ../zap-engine/examples/glypher/src).
    private static let worldHeight: Float = 600.0                 // game.rs:12 WORLD_H
    private static let ambient = SIMD3<Float>(0.12, 0.11, 0.10)   // VISION near-dark ambient
    private static let guideColor = SIMD3<Float>(0.5, 0.7, 1.0)   // game.rs:464
    private static let guideIntensity: Float = 3.0               // game.rs:464
    private static let guideRadius: Float = 280.0                // game.rs:464

    // Ink (Hello-style, docs/PLAN.md "Renderer decision"). Tunable at checkpoints.
    private static let inkColor = SIMD4<Float>(0.95, 0.91, 0.82, 1.0)  // opaque warm cream
    private static let inkWidthGlyphUnits: Float = 36.0               // ~7.5% of the 480 box
    private static let inkCapSegments = 12                            // round cap/join facets
    // The one fixed proverb this slice renders (settled ink, final block framing).
    private static let proverb = "Good things come to those who wait"

    private let device: MTLDevice
    private let queue: MTLCommandQueue

    private let scenePipeline: MTLRenderPipelineState
    private let inkPipeline: MTLRenderPipelineState
    private let lightingPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    private let leather: MTLTexture
    private let normalMap: MTLTexture

    /// Parsed once from the bundle; `nil` degrades to background-only (no ink).
    private let glyphSet: GlyphSet?

    private var sceneColor: MTLTexture?
    private var sceneSize: CGSize = .zero

    // Ink geometry, rebuilt on resize (world-space triangle-strip verts for the proverb).
    private var inkBuffer: MTLBuffer?
    private var inkVertexCount: Int = 0
    private var inkProjSize: SIMD2<Float> = .zero

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
              let inkVfn = library.makeFunction(name: "ink_vertex"),
              let inkFfn = library.makeFunction(name: "ink_fragment"),
              let lightFn = library.makeFunction(name: "lighting_fragment") else {
            NSLog("ZapRenderer: missing shader function(s)")
            return nil
        }

        // --- Pipelines ---
        // Scene + lighting are fullscreen (no vertex buffer); ink draws a
        // world-space triangle soup into the same rgba16Float scene target.
        let scenePD = MTLRenderPipelineDescriptor()
        scenePD.label = "ScenePass"
        scenePD.vertexFunction = vfn
        scenePD.fragmentFunction = sceneFn
        scenePD.colorAttachments[0].pixelFormat = .rgba16Float
        let inkPD = MTLRenderPipelineDescriptor()
        inkPD.label = "InkPass"
        inkPD.vertexFunction = inkVfn
        inkPD.fragmentFunction = inkFfn
        inkPD.colorAttachments[0].pixelFormat = .rgba16Float   // same target as scene
        let lightPD = MTLRenderPipelineDescriptor()
        lightPD.label = "LightingPass"
        lightPD.vertexFunction = vfn
        lightPD.fragmentFunction = lightFn
        lightPD.colorAttachments[0].pixelFormat = pixelFormat
        do {
            self.scenePipeline = try device.makeRenderPipelineState(descriptor: scenePD)
            self.inkPipeline = try device.makeRenderPipelineState(descriptor: inkPD)
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

        // --- Glyph set (bundled generated artifact). Parse failure degrades to
        //     background-only rather than failing the whole renderer. ---
        if let glyphURL = bundle.url(forResource: "glyphs_baked", withExtension: "json"),
           let glyphData = try? Data(contentsOf: glyphURL),
           let parsed = try? GlyphSet(data: glyphData) {
            self.glyphSet = parsed
        } else {
            NSLog("ZapRenderer: glyphs_baked.json missing/unparseable — rendering background only")
            self.glyphSet = nil
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
        rebuildInk(for: size)
    }

    /// Lay out the proverb for this drawable's world box and (re)build the ink
    /// vertex buffer. Called from `resize` (size-driven), so the layout tracks
    /// aspect changes. World box: height fixed to 600, width follows aspect —
    /// the same projSize the lighting pass uses, so ink registers with lights.
    private func rebuildInk(for size: CGSize) {
        guard let glyphSet = glyphSet, size.width > 0, size.height > 0 else {
            inkBuffer = nil; inkVertexCount = 0; return
        }
        let aspect = CGFloat(size.width / size.height)
        let projW = CGFloat(Self.worldHeight) * aspect
        inkProjSize = SIMD2<Float>(Float(projW), Self.worldHeight)

        let layout = ProverbLayout.layout(
            proverb: Self.proverb, glyphs: glyphSet,
            viewport: CGSize(width: projW, height: CGFloat(Self.worldHeight)))

        let verts = Self.tessellate(layout,
                                    widthGlyphUnits: Self.inkWidthGlyphUnits,
                                    capSegments: Self.inkCapSegments)
        inkVertexCount = verts.count / 2
        if inkVertexCount > 0 {
            inkBuffer = device.makeBuffer(bytes: verts,
                                          length: verts.count * MemoryLayout<Float>.stride,
                                          options: .storageModeShared)
        } else {
            inkBuffer = nil
        }
    }

    /// Tessellate the laid-out proverb's world-space polylines into a SINGLE
    /// connected triangle strip: one quad per segment plus a round disc at every
    /// vertex (a capsule union → round caps + round joins). Uniform width =
    /// `widthGlyphUnits` glyph units, scaled to world by the layout scale (so the
    /// ribbon stays ~7.5% of the glyph box at any viewport). Output is
    /// [x0,y0, x1,y1, …] in world coords in triangle-strip order; the ink vertex
    /// shader maps world → clip via projSize. Draw with `.triangleStrip`.
    ///
    /// Each convex piece is emitted with `addStrip`, which strip-triangulates a
    /// convex polygon by the standard two-pointer zig-zag (p0, p1, pN-1, p2,
    /// pN-2, …). Consecutive pieces are joined by a degenerate bridge (repeat
    /// prev-last then next-first): the two collapsed triangles at every seam are
    /// zero-area and never rasterize, so the pieces read as independent fills
    /// inside one draw call. GS-2 review-0 required strips over the prior
    /// triangle-list soup; the geometry (capsule union) is unchanged.
    ///
    /// Adapts ZapZap SegmentStripeMesh.swift:88–183 (perpendicular offset per
    /// segment); deviates by using discs for joins/caps instead of miter/square
    /// (round, and artifact-free for opaque self-overlapping cursive ink).
    private static func tessellate(_ layout: ProverbLayout.Layout,
                                   widthGlyphUnits: Float,
                                   capSegments: Int) -> [Float] {
        let halfW = widthGlyphUnits * 0.5 * Float(layout.scale)
        guard halfW > 0 else { return [] }
        var v: [Float] = []
        var stripStarted = false

        @inline(__always) func emit(_ x: Float, _ y: Float) { v.append(x); v.append(y) }

        // Emit `pts` (a convex polygon, CCW) as triangle-strip vertices, bridged
        // to any preceding piece with degenerate triangles.
        func addStrip(_ pts: [(Float, Float)]) {
            let n = pts.count
            guard n >= 3 else { return }
            if stripStarted {
                emit(v[v.count - 2], v[v.count - 1])   // repeat prev-last (degenerate)
                emit(pts[0].0, pts[0].1)               // repeat next-first (degenerate)
            }
            // Two-pointer convex-polygon strip: 0, 1, n-1, 2, n-2, 3, …
            emit(pts[0].0, pts[0].1)
            var front = 1, back = n - 1, takeFront = true
            while front <= back {
                if takeFront { emit(pts[front].0, pts[front].1); front += 1 }
                else         { emit(pts[back].0,  pts[back].1);  back  -= 1 }
                takeFront.toggle()
            }
            stripStarted = true
        }

        // Round disc (cap/join): `capSegments` rim points, already CCW by angle.
        let step = (2.0 * Float.pi) / Float(capSegments)
        func addDisc(_ cx: Float, _ cy: Float) {
            var rim: [(Float, Float)] = []
            rim.reserveCapacity(capSegments)
            for i in 0..<capSegments {
                let a = step * Float(i)
                rim.append((cx + halfW * cos(a), cy + halfW * sin(a)))
            }
            addStrip(rim)
        }

        for glyph in layout.glyphs {
            for stroke in glyph.strokes where !stroke.isEmpty {
                for p in stroke { addDisc(Float(p.x), Float(p.y)) }   // caps + joins
                guard stroke.count >= 2 else { continue }
                for i in 0..<(stroke.count - 1) {
                    let x0 = Float(stroke[i].x),   y0 = Float(stroke[i].y)
                    let x1 = Float(stroke[i+1].x), y1 = Float(stroke[i+1].y)
                    let dx = x1 - x0, dy = y1 - y0
                    let len = (dx*dx + dy*dy).squareRoot()
                    guard len > 1e-6 else { continue }
                    let nx = -dy / len * halfW, ny = dx / len * halfW
                    // Segment ribbon quad, corners in convex (CCW) order.
                    addStrip([(x0+nx, y0+ny), (x1+nx, y1+ny),
                              (x1-nx, y1-ny), (x0-nx, y0-ny)])
                }
            }
        }
        return v
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

            // Ink ribbons on top of the leather, into the same scene buffer.
            // Opaque cream; lit (and relief-shaded) by the following pass.
            if let inkBuffer = inkBuffer, inkVertexCount > 0 {
                enc.setRenderPipelineState(inkPipeline)
                enc.setVertexBuffer(inkBuffer, offset: 0, index: 0)
                var ink = InkUniformsGPU(projSize: inkProjSize)
                enc.setVertexBytes(&ink, length: MemoryLayout<InkUniformsGPU>.stride, index: 1)
                var color = Self.inkColor
                enc.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                // One connected strip for the whole proverb (pieces joined by
                // degenerate bridges; see `tessellate`). GS-2 review-0 required
                // triangle strips over the prior triangle-list soup.
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: inkVertexCount)
            }
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
