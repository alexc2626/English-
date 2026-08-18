// PhotonKernels.ci.metal
//
// Custom Core Image kernels for Photon's develop pipeline. Compiled with -fcikernel into the
// default metallib and loaded by KernelLibrary. All kernels operate on linear-light RGBA
// (unpremultiplied where noted) and mirror the CPU reference implementations in PhotonCore,
// which are the unit-tested source of truth for the math.

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>

using namespace metal;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static inline float lum(float3 c) {
    return dot(c, float3(0.2126f, 0.7152f, 0.0722f));
}

static inline float3 clamp01(float3 c) {
    return clamp(c, 0.0f, 1.0f);
}

// RGB <-> HSL matching PhotonCore.HSLRemap (h in degrees).
static inline float3 rgb2hsl(float3 c) {
    float maxV = max3(c.r, c.g, c.b);
    float minV = min3(c.r, c.g, c.b);
    float l = (maxV + minV) * 0.5f;
    if (maxV == minV) return float3(0.0f, 0.0f, l);
    float d = maxV - minV;
    float s = l > 0.5f ? d / (2.0f - maxV - minV) : d / (maxV + minV);
    float h;
    if (maxV == c.r)      h = (c.g - c.b) / d + (c.g < c.b ? 6.0f : 0.0f);
    else if (maxV == c.g) h = (c.b - c.r) / d + 2.0f;
    else                  h = (c.r - c.g) / d + 4.0f;
    return float3(h * 60.0f, s, l);
}

static inline float hue2rgb(float p, float q, float t) {
    if (t < 0.0f) t += 1.0f;
    if (t > 1.0f) t -= 1.0f;
    if (t < 1.0f / 6.0f) return p + (q - p) * 6.0f * t;
    if (t < 0.5f) return q;
    if (t < 2.0f / 3.0f) return p + (q - p) * (2.0f / 3.0f - t) * 6.0f;
    return p;
}

static inline float3 hsl2rgb(float3 hsl) {
    float h = hsl.x / 360.0f;
    if (hsl.y == 0.0f) return float3(hsl.z);
    float q = hsl.z < 0.5f ? hsl.z * (1.0f + hsl.y) : hsl.z + hsl.y - hsl.z * hsl.y;
    float p = 2.0f * hsl.z - q;
    return float3(hue2rgb(p, q, h + 1.0f / 3.0f), hue2rgb(p, q, h),
                  hue2rgb(p, q, h - 1.0f / 3.0f));
}

// ---------------------------------------------------------------------------
// Tone: exposure / contrast / highlights / shadows / whites / blacks
// ---------------------------------------------------------------------------

// Applies the Basic panel's tone sliders in linear light. Slider inputs are pre-normalised
// on the CPU: exposure in EV, the rest as -1…+1.
extern "C" float4 basicTone(coreimage::sample_t s,
                            float exposure, float contrast,
                            float highlights, float shadows,
                            float whites, float blacks) {
    float3 c = s.rgb;

    // Exposure: straight linear gain.
    c *= exp2(exposure);

    // Luminance-weighted region adjustments, computed on a tone-mapped luma so the
    // weights match perceived brightness.
    float l = lum(clamp01(c));

    // Highlights / shadows: raised-cosine weighted lift/cut with soft knee.
    float wh = smoothstep(0.5f, 1.0f, l);          // highlight membership
    float ws = 1.0f - smoothstep(0.0f, 0.5f, l);   // shadow membership
    c *= (1.0f + highlights * 0.6f * wh);
    c *= (1.0f + shadows * 0.6f * ws);

    // Whites / blacks: endpoint remapping.
    // whites > 0 raises the white point gain; blacks < 0 deepens the black point.
    float whiteGain = 1.0f + whites * 0.35f * smoothstep(0.7f, 1.0f, l);
    c *= whiteGain;
    float blackLift = blacks * 0.25f * (1.0f - smoothstep(0.0f, 0.35f, l));
    c += blackLift;

    // Contrast: S-curve pivoting at mid-grey (0.5 in gamma-ish space; approximate in linear
    // with a power pivot).
    float k = 1.0f + contrast;                     // contrast in -1…+1 → gain 0…2
    c = (c - 0.5f) * k + 0.5f;

    return float4(max(c, float3(0.0f)), s.a);
}

// ---------------------------------------------------------------------------
// White balance for non-RAW sources (RAW WB happens inside CIRAWFilter)
// ---------------------------------------------------------------------------

// temperature/tint as relative shifts (-1…+1). Approximates a Bradford shift by scaling
// the blue-yellow and green-magenta axes.
extern "C" float4 whiteBalance(coreimage::sample_t s, float temperature, float tint) {
    float3 c = s.rgb;
    // Warm: boost R, cut B. Cool: inverse. Tint>0: magenta (boost R+B, cut G).
    float t = temperature * 0.3f;
    float g = tint * 0.2f;
    c.r *= (1.0f + t + g * 0.5f);
    c.g *= (1.0f - g);
    c.b *= (1.0f - t + g * 0.5f);
    return float4(max(c, float3(0.0f)), s.a);
}

// ---------------------------------------------------------------------------
// Vibrance / saturation
// ---------------------------------------------------------------------------

extern "C" float4 vibranceSaturation(coreimage::sample_t s, float vibrance, float saturation) {
    float3 c = clamp01(s.rgb);
    float l = lum(c);

    // Saturation: uniform lerp away from luma.
    c = mix(float3(l), c, 1.0f + saturation);

    // Vibrance: boosts low-saturation pixels more, protects skin tones (hue ~20-50°).
    float3 hsl = rgb2hsl(clamp01(c));
    float satWeight = 1.0f - smoothstep(0.3f, 0.9f, hsl.y);   // stronger on muted colours
    float skin = smoothstep(10.0f, 20.0f, hsl.x) * (1.0f - smoothstep(50.0f, 70.0f, hsl.x));
    float protectedWeight = satWeight * (1.0f - skin * 0.7f);
    c = mix(float3(lum(clamp01(c))), clamp01(c), 1.0f + vibrance * protectedWeight);

    return float4(clamp01(c), s.a);
}

// ---------------------------------------------------------------------------
// Tone curve via 1D LUTs (composite + per-channel), sampled from a 4×lutSize strip image:
// row 0 = composite, rows 1-3 = R/G/B. See ToneCurveEvaluator.
// ---------------------------------------------------------------------------

extern "C" float4 toneCurveLUT(coreimage::sample_t s, coreimage::sampler lutStrip,
                               float lutWidth) {
    float3 c = clamp01(s.rgb);
    float2 extent = lutStrip.size();
    // Composite curve applied per channel (Lightroom's point curve semantics).
    float3 outc;
    for (int ch = 0; ch < 3; ch++) {
        float v = ch == 0 ? c.r : (ch == 1 ? c.g : c.b);
        float x = (v * (lutWidth - 1.0f) + 0.5f) / extent.x;
        float composite = lutStrip.sample(float2(x, 0.5f / extent.y)).r;
        float rowY = (float(ch + 1) + 0.5f) / extent.y;
        float channelMapped = lutStrip.sample(float2(
            (composite * (lutWidth - 1.0f) + 0.5f) / extent.x, rowY)).r;
        if (ch == 0) outc.r = channelMapped;
        else if (ch == 1) outc.g = channelMapped;
        else outc.b = channelMapped;
    }
    return float4(outc, s.a);
}

// ---------------------------------------------------------------------------
// HSL colour mixer — mirrors PhotonCore.HSLRemap
// ---------------------------------------------------------------------------

// Band parameters arrive as three float8-ish packings: hue shifts, sat scales, lum scales for
// the 8 bands (degrees /100 pre-scaled on CPU as in HSLRemap.apply).
extern "C" float4 hslRemap(coreimage::sample_t s,
                           float4 hueA, float4 hueB,       // red,orange,yellow,green | aqua,blue,purple,magenta
                           float4 satA, float4 satB,
                           float4 lumA, float4 lumB) {
    constexpr float centers[8] = {0.0f, 30.0f, 60.0f, 120.0f, 180.0f, 240.0f, 280.0f, 320.0f};
    float hueAdj[8] = {hueA.x, hueA.y, hueA.z, hueA.w, hueB.x, hueB.y, hueB.z, hueB.w};
    float satAdj[8] = {satA.x, satA.y, satA.z, satA.w, satB.x, satB.y, satB.z, satB.w};
    float lumAdj[8] = {lumA.x, lumA.y, lumA.z, lumA.w, lumB.x, lumB.y, lumB.z, lumB.w};

    float3 hsl = rgb2hsl(clamp01(s.rgb));
    float h = hsl.x, sat = hsl.y, l = hsl.z;

    float hueShift = 0.0f, satScale = 0.0f, lumScale = 0.0f;
    for (int i = 0; i < 8; i++) {
        float center = centers[i];
        float prev = centers[(i + 7) % 8];
        float next = centers[(i + 1) % 8];
        // signed shortest distance center→h
        float d = fmod(h - center + 540.0f, 360.0f) - 180.0f;
        float w = 0.0f;
        if (d == 0.0f) {
            w = 1.0f;
        } else if (d > 0.0f) {
            float span = fmod(next - center + 540.0f, 360.0f) - 180.0f;
            if (span > 0.0f && d < span) w = 0.5f * (1.0f + cos(M_PI_F * d / span));
        } else {
            float span = fmod(prev - center + 540.0f, 360.0f) - 180.0f;
            if (span < 0.0f && d > span) w = 0.5f * (1.0f + cos(M_PI_F * d / span));
        }
        hueShift += w * hueAdj[i] * 30.0f;
        satScale += w * satAdj[i];
        lumScale += w * lumAdj[i];
    }

    float gate = min(sat * 4.0f, 1.0f);
    h = fmod(h + hueShift * gate + 360.0f, 360.0f);
    sat = clamp(sat * (1.0f + satScale), 0.0f, 1.0f);
    l = lumScale >= 0.0f
        ? l + (1.0f - l) * lumScale * 0.5f * gate
        : l + l * lumScale * 0.5f * gate;

    return float4(hsl2rgb(float3(h, sat, clamp(l, 0.0f, 1.0f))), s.a);
}

// B&W conversion mix — mirrors HSLRemap.bwMix.
extern "C" float4 bwMix(coreimage::sample_t s, float4 mixA, float4 mixB) {
    constexpr float centers[8] = {0.0f, 30.0f, 60.0f, 120.0f, 180.0f, 240.0f, 280.0f, 320.0f};
    float mixAdj[8] = {mixA.x, mixA.y, mixA.z, mixA.w, mixB.x, mixB.y, mixB.z, mixB.w};

    float3 c = clamp01(s.rgb);
    float3 hsl = rgb2hsl(c);
    float base = lum(c);

    float delta = 0.0f;
    for (int i = 0; i < 8; i++) {
        float center = centers[i];
        float prev = centers[(i + 7) % 8];
        float next = centers[(i + 1) % 8];
        float d = fmod(hsl.x - center + 540.0f, 360.0f) - 180.0f;
        float w = 0.0f;
        if (d == 0.0f) {
            w = 1.0f;
        } else if (d > 0.0f) {
            float span = fmod(next - center + 540.0f, 360.0f) - 180.0f;
            if (span > 0.0f && d < span) w = 0.5f * (1.0f + cos(M_PI_F * d / span));
        } else {
            float span = fmod(prev - center + 540.0f, 360.0f) - 180.0f;
            if (span < 0.0f && d > span) w = 0.5f * (1.0f + cos(M_PI_F * d / span));
        }
        delta += w * mixAdj[i];
    }
    float grey = clamp(base + delta * 0.5f * min(hsl.y * 2.0f, 1.0f), 0.0f, 1.0f);
    return float4(float3(grey), s.a);
}

// ---------------------------------------------------------------------------
// Colour grading (3-way wheels) — mirrors ColorGradingMath
// ---------------------------------------------------------------------------

// Each wheel packed as float4(rOffset, gOffset, bOffset, lumLift), pre-computed on CPU by
// ColorGradingMath.wheelOffset.
extern "C" float4 colorGrade(coreimage::sample_t s,
                             float4 shadowsOff, float4 midtonesOff, float4 highlightsOff,
                             float4 globalOff, float blending, float balance) {
    float3 c = clamp01(s.rgb);
    float l = lum(c);

    float overlap = 0.05f + blending * 0.45f;          // blending pre-normalised 0…1
    float shift = balance * 0.25f;                      // balance pre-normalised -1…1
    float sEdge = 0.33f + shift;
    float hEdge = 0.66f + shift;

    float ws = 1.0f - smoothstep(sEdge - overlap, sEdge + overlap, l);
    float wh = smoothstep(hEdge - overlap, hEdge + overlap, l);
    float wm = max(0.0f, 1.0f - ws - wh);

    float tonalGate = 1.0f - pow(abs(2.0f * l - 1.0f), 2.0f);

    float4 offs[4] = {shadowsOff, midtonesOff, highlightsOff, globalOff};
    float ws4[4] = {ws, wm, wh, 1.0f};
    for (int i = 0; i < 4; i++) {
        c += offs[i].rgb * ws4[i] * tonalGate + offs[i].w * ws4[i] * 0.5f;
    }
    return float4(clamp01(c), s.a);
}

// ---------------------------------------------------------------------------
// Texture / Clarity / Dehaze
// ---------------------------------------------------------------------------

// Texture & clarity share a structure: add back a band-passed detail layer.
// The blurred inputs are produced by CIGaussianBlur upstream (GPU-resident); this kernel
// just does the frequency-band arithmetic, keeping the whole chain on the GPU.
//   texture uses a small radius blur (fine detail), clarity a large radius (local contrast).
extern "C" float4 detailBoost(coreimage::sample_t s, coreimage::sample_t smallBlur,
                              coreimage::sample_t largeBlur,
                              float texture, float clarity) {
    float3 c = s.rgb;

    // Texture: fine band = original - smallBlur.
    float3 fine = s.rgb - smallBlur.rgb;
    c += fine * texture * 1.2f;

    // Clarity: midtone-weighted local contrast = original - largeBlur.
    float3 coarse = s.rgb - largeBlur.rgb;
    float l = lum(clamp01(s.rgb));
    float midWeight = 1.0f - abs(2.0f * l - 1.0f);      // strongest in midtones
    c += coarse * clarity * 1.5f * midWeight;

    return float4(max(c, float3(0.0f)), s.a);
}

// Dehaze: simplified dark-channel prior. airlight ≈ 1.0 (estimated upstream per-image),
// transmission from the local dark channel (minBlur = min-filtered, blurred image provided
// upstream via CIMorphologyMinimum + blur).
extern "C" float4 dehaze(coreimage::sample_t s, coreimage::sample_t minBlur,
                         float amount, float3 airlight) {
    float darkChannel = min3(minBlur.r, minBlur.g, minBlur.b);
    // Estimated transmission; amount>0 removes haze, amount<0 adds it.
    float t = clamp(1.0f - 0.95f * darkChannel * amount, 0.05f, 1.0f);
    float3 c;
    if (amount >= 0.0f) {
        c = (s.rgb - airlight * (1.0f - t)) / max(t, 0.1f);
        // Gentle saturation compensation, as dehazing tends to dull colours.
        float l = lum(clamp01(c));
        c = mix(float3(l), c, 1.0f + amount * 0.15f);
    } else {
        // Negative dehaze: blend toward airlight.
        c = mix(s.rgb, airlight, -amount * 0.4f);
    }
    return float4(max(c, float3(0.0f)), s.a);
}

// ---------------------------------------------------------------------------
// Sharpening with edge masking (unsharp mask + threshold on edge energy)
// ---------------------------------------------------------------------------

extern "C" float4 sharpen(coreimage::sample_t s, coreimage::sample_t blurred,
                          coreimage::sample_t edgeEnergy,
                          float amount, float detail, float masking) {
    float3 high = s.rgb - blurred.rgb;
    // Detail: how much of the fine high-frequency signal survives (halo suppression low).
    float3 boost = high * mix(0.5f, 1.5f, detail);
    // Edge mask: suppress sharpening in flat areas as masking rises.
    float edge = clamp(edgeEnergy.r * 8.0f, 0.0f, 1.0f);
    float maskWeight = mix(1.0f, smoothstep(masking * 0.5f, masking, edge), step(0.001f, masking));
    float3 c = s.rgb + boost * amount * maskWeight;
    return float4(max(c, float3(0.0f)), s.a);
}

// Visualise the sharpening edge mask (Option-drag on the Masking slider).
extern "C" float4 sharpenMaskPreview(coreimage::sample_t edgeEnergy, float masking) {
    float edge = clamp(edgeEnergy.r * 8.0f, 0.0f, 1.0f);
    float w = smoothstep(masking * 0.5f, max(masking, 0.001f), edge);
    return float4(float3(w), 1.0f);
}

// ---------------------------------------------------------------------------
// Post-crop vignette
// ---------------------------------------------------------------------------

// dest coordinate kernel: needs pixel position. extent = (x, y, w, h) of the cropped image.
extern "C" float4 postCropVignette(coreimage::sample_t s, coreimage::destination dest,
                                   float4 extent, float amount, float midpoint,
                                   float roundness, float feather, float highlights) {
    float2 center = extent.xy + extent.zw * 0.5f;
    float2 p = (dest.coord() - center) / (extent.zw * 0.5f);   // -1…1 across the crop

    // Roundness morphs between rectangular (superellipse n→large) and circular/oval.
    float n = mix(4.0f, 2.0f, clamp(roundness * 0.5f + 0.5f, 0.0f, 1.0f));
    float d = pow(pow(abs(p.x), n) + pow(abs(p.y), n), 1.0f / n);

    float mid = mix(0.3f, 1.2f, midpoint);
    float f = max(feather, 0.01f);
    float vig = smoothstep(mid - f, mid + f, d);

    float3 c = s.rgb;
    if (amount < 0.0f) {
        // Darken; highlight protection keeps speculars bright.
        float l = lum(clamp01(c));
        float protect = highlights * smoothstep(0.6f, 1.0f, l);
        float dark = 1.0f + amount * vig * (1.0f - protect);
        c *= max(dark, 0.0f);
    } else {
        // Lighten.
        c += amount * vig * (1.0f - c);
    }
    return float4(c, s.a);
}

// ---------------------------------------------------------------------------
// Film grain
// ---------------------------------------------------------------------------

static inline float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031f);
    p3 += dot(p3, p3.yzx + 33.33f);
    return fract((p3.x + p3.y) * p3.z);
}

extern "C" float4 filmGrain(coreimage::sample_t s, coreimage::destination dest,
                            float amount, float size, float roughness, float seed) {
    float2 cell = floor(dest.coord() / max(size, 1.0f));
    float g1 = hash12(cell + seed);
    // Roughness blends a second, offset noise octave for a coarser texture.
    float g2 = hash12(cell * 0.5f + seed + 17.0f);
    float g = mix(g1, (g1 + g2) * 0.5f, roughness) - 0.5f;

    // Grain response is strongest in midtones, like film.
    float l = lum(clamp01(s.rgb));
    float weight = 1.0f - abs(2.0f * l - 1.0f) * 0.7f;
    float3 c = s.rgb + g * amount * 0.25f * weight;
    return float4(max(c, float3(0.0f)), s.a);
}

// ---------------------------------------------------------------------------
// Calibration: primaries hue/sat shifts + shadow tint
// ---------------------------------------------------------------------------

extern "C" float4 calibration(coreimage::sample_t s,
                              float2 redShift, float2 greenShift, float2 blueShift,
                              float shadowTint) {
    // Shift each primary's contribution: rotate hue of the channel basis and scale sat.
    // Implemented as channel remixing: hue shift of primary P rotates P's row toward its
    // neighbours; saturation scales P's off-diagonal bleed.
    float3 c = clamp01(s.rgb);

    float3x3 m = float3x3(1.0f);
    // red primary
    m[0][0] = 1.0f + redShift.y * 0.3f;
    m[1][0] = redShift.x > 0.0f ? redShift.x * 0.3f : 0.0f;     // toward green
    m[2][0] = redShift.x < 0.0f ? -redShift.x * 0.3f : 0.0f;    // toward blue (magenta)
    // green primary
    m[1][1] = 1.0f + greenShift.y * 0.3f;
    m[2][1] = greenShift.x > 0.0f ? greenShift.x * 0.3f : 0.0f;
    m[0][1] = greenShift.x < 0.0f ? -greenShift.x * 0.3f : 0.0f;
    // blue primary
    m[2][2] = 1.0f + blueShift.y * 0.3f;
    m[0][2] = blueShift.x > 0.0f ? blueShift.x * 0.3f : 0.0f;
    m[1][2] = blueShift.x < 0.0f ? -blueShift.x * 0.3f : 0.0f;

    float3 outc = m * c;

    // Shadow tint: green-magenta cast in the darks.
    float l = lum(c);
    float w = 1.0f - smoothstep(0.0f, 0.4f, l);
    outc.g -= shadowTint * 0.1f * w;
    outc.r += shadowTint * 0.05f * w;
    outc.b += shadowTint * 0.05f * w;

    // Renormalise approximate energy.
    return float4(max(outc, float3(0.0f)), s.a);
}

// ---------------------------------------------------------------------------
// Mask combination + local adjustments
// ---------------------------------------------------------------------------

// Combine one component raster into the accumulated mask. mode: 0=add, 1=subtract,
// 2=intersect; invert flips the component first. Mirrors MaskBlending.combine.
extern "C" float4 maskCombine(coreimage::sample_t acc, coreimage::sample_t comp,
                              float mode, float invert, float started) {
    float m = acc.r;
    float c = clamp(comp.r, 0.0f, 1.0f);
    c = mix(c, 1.0f - c, invert);
    float outm;
    if (mode < 0.5f) {          // add (screen union)
        outm = m + c - m * c;
    } else if (mode < 1.5f) {   // subtract
        outm = m * (1.0f - c);
    } else {                    // intersect
        outm = started > 0.5f ? m * c : c;
    }
    return float4(float3(clamp(outm, 0.0f, 1.0f)), 1.0f);
}

// Feather approximation on a mask raster is done upstream with CIGaussianBlur.
// Invert a full mask (the mask-level invert toggle).
extern "C" float4 maskInvert(coreimage::sample_t m) {
    return float4(float3(1.0f - clamp(m.r, 0.0f, 1.0f)), 1.0f);
}

// Apply a mask's local adjustments: blend the fully-adjusted image with the base by the
// mask coverage (scaled by amount). adjusted = the same pipeline stages applied globally
// with the mask's slider values; this kernel is just the coverage lerp, so local edits
// compose exactly like Lightroom's.
extern "C" float4 maskedBlend(coreimage::sample_t base, coreimage::sample_t adjusted,
                              coreimage::sample_t mask, float amount) {
    float w = clamp(mask.r, 0.0f, 1.0f) * amount;
    return float4(mix(base.rgb, adjusted.rgb, w), base.a);
}

// Red overlay preview ("O" key): show mask coverage as translucent red over the image.
extern "C" float4 maskOverlay(coreimage::sample_t image, coreimage::sample_t mask,
                              float overlayOn) {
    float w = clamp(mask.r, 0.0f, 1.0f) * overlayOn;
    float3 c = mix(image.rgb, float3(1.0f, 0.1f, 0.1f), w * 0.5f);
    return float4(c, image.a);
}

// Luminance range mask raster — mirrors MaskBlending.rangeCoverage.
extern "C" float4 luminanceRangeMask(coreimage::sample_t s, float low, float high,
                                     float smoothness) {
    float v = lum(clamp01(s.rgb));
    float c;
    if (v >= low && v <= high) {
        c = 1.0f;
    } else {
        float d = v < low ? low - v : v - high;
        float sm = max(smoothness, 1e-6f);
        c = d < sm ? 0.5f * (1.0f + cos(M_PI_F * d / sm)) : 0.0f;
    }
    return float4(float3(c), 1.0f);
}

// Colour range mask raster — mirrors MaskBlending.colorRangeCoverage for up to 5 samples
// (unused samples have w < 0).
extern "C" float4 colorRangeMask(coreimage::sample_t s,
                                 float4 s0, float4 s1, float4 s2, float4 s3, float4 s4,
                                 float refineWidth) {
    float3 c = clamp01(s.rgb);
    float3 hslC = rgb2hsl(c);
    float best = 1e9f;
    float4 samples[5] = {s0, s1, s2, s3, s4};
    for (int i = 0; i < 5; i++) {
        if (samples[i].w < 0.0f) continue;
        float3 sc = samples[i].rgb;
        float3 hslS = rgb2hsl(sc);
        float dh = abs(fmod(hslC.x - hslS.x + 540.0f, 360.0f) - 180.0f) / 180.0f;
        float ds = abs(hslC.y - hslS.y);
        float drgb = distance(c, sc) / sqrt(3.0f);
        best = min(best, dh * 0.6f + ds * 0.2f + drgb * 0.2f);
    }
    float cov = best < refineWidth ? 0.5f * (1.0f + cos(M_PI_F * best / refineWidth)) : 0.0f;
    return float4(float3(cov), 1.0f);
}

// Linear gradient mask raster — mirrors MaskBlending.linearGradientCoverage.
// start/end in image pixel coordinates.
extern "C" float4 linearGradientMask(coreimage::destination dest,
                                     float2 start, float2 end) {
    float2 d = end - start;
    float lenSq = dot(d, d);
    float t = lenSq > 1e-9f ? dot(dest.coord() - start, d) / lenSq : 0.0f;
    float x = clamp(1.0f - t, 0.0f, 1.0f);
    float cov = x * x * (3.0f - 2.0f * x);
    return float4(float3(cov), 1.0f);
}

// Radial gradient mask raster — mirrors MaskBlending.radialGradientCoverage.
extern "C" float4 radialGradientMask(coreimage::destination dest,
                                     float2 center, float2 radii,
                                     float rotationRad, float feather) {
    float2 p = dest.coord() - center;
    float cs = cos(rotationRad), sn = sin(rotationRad);
    float2 r = float2(p.x * cs + p.y * sn, -p.x * sn + p.y * cs);
    float d = length(r / max(radii, float2(1e-6f)));
    float f = max(feather, 0.001f);
    float t = (d - (1.0f - f)) / (2.0f * f);
    float x = clamp(1.0f - t, 0.0f, 1.0f);
    float cov = x * x * (3.0f - 2.0f * x);
    return float4(float3(cov), 1.0f);
}

// Depth range mask from a depth map — mirrors MaskBlending.rangeCoverage over depth.
extern "C" float4 depthRangeMask(coreimage::sample_t depth, float near, float far,
                                 float smoothness) {
    float v = clamp(depth.r, 0.0f, 1.0f);
    float c;
    if (v >= near && v <= far) {
        c = 1.0f;
    } else {
        float d = v < near ? near - v : v - far;
        float sm = max(smoothness, 1e-6f);
        c = d < sm ? 0.5f * (1.0f + cos(M_PI_F * d / sm)) : 0.0f;
    }
    return float4(float3(c), 1.0f);
}

// ---------------------------------------------------------------------------
// Local adjustment colour ops that differ from their global counterparts
// ---------------------------------------------------------------------------

// Local temperature/tint/hue for masked regions (relative shifts -1…+1).
extern "C" float4 localColor(coreimage::sample_t s, float temperature, float tint,
                             float hueShift, float saturation) {
    float3 c = clamp01(s.rgb);
    // WB-style shift
    float t = temperature * 0.25f;
    float g = tint * 0.15f;
    c.r *= (1.0f + t + g * 0.5f);
    c.g *= (1.0f - g);
    c.b *= (1.0f - t + g * 0.5f);
    // Hue rotation + saturation
    float3 hsl = rgb2hsl(clamp01(c));
    hsl.x = fmod(hsl.x + hueShift * 60.0f + 360.0f, 360.0f);
    hsl.y = clamp(hsl.y * (1.0f + saturation), 0.0f, 1.0f);
    return float4(hsl2rgb(hsl), s.a);
}

// ---------------------------------------------------------------------------
// Spot removal: clone/heal one circular patch. Source content arrives as a shifted sampler.
// ---------------------------------------------------------------------------

// dstLow / srcLowShifted are heavily blurred copies of the image (and of the shifted source),
// produced upstream by CIGaussianBlur — the whole heal stays GPU-resident.
extern "C" float4 spotPatch(coreimage::sample_t dstImage, coreimage::sample_t srcShifted,
                            coreimage::sample_t dstLow, coreimage::sample_t srcLowShifted,
                            coreimage::destination dest,
                            float2 center, float radius, float feather, float opacity,
                            float healMode) {
    float d = distance(dest.coord(), center) / max(radius, 1.0f);
    float f = clamp(feather, 0.01f, 1.0f);
    float t = clamp((1.0f - d) / f, 0.0f, 1.0f);
    float w = t * t * (3.0f - 2.0f * t);            // smooth falloff to patch edge

    float3 src = srcShifted.rgb;
    // Heal mode: match the source patch's low-frequency tone to the destination
    // neighbourhood (Lightroom's heal vs clone distinction).
    float3 healed = src + (dstLow.rgb - srcLowShifted.rgb);
    float3 patch = mix(src, healed, healMode);

    return float4(mix(dstImage.rgb, patch, w * opacity), dstImage.a);
}

// ---------------------------------------------------------------------------
// Chromatic aberration / defringe
// ---------------------------------------------------------------------------

extern "C" float4 defringe(coreimage::sample_t s, float purpleAmount, float greenAmount) {
    float3 c = clamp01(s.rgb);
    float3 hsl = rgb2hsl(c);
    // Purple fringe: hue 260-320; green fringe: hue 80-160. Desaturate on high-contrast edges
    // is approximated by plain band desaturation scaled by saturation itself.
    float purple = smoothstep(255.0f, 275.0f, hsl.x) * (1.0f - smoothstep(310.0f, 330.0f, hsl.x));
    float green = smoothstep(75.0f, 95.0f, hsl.x) * (1.0f - smoothstep(145.0f, 165.0f, hsl.x));
    float cut = purple * purpleAmount + green * greenAmount;
    hsl.y *= (1.0f - clamp(cut, 0.0f, 1.0f));
    return float4(hsl2rgb(hsl), s.a);
}

// ---------------------------------------------------------------------------
// Manual lens vignette (pre-crop, optical centre) and distortion helper
// ---------------------------------------------------------------------------

extern "C" float4 lensVignette(coreimage::sample_t s, coreimage::destination dest,
                               float4 extent, float amount, float midpoint) {
    float2 center = extent.xy + extent.zw * 0.5f;
    float2 p = (dest.coord() - center) / (length(extent.zw) * 0.5f);
    float d = length(p);
    float mid = mix(0.2f, 1.0f, midpoint);
    float vig = smoothstep(mid * 0.5f, mid * 1.5f, d);
    float3 c = s.rgb;
    if (amount < 0.0f) {
        c *= (1.0f + amount * vig);
    } else {
        c += amount * vig * (1.0f - c);
    }
    return float4(max(c, float3(0.0f)), s.a);
}

// Simple radial barrel/pincushion warp for manual distortion correction.
extern "C" float2 radialDistortWarp(coreimage::destination dest, float2 center,
                                    float normScale, float k) {
    float2 p = (dest.coord() - center) * normScale;   // roughly -1…1
    float r2 = dot(p, p);
    float scale = 1.0f + k * r2;
    float2 srcP = center + (p * scale) / normScale;
    return srcP;
}
