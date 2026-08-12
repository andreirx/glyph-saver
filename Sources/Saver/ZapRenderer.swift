//
//  ZapRenderer.swift — Metal renderer for Glyph Saver
//  Module maturity: PROTOTYPE (slice GS-4)
//
//  PROVENANCE
//  ----------
//  Adapted from the ZapZap donor (/Users/apple/Documents/Xcodes/ZapZap,
//  "ZapZap Shared/"), same author. What was carried over vs. changed:
//    - Surface format .rgba16Float               ← Renderer.swift:186
//    - EDR layer setup (extendedLinearDisplayP3, ← GameViewController.swift:32–39
//      wantsExtendedDynamicRangeContent). Applied on the CAMetalLayer in
//      GlyphSaverView (a screensaver hosts a bare CAMetalLayer, not an MTKView).
//    - Linear sampler (min/mag linear)           ← Renderer.swift:188–195
//  DROPPED (donor game code left behind, per PLAN.md "adapt, don't wrap"):
//    the Screen/GraphicsLayer/mesh/button/tutorial/sound machinery.
//
//  The two-pass structure (offscreen scene color → fullscreen lighting) ports
//  the zap-web pipeline verified in VISION.md: lighting is a fullscreen
//  post-process that multiplies over the composed scene.
//
//  GS-3 — THE WRITING (landed GS-3; the finale below supersedes its tail)
//  ---------------------------------------------------------------------
//  An invisible pen writes each proverb letter by letter while the camera pulls
//  back from one huge letter to the full boxed proverb, then holds and hands off
//  to the GS-4 FINALE (below) — NOT the old GS-3 "hold 12 s → fade" tail, which
//  the ratified finale replaced (VISION §6). All of the *decisions* are pure
//  GlyphCore:
//    - ProverbSequence  — uniform-random, no-immediate-repeat pick over
//      sayings.json. Seeded ONCE per renderer instance from system randomness
//      (each saver session opens on a random proverb — VISION §Experience 2 /
//      GS-3, NOT a fixed sequence). The seed is fixed FOR THE INSTANCE, so the
//      schedule stays a deterministic function of absolute time and the renderer
//      can replay it statelessly from t=0 every frame; the two verify.sh captures
//      from one host process therefore stay mutually consistent.
//    - WritingClock     — per-proverb timeline: which strokes are inked, the pen
//      arc-length position (GUIDE_SPEED = 60 pts/s, game.rs:26), and the ratified
//      finale phase machine writing → holding (~5 s gold dwell) →
//      igniting (~1.5 s) → dissolving (~2.5 s) → done (VISION §6 / PLAN GS-4;
//      these superseded the game's static 12 s SAYING_CELEBRATE_DURATION dwell).
//    - CameraPlan       — the monotone world→view pull-back (opens on letter 1,
//      converges to the GS-2 static framing). Applied to INK/PEN/LIGHTS only.
//  The renderer is pure mechanism: each frame it reconstructs (proverb, local
//  time) from the absolute time, tessellates the partial-inked ribbons up to the
//  pen (round cap at the pen), draws the bright pen-tip dot (game.rs:468), and
//  positions the pen's lights — guide [0.5,0.7,1.0] i3 r280 + green
//  [0.3,1.0,0.4] i4 r250 (game.rs:463/483) + faint letter ambient
//  [0.3,0.3,0.4] i4 r350 (game.rs:477) — in VIEW space through the camera. The
//  leather (scene pass) and the lighting pass stay screen-fixed (VISION §3).
//  During the holding dwell a gentle Lissajous ambient sweep keeps the scene
//  alive under the gold dwell light (before the finale ignites the ink).
//
//  GS-4 — CELEBRATIONS & THE FINALE (this slice)
//  --------------------------------------------
//  Three additions, all still stateless per-frame replays of pure GlyphCore:
//    - LETTER CELEBRATION (game.rs:533-553, 795-803): as each letter finishes it
//      floods GOLD — its strokes redrawn wide-and-golden into the SCENE buffer
//      (so the following lighting pass shades them, game parity) + a gold point
//      light at the glyph centre + a 25-spark burst (ParticleField). Computed
//      independent of the writing/holding boundary so the last letter's 1.2 s
//      window spills into early holding.
//    - FINALE (VISION §6, WritingClock phases holding→igniting→dissolving): a
//      ~5 s gold dwell, then the settled ink IGNITES to a random full-saturation
//      4×–8× HDR hue (FinaleColor, seeded per proverb), then DISSOLVES into
//      fireworks along the stroke paths while the ink ramps out.
//    - EMISSIVE PASS: ignited ink + all particles are self-luminous HDR,
//      composited ADDITIVELY on top of the lit frame — NOT run through the
//      lighting multiply. This is required by the human directive (2026-08-12):
//      the 4×–8× HDR values must reach the panel unreduced; the near-dark ambient
//      would otherwise scale them down. Additive ⇒ the full HDR value is present.
//
//  ABSTRACTION LEDGER (this file adds none new): one concrete renderer, called
//  only by GlyphSaverView; GlyphCore + ParticleField (render-layer sibling) are
//  the collaborators. The ink/particle vertex buffers are rebuilt PER FRAME;
//  layouts are cached per (proverb index, world size).
//

import Metal
import MetalKit
import QuartzCore
import CoreGraphics
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

/// Mirror of MSL `InkUniforms` (float2 projSize, float2 focus, float scale,
/// float pad → 24 bytes). GS-3 adds the camera (focus + scale).
private struct InkUniformsGPU {
    var projSize: SIMD2<Float> = .zero
    var focus: SIMD2<Float> = .zero
    var scale: Float = 1
    var pad: Float = 0
}

final class ZapRenderer {
    // Verified game facts (docs/VISION.md, ../zap-engine/examples/glypher/src).
    private static let worldHeight: Float = 600.0                 // game.rs:12 WORLD_H
    private static let ambient = SIMD3<Float>(0.12, 0.11, 0.10)   // VISION near-dark ambient

    // Pen-carried lights (game.rs). Radii are WORLD units; the renderer scales
    // them by the camera magnification so the glow footprint tracks the ink.
    private static let guideColor = SIMD3<Float>(0.5, 0.7, 1.0)   // game.rs:463
    private static let guideIntensity: Float = 3.0               // game.rs:463
    private static let guideRadius: Float = 280.0                // game.rs:463
    private static let greenColor = SIMD3<Float>(0.3, 1.0, 0.4)  // game.rs:483 (user/pen cursor)
    private static let greenIntensity: Float = 4.0              // game.rs:483
    private static let greenRadius: Float = 250.0              // game.rs:483
    private static let letterAmbientColor = SIMD3<Float>(0.3, 0.3, 0.4) // game.rs:477
    private static let letterAmbientIntensity: Float = 4.0     // game.rs:477
    private static let letterAmbientRadius: Float = 350.0      // game.rs:477

    // Ink (Hello-style, docs/PLAN.md "Renderer decision"). Tunable at checkpoints.
    private static let inkColor = SIMD3<Float>(0.95, 0.91, 0.82)      // opaque warm cream
    // RATIFIED default ink width (do NOT change — operator note 2026-08-12). The
    // verification path may OVERRIDE it per-frame via
    // renderFrameSynchronously(into:time:inkWidthGlyphUnits:) to render the
    // width-comparison PNG; the live saver always uses this value.
    private static let inkWidthGlyphUnits: Float = 28.0               // ~5.8% of the 480 box; human pick 2026-08-12 (36 closed small 'e' counters — see PLAN)
    private static let inkCapSegments = 12                            // round cap/join facets
    /// Bright pen-tip dot (game.rs:468 fill_circle(pos, 8.0, (0.8,1.2,2.5))).
    private static let penDotColor = SIMD3<Float>(1.1, 1.4, 2.2)
    private static let penDotWidthFactor: Float = 1.35               // × ink half-width

    // Celebration / finale constants (game.rs; VISION §6).
    private static let celebrateDuration: CGFloat = 1.2              // CELEBRATE_DURATION game.rs:29
    /// Gold used by BOTH the letter-complete light (game.rs:551) and the
    /// saying-complete dwell light (game.rs:558): [1.0, 0.85, 0.3].
    private static let goldLightColor = SIMD3<Float>(1.0, 0.85, 0.3)
    private static let letterGoldIntensity: Float = 14.0            // i14·t  game.rs:551
    private static let letterGoldRadius: Float = 350.0             // r350   game.rs:551
    private static let sayingGoldIntensity: Float = 10.0           // i10·t  game.rs:558
    private static let sayingGoldRadius: Float = 400.0            // r400   game.rs:558

    /// Per-instance schedule seed, drawn from system randomness ONCE in `init`
    /// (see header). Random per session ⇒ a random opening proverb; fixed for the
    /// instance ⇒ the schedule is a pure function of absolute time (stateless
    /// per-frame replay). Tests seed `ProverbSequence` directly, not this.
    private let scheduleSeed: UInt64

    private let device: MTLDevice
    private let queue: MTLCommandQueue

    private let scenePipeline: MTLRenderPipelineState
    private let inkPipeline: MTLRenderPipelineState
    private let lightingPipeline: MTLRenderPipelineState
    /// Self-luminous HDR geometry (ignited ink), additively blended on top of the
    /// lit frame. Per-vertex colour; see Shaders.metal emissive_*.
    private let emissivePipeline: MTLRenderPipelineState
    /// Particles (letter-burst sparks + finale dissolve fireworks) as INSTANCED
    /// quads — one unit-quad geometry per live particle. Shares the emissive
    /// additive blend + fragment; only the vertex stage differs. See particle_vertex.
    private let particlePipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    private let leather: MTLTexture
    private let normalMap: MTLTexture

    /// Parsed once from the bundle; `nil` degrades to background-only (no ink).
    private let glyphSet: GlyphSet?
    /// Proverbs (sayings.json); empty degrades to background-only.
    private let sayings: [String]

    private var sceneColor: MTLTexture?
    private var sceneSize: CGSize = .zero

    // World viewport (height fixed to 600, width follows aspect) + layout cache.
    private var currentProjSize: CGSize = .zero
    private var layoutCache: [Int: ProverbLayout.Layout] = [:]

    /// Returns nil if Metal setup fails (device, shader compile, textures, or
    /// pipelines). GlyphSaverView renders nothing when the renderer is nil.
    init?(device: MTLDevice, pixelFormat: MTLPixelFormat, bundle: Bundle) {
        self.device = device
        // One system-random seed per renderer instance: the saver session opens
        // on a random proverb (GS-3 / VISION §Experience 2). `UInt64.random(in:)`
        // uses SystemRandomNumberGenerator (CSPRNG-seeded) — genuine per-instance
        // randomness, not the old fixed compile-time constant.
        //
        // TESTING SEAM (GS-4): `GLYPHSAVER_SEED`, when set to a UInt64, PINS the
        // schedule so verify.sh can land offscreen frames on a known celebration /
        // finale moment (deliverable 6). Unset in the live saver — no behavioural
        // change to the shipped product.
        if let env = ProcessInfo.processInfo.environment["GLYPHSAVER_SEED"],
           let seed = UInt64(env) {
            self.scheduleSeed = seed
        } else {
            self.scheduleSeed = UInt64.random(in: UInt64.min ... UInt64.max)
        }
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
              let emissiveVfn = library.makeFunction(name: "emissive_vertex"),
              let emissiveFfn = library.makeFunction(name: "emissive_fragment"),
              let particleVfn = library.makeFunction(name: "particle_vertex"),
              let particleFfn = library.makeFunction(name: "particle_fragment"),
              let lightFn = library.makeFunction(name: "lighting_fragment") else {
            NSLog("ZapRenderer: missing shader function(s)")
            return nil
        }

        // --- Pipelines ---
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
        // Alpha blend: at alpha 1 the cream ink is opaque (src replaces dst, so
        // self-overlapping cursive loops compose cleanly); the proverb FADE
        // (GS-3) lowers alpha to dissolve the ink back into the leather.
        inkPD.colorAttachments[0].isBlendingEnabled = true
        inkPD.colorAttachments[0].rgbBlendOperation = .add
        inkPD.colorAttachments[0].alphaBlendOperation = .add
        inkPD.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        inkPD.colorAttachments[0].sourceAlphaBlendFactor = .one
        inkPD.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        inkPD.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let lightPD = MTLRenderPipelineDescriptor()
        lightPD.label = "LightingPass"
        lightPD.vertexFunction = vfn
        lightPD.fragmentFunction = lightFn
        lightPD.colorAttachments[0].pixelFormat = pixelFormat
        // Emissive pass: ADDITIVE, self-luminous HDR (ignited ink + particles),
        // composited over the lit frame. The fragment premultiplies rgb by alpha,
        // so the blend is a plain add (dst.rgb += src.rgb·src.a); the alpha channel
        // is preserved (target stays opaque). Same target format as the light pass.
        let emissivePD = MTLRenderPipelineDescriptor()
        emissivePD.label = "EmissivePass"
        emissivePD.vertexFunction = emissiveVfn
        emissivePD.fragmentFunction = emissiveFfn
        emissivePD.colorAttachments[0].pixelFormat = pixelFormat
        emissivePD.colorAttachments[0].isBlendingEnabled = true
        emissivePD.colorAttachments[0].rgbBlendOperation = .add
        emissivePD.colorAttachments[0].sourceRGBBlendFactor = .one
        emissivePD.colorAttachments[0].destinationRGBBlendFactor = .one
        emissivePD.colorAttachments[0].alphaBlendOperation = .add
        emissivePD.colorAttachments[0].sourceAlphaBlendFactor = .zero
        emissivePD.colorAttachments[0].destinationAlphaBlendFactor = .one
        // Particle pass: identical additive HDR blend as the emissive pass, but
        // its own instanced-quad vertex stage AND its own fragment stage
        // (particle_fragment adds the radial soft falloff → round sparks).
        let particlePD = MTLRenderPipelineDescriptor()
        particlePD.label = "ParticlePass"
        particlePD.vertexFunction = particleVfn
        particlePD.fragmentFunction = particleFfn
        particlePD.colorAttachments[0].pixelFormat = pixelFormat
        particlePD.colorAttachments[0].isBlendingEnabled = true
        particlePD.colorAttachments[0].rgbBlendOperation = .add
        particlePD.colorAttachments[0].sourceRGBBlendFactor = .one
        particlePD.colorAttachments[0].destinationRGBBlendFactor = .one
        particlePD.colorAttachments[0].alphaBlendOperation = .add
        particlePD.colorAttachments[0].sourceAlphaBlendFactor = .zero
        particlePD.colorAttachments[0].destinationAlphaBlendFactor = .one
        do {
            self.scenePipeline = try device.makeRenderPipelineState(descriptor: scenePD)
            self.inkPipeline = try device.makeRenderPipelineState(descriptor: inkPD)
            self.lightingPipeline = try device.makeRenderPipelineState(descriptor: lightPD)
            self.emissivePipeline = try device.makeRenderPipelineState(descriptor: emissivePD)
            self.particlePipeline = try device.makeRenderPipelineState(descriptor: particlePD)
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

        // --- Textures. Leather as sRGB; normal map as raw data.
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

        // --- Glyph set + sayings (bundled artifacts). Parse failure degrades to
        //     background-only rather than failing the whole renderer. ---
        if let glyphURL = bundle.url(forResource: "glyphs_baked", withExtension: "json"),
           let glyphData = try? Data(contentsOf: glyphURL),
           let parsed = try? GlyphSet(data: glyphData) {
            self.glyphSet = parsed
        } else {
            NSLog("ZapRenderer: glyphs_baked.json missing/unparseable — background only")
            self.glyphSet = nil
        }
        if let sayingsURL = bundle.url(forResource: "sayings", withExtension: "json"),
           let sayingsData = try? Data(contentsOf: sayingsURL),
           let parsed = try? JSONDecoder().decode([String].self, from: sayingsData) {
            self.sayings = parsed
        } else {
            NSLog("ZapRenderer: sayings.json missing/unparseable — background only")
            self.sayings = []
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

    // MARK: - Scheduling (pure GlyphCore reconstructed from absolute time)

    /// World viewport for a drawable size: height fixed to 600, width by aspect.
    private func projSize(for drawable: CGSize) -> CGSize {
        let aspect = drawable.width / drawable.height
        return CGSize(width: CGFloat(Self.worldHeight) * aspect, height: CGFloat(Self.worldHeight))
    }

    /// Layout for proverb `index` at the current world viewport, cached. The
    /// cache is invalidated when the world size changes.
    private func layout(_ index: Int, proj: CGSize) -> ProverbLayout.Layout? {
        guard let glyphSet = glyphSet, sayings.indices.contains(index) else { return nil }
        if proj != currentProjSize { layoutCache.removeAll(keepingCapacity: true); currentProjSize = proj }
        if let cached = layoutCache[index] { return cached }
        let l = ProverbLayout.layout(proverb: sayings[index], glyphs: glyphSet, viewport: proj)
        layoutCache[index] = l
        return l
    }

    /// Reconstruct (layout, clock, local time) for absolute elapsed `t`. Walks
    /// the schedule from t=0 using this instance's seed, subtracting each
    /// proverb's totalDuration. Cheap: layouts are cached; only WritingClock is
    /// rebuilt per step, and the walk is O(t / proverb-duration).
    private func scheduled(atAbsolute t: Double, proj: CGSize)
        -> (layout: ProverbLayout.Layout, clock: WritingClock, local: CGFloat, index: Int)? {
        guard glyphSet != nil, !sayings.isEmpty else { return nil }
        var seq = ProverbSequence(seed: scheduleSeed)
        var remaining = CGFloat(max(0, t))
        var guardIter = 0
        while true {
            let idx = seq.next(count: sayings.count)
            guard let layout = layout(idx, proj: proj) else { return nil }
            let clock = WritingClock(layout: layout)
            if remaining < clock.totalDuration || guardIter > 100_000 {
                return (layout, clock, max(0, remaining), idx)
            }
            remaining -= clock.totalDuration
            guardIter += 1
        }
    }

    /// Per-proverb finale/particle seed: the instance schedule seed mixed with the
    /// proverb index, so the ignite hue is "seeded per proverb" (VISION §6) yet a
    /// deterministic function of absolute time (stateless replay). SplitMix64
    /// finalizer so adjacent indices don't yield adjacent hues.
    private static func proverbSeed(_ base: UInt64, _ index: Int) -> UInt64 {
        var z = base ^ (UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9_7F4A_7C15)
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    // MARK: - Ink tessellation (world-space triangle strips)

    /// Tessellate world-space polylines into ONE connected triangle strip: a quad
    /// per segment + a round disc at every vertex (capsule union → round caps &
    /// joins). Provenance/method unchanged from GS-2 (donor
    /// SegmentStripeMesh.swift:88–183, disc joins instead of miter). The pen's
    /// round cap comes for free: each partial polyline ends at the interpolated
    /// pen point, and a disc is emitted there.
    private static func tessellatePolylines(_ polylines: [[CGPoint]],
                                            halfW: Float,
                                            capSegments: Int) -> [Float] {
        guard halfW > 0 else { return [] }
        var v: [Float] = []
        var stripStarted = false

        @inline(__always) func emit(_ x: Float, _ y: Float) { v.append(x); v.append(y) }

        func addStrip(_ pts: [(Float, Float)]) {
            let n = pts.count
            guard n >= 3 else { return }
            if stripStarted {
                emit(v[v.count - 2], v[v.count - 1])   // repeat prev-last (degenerate)
                emit(pts[0].0, pts[0].1)               // repeat next-first (degenerate)
            }
            emit(pts[0].0, pts[0].1)
            var front = 1, back = n - 1, takeFront = true
            while front <= back {
                if takeFront { emit(pts[front].0, pts[front].1); front += 1 }
                else         { emit(pts[back].0,  pts[back].1);  back  -= 1 }
                takeFront.toggle()
            }
            stripStarted = true
        }

        let step = (2.0 * Float.pi) / Float(capSegments)
        func addDisc(_ cx: Float, _ cy: Float, _ radius: Float) {
            var rim: [(Float, Float)] = []
            rim.reserveCapacity(capSegments)
            for i in 0..<capSegments {
                let a = step * Float(i)
                rim.append((cx + radius * cos(a), cy + radius * sin(a)))
            }
            addStrip(rim)
        }

        for stroke in polylines where !stroke.isEmpty {
            for p in stroke { addDisc(Float(p.x), Float(p.y), halfW) }   // caps + joins
            guard stroke.count >= 2 else { continue }
            for i in 0..<(stroke.count - 1) {
                let x0 = Float(stroke[i].x),   y0 = Float(stroke[i].y)
                let x1 = Float(stroke[i+1].x), y1 = Float(stroke[i+1].y)
                let dx = x1 - x0, dy = y1 - y0
                let len = (dx*dx + dy*dy).squareRoot()
                guard len > 1e-6 else { continue }
                let nx = -dy / len * halfW, ny = dx / len * halfW
                addStrip([(x0+nx, y0+ny), (x1+nx, y1+ny),
                          (x1-nx, y1-ny), (x0-nx, y0-ny)])
            }
        }
        return v
    }

    /// A single filled disc as a triangle strip (the pen-tip dot).
    private static func discStrip(center: CGPoint, radius: Float, segments: Int) -> [Float] {
        guard radius > 0 else { return [] }
        let step = (2.0 * Float.pi) / Float(segments)
        var pts: [(Float, Float)] = []
        pts.reserveCapacity(segments)
        for i in 0..<segments {
            let a = step * Float(i)
            pts.append((Float(center.x) + radius * cos(a), Float(center.y) + radius * sin(a)))
        }
        // Reuse the convex-strip triangulation via tessellatePolylines' addStrip
        // by feeding a degenerate polyline is awkward; emit directly here.
        var v: [Float] = []
        @inline(__always) func emit(_ x: Float, _ y: Float) { v.append(x); v.append(y) }
        let n = pts.count
        guard n >= 3 else { return [] }
        emit(pts[0].0, pts[0].1)
        var front = 1, back = n - 1, takeFront = true
        while front <= back {
            if takeFront { emit(pts[front].0, pts[front].1); front += 1 }
            else         { emit(pts[back].0,  pts[back].1);  back  -= 1 }
            takeFront.toggle()
        }
        return v
    }

    /// Per-stroke inked polyline (world coords) for the current pen position:
    /// full points 0..<m plus, if the pen is mid-segment, the interpolated tip.
    private static func writingPolylines(layout: ProverbLayout.Layout,
                                         clock: WritingClock,
                                         local: CGFloat) -> [[CGPoint]] {
        var out: [[CGPoint]] = []
        for s in clock.strokes {
            let inked = clock.inkedPointCount(s, at: local)
            guard inked > 0 else { continue }
            let stroke = layout.glyphs[s.glyphIndex].strokes[s.strokeIndex]
            if inked >= CGFloat(stroke.count) { out.append(stroke); continue }
            let m = Int(inked.rounded(.down))          // whole points inked: 0..<m
            guard m >= 1 else { continue }
            if m >= stroke.count { out.append(stroke); continue }
            var pts = Array(stroke[0..<m])
            let frac = inked - CGFloat(m)              // into segment [m-1, m]
            if frac > 1e-4 && m < stroke.count {
                let a = stroke[m - 1], b = stroke[m]
                pts.append(CGPoint(x: a.x + (b.x - a.x) * frac,
                                   y: a.y + (b.y - a.y) * frac))
            }
            out.append(pts)
        }
        return out
    }

    /// The pen tip in WORLD coords (interpolated along the active stroke).
    private static func penTipWorld(layout: ProverbLayout.Layout,
                                    pen: WritingClock.Pen) -> CGPoint {
        let stroke = layout.glyphs[pen.glyphIndex].strokes[pen.strokeIndex]
        guard !stroke.isEmpty else { return layout.glyphs[pen.glyphIndex].center }
        let i0 = min(stroke.count - 1, max(0, Int(pen.pointPosition.rounded(.down))))
        let i1 = min(stroke.count - 1, i0 + 1)
        let frac = pen.pointPosition - CGFloat(i0)
        let a = stroke[i0], b = stroke[i1]
        return CGPoint(x: a.x + (b.x - a.x) * frac, y: a.y + (b.y - a.y) * frac)
    }

    // MARK: - Render entry points

    /// Render one frame into the layer's next drawable. `time` is monotonic
    /// elapsed seconds (drives the whole schedule).
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

    /// Isolation test seam (verify.sh / thumbnail). Renders one frame into an
    /// arbitrary target and blocks until the GPU finishes. Deterministic: the
    /// schedule is a pure function of `time`. Not used by the live saver's loop.
    /// `inkWidthGlyphUnits`: VERIFICATION-ONLY override of the ratified default
    /// ink width (`Self.inkWidthGlyphUnits`). Reachable only through this
    /// seam (never the live `newFrame` path), so the shipped default is unchanged.
    /// Used by verify.sh to render `verify-width28.png` at width 28 for the human
    /// width-legibility comparison (operator note 2026-08-12); nil ⇒ the default.
    func renderFrameSynchronously(into target: MTLTexture, time: Double,
                                  inkWidthGlyphUnits: Float? = nil) {
        let size = CGSize(width: target.width, height: target.height)
        if sceneColor == nil || size != sceneSize { resize(size) }
        guard let cmd = queue.makeCommandBuffer() else { return }
        encodeFrame(into: target, time: time, cmd: cmd, inkWidthOverride: inkWidthGlyphUnits)
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    /// Encode the scene pass (offscreen color) and the lighting pass (into
    /// `target`). Single source of pass logic for both entry points.
    private func encodeFrame(into target: MTLTexture, time: Double, cmd: MTLCommandBuffer,
                             inkWidthOverride: Float? = nil) {
        guard let sceneColor = sceneColor else { return }
        let ds = CGSize(width: target.width, height: target.height)

        let aspect = Float(ds.width / ds.height)
        let fillScale = SIMD2<Float>(min(1.0, aspect), min(1.0, 1.0 / aspect))
        let projSizeF = SIMD2<Float>(Self.worldHeight * aspect, Self.worldHeight)
        let proj = CGSize(width: CGFloat(projSizeF.x), height: CGFloat(projSizeF.y))

        // ---- Resolve this frame's proverb + pen + camera + celebrations/finale
        //      (all decided by pure GlyphCore + ParticleField) ----
        var inkVerts: [Float] = []
        var penDotVerts: [Float] = []
        var creamAlpha: Float = 1                         // settled cream ink alpha (scene buffer)
        var camScale: Float = 1
        var camFocus = SIMD2<Float>(projSizeF.x * 0.5, projSizeF.y * 0.5)
        var lights: [PointLightGPU] = []
        var goldFloods: [(verts: [Float], color: SIMD4<Float>)] = []   // per celebrating letter
        var emissiveInkVerts: [Float] = []                // ignited-ink ribbon (triangleStrip)
        var particleInstances: [ParticleQuad] = []        // burst + dissolve quads (instanced)

        if let s = scheduled(atAbsolute: time, proj: proj) {
            let layout = s.layout, clock = s.clock, local = s.local
            let proverbSeed = Self.proverbSeed(scheduleSeed, s.index)
            let camera = CameraPlan.camera(at: local, layout: layout, clock: clock)
            camScale = Float(camera.scale)
            camFocus = SIMD2<Float>(Float(camera.focus.x), Float(camera.focus.y))

            let halfW = (inkWidthOverride ?? Self.inkWidthGlyphUnits) * 0.5 * Float(layout.scale)
            // Partial while writing; full (all points inked) once writing ends —
            // reused as both the cream ink and the ignited-ink geometry.
            let polylines = Self.writingPolylines(layout: layout, clock: clock, local: local)
            inkVerts = Self.tessellatePolylines(polylines, halfW: halfW, capSegments: Self.inkCapSegments)

            var particleQuads: [ParticleQuad] = []

            switch clock.phase(at: local) {
            case .writing:
                creamAlpha = 1
                if let pen = clock.pen(at: local) {
                    let tip = Self.penTipWorld(layout: layout, pen: pen)
                    penDotVerts = Self.discStrip(center: tip,
                                                 radius: halfW * Self.penDotWidthFactor,
                                                 segments: Self.inkCapSegments)
                    // Pen-carried lights, positioned in VIEW space via the camera.
                    let tipV = camera.project(tip)
                    let centerV = camera.project(layout.glyphs[pen.glyphIndex].center)
                    lights.append(Self.makeLight(pos: tipV, color: Self.guideColor,
                                                 intensity: Self.guideIntensity,
                                                 radius: Self.guideRadius * camScale))
                    lights.append(Self.makeLight(pos: tipV, color: Self.greenColor,
                                                 intensity: Self.greenIntensity,
                                                 radius: Self.greenRadius * camScale))
                    lights.append(Self.makeLight(pos: centerV, color: Self.letterAmbientColor,
                                                 intensity: Self.letterAmbientIntensity,
                                                 radius: Self.letterAmbientRadius * camScale))
                }

            case .holding:
                // Admiring gold dwell (game.rs:556-559): [1,0.85,0.3] i10·t r400,
                // t fading 1→0 across the ~5 s hold. Sweep keeps the leather alive.
                creamAlpha = 1
                let holdElapsed = local - clock.writingDuration
                let t = Float(1 - max(0, min(1, holdElapsed / clock.holdDuration)))
                let centerV = SIMD2<Float>(projSizeF.x * 0.5, projSizeF.y * 0.5)
                lights.append(Self.makeLight(pos: CGPoint(x: CGFloat(centerV.x), y: CGFloat(centerV.y)),
                                             color: Self.goldLightColor,
                                             intensity: Self.sayingGoldIntensity * t,
                                             radius: Self.sayingGoldRadius))
                lights.append(holdSweepLight(time: time, proj: projSizeF))

            case .igniting(let t):
                // Cross-fade: cream fades out of the scene buffer as the ignited
                // HDR hue ramps up in the additive emissive pass.
                let e = Self.smoothstep(Float(t))
                creamAlpha = 1 - e
                let ic = FinaleColor.ignite(seed: proverbSeed)
                let col = SIMD4<Float>(Float(ic.r), Float(ic.g), Float(ic.b), e)
                emissiveInkVerts = Self.colorizeStrip(inkVerts, color: col)
                lights.append(holdSweepLight(time: time, proj: projSizeF))

            case .dissolving(let t):
                // Cream is gone; the ignited HDR ink fades out while fireworks are
                // emitted along the stroke paths (coloured like the ignited ink).
                creamAlpha = 0
                let e = Self.smoothstep(Float(t))
                let ic = FinaleColor.ignite(seed: proverbSeed)
                let col = SIMD4<Float>(Float(ic.r), Float(ic.g), Float(ic.b), 1 - e)
                emissiveInkVerts = Self.colorizeStrip(inkVerts, color: col)
                particleQuads += ParticleField.dissolveField(layout: layout, clock: clock,
                                                             local: local, igniteColor: ic,
                                                             proverbSeed: proverbSeed)
                lights.append(holdSweepLight(time: time, proj: projSizeF))

            case .done:
                creamAlpha = 0
                lights.append(holdSweepLight(time: time, proj: projSizeF))
            }

            // Letter celebrations — computed independent of the writing/holding
            // boundary so the LAST letter's 1.2 s gold flood + burst spill into
            // early holding. Empty during the finale (all completions are >1.2 s
            // in the past), so this is safe to always run.
            let cel = letterCelebrations(layout: layout, clock: clock, local: local,
                                         camera: camera)
            goldFloods.append(contentsOf: cel.floods)
            lights.append(contentsOf: cel.lights)
            particleQuads += ParticleField.letterBursts(layout: layout, clock: clock,
                                                        local: local, proverbSeed: proverbSeed)

            particleInstances = particleQuads
        } else {
            // No glyphs/sayings: background-only, single slow sweep (GS-1 look).
            lights = [holdSweepLight(time: time, proj: projSizeF)]
        }

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

            // Ink ribbons (camera-transformed) into the same scene buffer. All
            // scene-buffer geometry (cream ink, gold flood, pen dot) shares the
            // camera uniforms and the ink pipeline.
            var ink = InkUniformsGPU(projSize: projSizeF, focus: camFocus, scale: camScale, pad: 0)
            enc.setRenderPipelineState(inkPipeline)
            enc.setVertexBytes(&ink, length: MemoryLayout<InkUniformsGPU>.stride, index: 1)

            // Settled cream ink (opaque during writing/hold; faded out during the
            // finale ignite — the ignited hue is drawn self-luminous later).
            if creamAlpha > 0, !inkVerts.isEmpty,
               let buf = device.makeBuffer(bytes: inkVerts,
                                           length: inkVerts.count * MemoryLayout<Float>.stride,
                                           options: .storageModeShared) {
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                var color = SIMD4<Float>(Self.inkColor.x, Self.inkColor.y, Self.inkColor.z, creamAlpha)
                enc.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: inkVerts.count / 2)
            }

            // Gold flood ribbons over just-completed letters (game.rs:533-553):
            // wide golden strokes into the scene buffer, LIT by the gold letter
            // light in the following pass (game parity — not self-luminous).
            for flood in goldFloods where !flood.verts.isEmpty {
                if let buf = device.makeBuffer(bytes: flood.verts,
                                               length: flood.verts.count * MemoryLayout<Float>.stride,
                                               options: .storageModeShared) {
                    enc.setVertexBuffer(buf, offset: 0, index: 0)
                    var color = flood.color
                    enc.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: flood.verts.count / 2)
                }
            }

            // Bright pen-tip dot (writing only; same camera, brighter color).
            if !penDotVerts.isEmpty,
               let buf = device.makeBuffer(bytes: penDotVerts,
                                           length: penDotVerts.count * MemoryLayout<Float>.stride,
                                           options: .storageModeShared) {
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                var color = SIMD4<Float>(Self.penDotColor.x, Self.penDotColor.y, Self.penDotColor.z, 1)
                enc.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: penDotVerts.count / 2)
            }
            enc.endEncoding()
        }

        // ---- Lighting pass → target ----
        if lights.isEmpty { lights = [holdSweepLight(time: time, proj: projSizeF)] }
        let count = min(lights.count, 8)
        var lightArray = [PointLightGPU](repeating: PointLightGPU(), count: 8)
        for i in 0..<count { lightArray[i] = lights[i] }

        var uniforms = LightingUniformsGPU()
        uniforms.ambientAndCount = SIMD4<Float>(Self.ambient.x, Self.ambient.y, Self.ambient.z, Float(count))
        uniforms.projSizeFill = SIMD4<Float>(projSizeF.x, projSizeF.y, fillScale.x, fillScale.y)

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
            enc.setFragmentBytes(&lightArray,
                                 length: MemoryLayout<PointLightGPU>.stride * 8, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // ---- Emissive pass → target (LOAD the lit frame, ADD self-luminous HDR).
        //      Ignited ink (triangle strip) + particles (triangle list), both
        //      camera-transformed via the ink uniforms. Skipped when there is
        //      nothing self-luminous this frame (writing/holding with no bursts is
        //      rare — a burst is almost always active during writing). ----
        if !emissiveInkVerts.isEmpty || !particleInstances.isEmpty {
            var ink = InkUniformsGPU(projSize: projSizeF, focus: camFocus, scale: camScale, pad: 0)
            let emissivePass = MTLRenderPassDescriptor()
            emissivePass.colorAttachments[0].texture = target
            emissivePass.colorAttachments[0].loadAction = .load
            emissivePass.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: emissivePass) {
                enc.label = "EmissivePass"
                enc.setVertexBytes(&ink, length: MemoryLayout<InkUniformsGPU>.stride, index: 1)
                // Ignited ink: per-vertex-coloured ribbon (triangle strip).
                if !emissiveInkVerts.isEmpty,
                   let buf = device.makeBuffer(bytes: emissiveInkVerts,
                                               length: emissiveInkVerts.count * MemoryLayout<Float>.stride,
                                               options: .storageModeShared) {
                    enc.setRenderPipelineState(emissivePipeline)
                    enc.setVertexBuffer(buf, offset: 0, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                       vertexCount: emissiveInkVerts.count / 6)
                }
                // Particles: one INSTANCED unit quad (4-vertex strip) per particle.
                // ParticleQuad uploads verbatim as the per-instance buffer (layout
                // matches Shaders.metal ParticleInstance — see that struct).
                if !particleInstances.isEmpty,
                   let buf = device.makeBuffer(bytes: particleInstances,
                                               length: particleInstances.count * MemoryLayout<ParticleQuad>.stride,
                                               options: .storageModeShared) {
                    enc.setRenderPipelineState(particlePipeline)
                    enc.setVertexBuffer(buf, offset: 0, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                       instanceCount: particleInstances.count)
                }
                enc.endEncoding()
            }
        }
    }

    // MARK: - Celebration + emissive geometry helpers

    /// Gold flood ribbons + gold point lights for every letter currently within
    /// its 1.2 s celebration window (game.rs:533-553). The gold color and light
    /// fade with `t = 1 − age/1.2` (game.rs:535: celebrate_timer/CELEBRATE_DURATION,
    /// which decays 1→0). Flood width is the game's literal `8 + 12·t` glyph units
    /// (game.rs:538), mapped to the tessellator's world half-width by the SAME
    /// convention as the cream ink (`widthGlyphUnits · 0.5 · layout.scale`, cf.
    /// `inkWidthGlyphUnits`). NOTE (review-0): at Hello-fat ink widths the
    /// 8→20-unit gold reads as a bright gold CORE inside the cream, not an outer
    /// bloom — that is the game constant applied faithfully; the human owns the
    /// visual call (a re-scale would be a new ratified decision, not a builder tweak).
    private func letterCelebrations(layout: ProverbLayout.Layout,
                                    clock: WritingClock,
                                    local: CGFloat,
                                    camera: Camera)
        -> (floods: [(verts: [Float], color: SIMD4<Float>)], lights: [PointLightGPU]) {
        var completeByGlyph: [Int: CGFloat] = [:]
        for s in clock.strokes {
            completeByGlyph[s.glyphIndex] = max(completeByGlyph[s.glyphIndex] ?? 0, s.endTime)
        }
        var floods: [(verts: [Float], color: SIMD4<Float>)] = []
        var lights: [PointLightGPU] = []
        let camScale = Float(camera.scale)
        for (gi, complete) in completeByGlyph {
            let age = local - complete
            guard age >= 0, age < Self.celebrateDuration else { continue }
            let t = Float(1 - age / Self.celebrateDuration)         // 1 → 0 (game.rs:535)
            let floodWidthGlyphUnits = 8 + 12 * t                   // game.rs:538 (8 + 12·t)
            let floodHalfW = floodWidthGlyphUnits * 0.5 * Float(layout.scale)
            let verts = Self.tessellatePolylines(layout.glyphs[gi].strokes,
                                                 halfW: floodHalfW,
                                                 capSegments: Self.inkCapSegments)
            let gold = SIMD4<Float>(8 * t, 6.8 * t, 2.4 * t, 1)     // game.rs:536
            floods.append((verts, gold))
            let centerV = camera.project(layout.glyphs[gi].center)
            lights.append(Self.makeLight(pos: centerV, color: Self.goldLightColor,
                                         intensity: Self.letterGoldIntensity * t,
                                         radius: Self.letterGoldRadius * camScale))   // game.rs:551
        }
        return (floods, lights)
    }

    /// Attach a uniform per-vertex colour to a plain [x,y,…] strip → the emissive
    /// format [x, y, r, g, b, a] the emissive_vertex shader reads (6 floats/vert).
    private static func colorizeStrip(_ xy: [Float], color c: SIMD4<Float>) -> [Float] {
        guard xy.count >= 2 else { return [] }
        var out: [Float] = []
        out.reserveCapacity(xy.count / 2 * 6)
        var i = 0
        while i + 1 < xy.count {
            out.append(xy[i]); out.append(xy[i + 1])
            out.append(c.x); out.append(c.y); out.append(c.z); out.append(c.w)
            i += 2
        }
        return out
    }

    /// Smoothstep on [0,1] (matches CameraPlan's easing); used to ease the finale
    /// ignite/dissolve ramps so the cross-fades start and end gently.
    private static func smoothstep(_ x: Float) -> Float {
        let c = max(0, min(1, x))
        return c * c * (3 - 2 * c)
    }

    private static func makeLight(pos: CGPoint, color: SIMD3<Float>,
                                  intensity: Float, radius: Float) -> PointLightGPU {
        var l = PointLightGPU()
        l.x = Float(pos.x); l.y = Float(pos.y)
        l.r = color.x; l.g = color.y; l.b = color.z
        l.intensity = intensity; l.radius = radius
        return l
    }

    /// Gentle non-repeating Lissajous guide sweep for hold/finale/background so the
    /// scene never freezes (VISION §3). Two nearly-incommensurate low frequencies.
    private func holdSweepLight(time: Double, proj: SIMD2<Float>) -> PointLightGPU {
        let t = Float(time)
        let cx = proj.x * 0.5, cy = proj.y * 0.5
        let ax = proj.x * 0.36, ay = proj.y * 0.36
        let pos = CGPoint(x: CGFloat(cx + ax * sin(0.13 * t)),
                          y: CGFloat(cy + ay * sin(0.19 * t + 1.3)))
        return Self.makeLight(pos: pos, color: Self.guideColor,
                              intensity: Self.guideIntensity, radius: Self.guideRadius)
    }
}
