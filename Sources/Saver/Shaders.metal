//
//  Shaders.metal — Glyph Saver render shaders (MSL)
//  Module maturity: PROTOTYPE (slice GS-1)
//
//  Shipped as SOURCE in Contents/Resources and compiled at RUNTIME via
//  MTLDevice.makeLibrary(source:) — the `metal` tool is NOT on PATH on this
//  machine (see docs/PLAN.md → Toolchain). build.sh must never invoke it.
//
//  PROVENANCE
//  ----------
//  fs_lighting is a straight port of the ZapEngine WGSL dynamic point-light
//  post-process:
//    ../zap-engine/packages/zap-web/src/renderer/lighting.wgsl, lines 52–93
//    (fragment fs_lighting). Ported verbatim in math:
//      - world_pos = uv * proj_size            (wgsl L60)
//      - N = normalize(sample * 2 - 1)         (wgsl L63–64)
//      - norm_dist = saturate(1 - d/radius)    (wgsl L76)
//      - attenuation = norm_dist^2             (wgsl L77)  → falloff (1 - d/r)^2
//      - light_height = radius * 0.3           (wgsl L81)
//      - NdotL = max(dot(N, light_dir), 0)     (wgsl L85)
//      - out = scene.rgb * (ambient + Σ contrib)  (wgsl L87–92)
//    Normal encoding note copied from wgsl L6–7: RGB = tangent normal*0.5+0.5.
//
//  DEVIATION from docs/PLAN.md wording ("a parallel normal buffer"): the web
//  engine bakes many sprites, each with its own normal map, into a normal
//  BUFFER. Here there is exactly ONE static normal source (the leather normal
//  map) and strokes never write normals (VISION: relief shows through ink).
//  So the lighting pass samples the normal TEXTURE directly, with the same
//  aspect-fill transform used for the background, instead of rendering a
//  redundant per-frame normal render-target. Behaviourally identical; smaller.
//

#include <metal_stdlib>
using namespace metal;

// One point light. Scalar-only layout (8 × float = 32 bytes, align 4) so the
// Swift mirror (PointLightGPU) needs no alignment padding tricks.
struct PointLight {
    float x;
    float y;
    float r;
    float g;
    float b;
    float intensity;
    float radius;
    float _pad;
};

// Fragment-stage uniforms for the lighting pass, packed into float4s so the
// Swift mirror (LightingUniformsGPU) matches 16-byte alignment exactly.
struct LightingUniforms {
    float4 ambient_and_count; // xyz = ambient RGB, w = light count
    float4 projsize_fill;     // xy = world proj size, zw = aspect-fill scale
};

struct VSOut {
    float4 position [[position]];
    float2 uv; // screen-space UV in [0,1], Y-DOWN (origin top-left), matches wgsl
};

// Fullscreen triangle. vertex_id 0,1,2 → clip (-1,-1),(3,-1),(-1,3).
// Shared by the scene pass and the lighting pass.
vertex VSOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 g = float2(float((vid << 1) & 2u), float(vid & 2u)); // (0,0),(2,0),(0,2)
    float2 clip = g * 2.0 - 1.0;
    VSOut out;
    out.position = float4(clip, 0.0, 1.0);
    // clip → [0,1], flip Y so texture origin is top-left (Y-down)
    out.uv = float2(g.x, 1.0 - g.y);
    return out;
}

// ---- Scene pass: fullscreen leather quad, aspect-fill into the color buffer.
// GS-2 will additionally draw ink-stroke ribbons into this same target.
fragment float4 scene_fragment(VSOut in [[stage_in]],
                               texture2d<float> leather [[texture(0)]],
                               sampler samp [[sampler(0)]],
                               constant float2 &fillScale [[buffer(0)]]) {
    // Aspect-fill about the texture centre: shrink the sampled range on the
    // longer view axis so the square leather covers the view without distortion.
    float2 uv = 0.5 + (in.uv - 0.5) * fillScale;
    return leather.sample(samp, uv);
}

// ---- Ink pass: Hello-style cream ribbons drawn INTO the scene color buffer
// AFTER the leather and BEFORE lighting (slice GS-2). The render layer
// tessellates each glyph polyline into round-capped/round-joined triangles in
// WORLD coords (y-down); GS-3 draws each partial-inked stroke up to the pen and
// a bright pen-tip dot. Strokes write COLOR ONLY — never normals — so the
// leather relief shows through the ink via the lighting pass (verified engine
// behavior, VISION §4). Cream ink is opaque (alpha 1) so self-overlapping
// cursive loops (e/o/l) compose without double-brightening; the 1 s proverb
// FADE (GS-3) lowers alpha to dissolve the ink back into the leather via the
// pipeline's alpha blend.
//
// GS-3 CAMERA (VISION §3, ratified): the pen carries the writing; the camera
// pulls back from one huge letter to the full block. The transform is applied
// HERE, to ink/pen only — leather (scene pass) and the lighting pass stay
// screen-fixed. view = (world − focus)·scale + projSize/2.
struct InkUniforms {
    float2 projSize;   // world proj size (matches LightingUniforms.projsize_fill.xy)
    float2 focus;      // world point mapped to the view centre (CameraPlan)
    float  scale;      // uniform world→view magnification (CameraPlan)
    float  _pad;
};

vertex float4 ink_vertex(uint vid [[vertex_id]],
                         device const float2 *positions [[buffer(0)]],
                         constant InkUniforms &u [[buffer(1)]]) {
    float2 w = positions[vid];
    float2 view = (w - u.focus) * u.scale + u.projSize * 0.5;   // apply camera
    float2 uv = view / u.projSize;               // y-down [0,1], same as lighting world_pos
    float2 clip = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);   // y-down world → y-up clip
    return float4(clip, 0.0, 1.0);
}

fragment float4 ink_fragment(constant float4 &color [[buffer(0)]]) {
    return color;   // cream (or bright pen dot); lit by the following lighting pass
}

// ---- Lighting pass: port of lighting.wgsl fs_lighting (L52–93).
fragment float4 lighting_fragment(VSOut in [[stage_in]],
                                  texture2d<float> sceneTex [[texture(0)]],
                                  texture2d<float> normalTex [[texture(1)]],
                                  sampler samp [[sampler(0)]],
                                  constant LightingUniforms &u [[buffer(0)]],
                                  constant PointLight *lights [[buffer(1)]]) {
    float2 uv = in.uv;
    float4 scene_color = sceneTex.sample(samp, uv);

    float3 ambient = u.ambient_and_count.xyz;
    uint light_count = uint(u.ambient_and_count.w);
    float2 proj_size = u.projsize_fill.xy;
    float2 fill_scale = u.projsize_fill.zw;

    // Normal sampled with the SAME aspect-fill transform as the background so
    // the relief stays registered to the leather (wgsl L62–64).
    float2 nUV = 0.5 + (uv - 0.5) * fill_scale;
    float3 normal_sample = normalTex.sample(samp, nUV).xyz;
    float3 N = normalize(normal_sample * 2.0 - 1.0);

    // Orthographic, Y-down world position (wgsl L60).
    float2 world_pos = uv * proj_size;

    float3 total_light = ambient;
    for (uint i = 0u; i < light_count; i = i + 1u) {
        PointLight light = lights[i];
        float2 light_pos = float2(light.x, light.y);
        float2 delta = light_pos - world_pos;
        float d = length(delta);

        float norm_dist = saturate(1.0 - d / light.radius);
        float attenuation = norm_dist * norm_dist;

        float light_height = light.radius * 0.3;
        float3 light_dir = normalize(float3(delta, light_height));
        float NdotL = max(dot(N, light_dir), 0.0);

        float3 contribution = float3(light.r, light.g, light.b) * light.intensity * attenuation * NdotL;
        total_light = total_light + contribution;
    }

    return float4(scene_color.rgb * total_light, scene_color.a);
}
