// CompositeKernels.metal
//
// Metal compute kernels for Photon's composite workflows: focus stacking, HDR merge, and
// panorama warping/blending. Compiled at runtime with MTLDevice.makeLibrary(source:) —
// see CompositePipelines.swift. All textures are RGBA16F/RGBA32F in linear light; the
// accumulate/resolve pattern processes one source frame at a time so unified memory holds
// at most a handful of full-resolution buffers regardless of stack depth.

#include <metal_stdlib>
using namespace metal;

constant float3 kLumWeights = float3(0.2126f, 0.7152f, 0.0722f);

// ---------------------------------------------------------------------------
// Shared: sharpness measure (focus stacking)
// ---------------------------------------------------------------------------

// Modified-Laplacian sharpness of the luminance channel — a robust per-pixel focus measure.
kernel void sharpnessMeasure(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::write> score [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = src.get_width(), h = src.get_height();
    if (gid.x >= w || gid.y >= h) return;

    uint xm = gid.x == 0 ? 0 : gid.x - 1;
    uint xp = min(gid.x + 1, w - 1);
    uint ym = gid.y == 0 ? 0 : gid.y - 1;
    uint yp = min(gid.y + 1, h - 1);

    float c = dot(src.read(gid).rgb, kLumWeights);
    float l = dot(src.read(uint2(xm, gid.y)).rgb, kLumWeights);
    float r = dot(src.read(uint2(xp, gid.y)).rgb, kLumWeights);
    float u = dot(src.read(uint2(gid.x, ym)).rgb, kLumWeights);
    float d = dot(src.read(uint2(gid.x, yp)).rgb, kLumWeights);

    // Modified Laplacian: |2c - l - r| + |2c - u - d|
    float ml = fabs(2.0f * c - l - r) + fabs(2.0f * c - u - d);
    score.write(float4(ml, 0, 0, 1), gid);
}

// Keep the sharper source per pixel. bestScore/bestColor are updated in place; scores are
// expected pre-blurred (window integration) so the decision map is smooth and halo-free.
kernel void focusAccumulate(
    texture2d<float, access::read> srcColor [[texture(0)]],
    texture2d<float, access::read> srcScore [[texture(1)]],
    texture2d<float, access::read_write> bestColor [[texture(2)]],
    texture2d<float, access::read_write> bestScore [[texture(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= srcColor.get_width() || gid.y >= srcColor.get_height()) return;
    float s = srcScore.read(gid).r;
    float best = bestScore.read(gid).r;
    // Soft transition band avoids hard seams where scores are close.
    float t = smoothstep(-0.02f, 0.02f, s - best);
    if (t > 0.0f) {
        float4 src = srcColor.read(gid);
        float4 cur = bestColor.read(gid);
        bestColor.write(mix(cur, src, t), gid);
        bestScore.write(float4(max(s, best), 0, 0, 1), gid);
    }
}

// ---------------------------------------------------------------------------
// HDR merge
// ---------------------------------------------------------------------------

// Hat weighting over the usable range — trusts mid-exposed pixels most.
static inline float hdrWeight(float3 c) {
    float l = dot(c, kLumWeights);
    return clamp(1.0f - fabs(2.0f * clamp(l, 0.0f, 1.0f) - 1.0f), 0.02f, 1.0f);
}

// Accumulate one bracket frame into the radiance sum.
//   radiance += w * ghostW * (color / exposureFactor)
// ghost suppression compares the exposure-normalised frame with the reference frame and
// down-weights pixels that disagree (motion), keeping handheld brackets clean.
kernel void hdrAccumulate(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::read> reference [[texture(1)]],  // exposure-normalised radiance
    texture2d<float, access::read_write> accumColor [[texture(2)]],
    texture2d<float, access::read_write> accumWeight [[texture(3)]],
    constant float& exposureFactor [[buffer(0)]],   // 2^EV relative to the reference frame
    constant float& ghostStrength [[buffer(1)]],    // 0 = off, ~8 typical
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;

    float4 c = src.read(gid);
    float3 radiance = c.rgb / max(exposureFactor, 1e-6f);
    float w = hdrWeight(c.rgb);

    if (ghostStrength > 0.0f) {
        float3 ref = reference.read(gid).rgb;
        // Relative difference in log-ish space, tolerant in highlights.
        float3 diff = fabs(radiance - ref) / (ref + 0.05f);
        float d = dot(diff, float3(1.0f / 3.0f));
        w *= exp(-ghostStrength * d * d);
    }

    float4 ac = accumColor.read(gid);
    float aw = accumWeight.read(gid).r;
    accumColor.write(float4(ac.rgb + radiance * w, 1.0f), gid);
    accumWeight.write(float4(aw + w, 0, 0, 1), gid);
}

// Resolve the weighted sum into final radiance. Shared by HDR and panorama.
kernel void weightedResolve(
    texture2d<float, access::read> accumColor [[texture(0)]],
    texture2d<float, access::read> accumWeight [[texture(1)]],
    texture2d<float, access::read> fallback [[texture(2)]],   // used where weight ~ 0
    texture2d<float, access::write> out [[texture(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float w = accumWeight.read(gid).r;
    if (w > 1e-5f) {
        float3 c = accumColor.read(gid).rgb / w;
        out.write(float4(c, 1.0f), gid);
    } else {
        out.write(fallback.read(gid), gid);
    }
}

// ---------------------------------------------------------------------------
// Panorama: projective warp with projection models + feathered accumulation
// ---------------------------------------------------------------------------

// Projection modes must match PanoramaService.Projection.
constant int kProjPerspective = 0;
constant int kProjCylindrical = 1;
constant int kProjSpherical = 2;

// For each canvas pixel: map canvas → panorama angular space (by projection) → reference
// plane → source pixel via inverse homography; sample bilinearly and accumulate with an
// edge-feathered weight for seamless blending.
kernel void panoWarpAccumulate(
    texture2d<float, access::sample> src [[texture(0)]],
    texture2d<float, access::read_write> accumColor [[texture(1)]],
    texture2d<float, access::read_write> accumWeight [[texture(2)]],
    constant float3x3& invH [[buffer(0)]],        // canvas-plane → source-image homography
    constant int& projection [[buffer(1)]],
    constant float2& canvasCenter [[buffer(2)]],  // canvas pixel of the pano optical centre
    constant float& focal [[buffer(3)]],          // focal length in canvas pixels
    uint2 gid [[thread_position_in_grid]])
{
    uint w = accumColor.get_width(), h = accumColor.get_height();
    if (gid.x >= w || gid.y >= h) return;

    // Canvas pixel → reference-plane coordinates by inverting the chosen projection.
    float2 p = float2(gid) - canvasCenter;
    float2 plane;
    if (projection == kProjCylindrical) {
        float theta = p.x / focal;
        if (fabs(theta) > 1.55f) return;          // beyond ±~89°: no plane mapping
        plane = float2(focal * tan(theta), p.y / cos(theta));
    } else if (projection == kProjSpherical) {
        float theta = p.x / focal;
        float phi = p.y / focal;
        if (fabs(theta) > 1.55f || fabs(phi) > 1.55f) return;
        plane = float2(focal * tan(theta), focal * tan(phi) / cos(theta));
    } else {
        plane = p;
    }

    // Reference plane → source pixel.
    float3 q = invH * float3(plane, 1.0f);
    if (fabs(q.z) < 1e-8f) return;
    float2 sp = q.xy / q.z;

    float sw = (float)src.get_width(), sh = (float)src.get_height();
    if (sp.x < 0.0f || sp.y < 0.0f || sp.x > sw - 1.0f || sp.y > sh - 1.0f) return;

    constexpr sampler smp(coord::pixel, filter::linear, address::clamp_to_edge);
    float4 c = src.sample(smp, sp);

    // Feather: weight falls to zero at the source frame edges → invisible seams.
    float margin = 0.08f * min(sw, sh);
    float edgeDist = min(min(sp.x, sw - 1.0f - sp.x), min(sp.y, sh - 1.0f - sp.y));
    float feather = clamp(edgeDist / margin, 0.02f, 1.0f);

    float4 ac = accumColor.read(gid);
    float aw = accumWeight.read(gid).r;
    accumColor.write(float4(ac.rgb + c.rgb * feather, 1.0f), gid);
    accumWeight.write(float4(aw + feather, 0, 0, 1), gid);
}

// Coverage map for auto-crop: 1 where the pano has content.
kernel void coverageMap(
    texture2d<float, access::read> accumWeight [[texture(0)]],
    texture2d<float, access::write> coverage [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= coverage.get_width() || gid.y >= coverage.get_height()) return;
    float w = accumWeight.read(gid).r;
    coverage.write(float4(w > 1e-5f ? 1.0f : 0.0f, 0, 0, 1), gid);
}

// Zero-fill a texture (accumulators start empty).
kernel void clearTexture(
    texture2d<float, access::write> tex [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= tex.get_width() || gid.y >= tex.get_height()) return;
    tex.write(float4(0), gid);
}

// ---------------------------------------------------------------------------
// Alignment helper: apply a plain homography to warp a frame onto another frame's grid
// (used by focus stacking and HDR after Vision estimates registration).
// ---------------------------------------------------------------------------

kernel void homographyWarp(
    texture2d<float, access::sample> src [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    constant float3x3& invH [[buffer(0)]],   // out pixel → src pixel
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float3 q = invH * float3(float2(gid), 1.0f);
    if (fabs(q.z) < 1e-8f) {
        out.write(float4(0), gid);
        return;
    }
    float2 sp = q.xy / q.z;
    constexpr sampler smp(coord::pixel, filter::linear, address::clamp_to_edge);
    float2 sz = float2(src.get_width(), src.get_height());
    if (sp.x < -1.0f || sp.y < -1.0f || sp.x > sz.x || sp.y > sz.y) {
        out.write(float4(0), gid);
        return;
    }
    out.write(src.sample(smp, sp), gid);
}
