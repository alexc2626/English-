import Foundation

/// Three-way colour grading math: luminance-range weights for the Shadows / Midtones /
/// Highlights wheels, with Blending and Balance controls matching Lightroom's behaviour.
public enum ColorGradingMath {

    /// Weights of the three tonal ranges at luminance `l` (0…1). Weights sum to ≤ 1; the
    /// midtone lobe fills the gap. `blending` (0…100) widens the overlap between ranges;
    /// `balance` (−100…+100) shifts the shadow/highlight crossover point.
    public static func rangeWeights(luminance l: Double, blending: Double, balance: Double)
        -> (shadows: Double, midtones: Double, highlights: Double) {
        let overlap = 0.05 + (blending / 100) * 0.45          // shoulder width 0.05…0.5
        let shift = (balance / 100) * 0.25                    // crossover shift ±0.25

        // Shadows fall off around 0.33+shift, highlights rise around 0.66+shift.
        let sEdge = 0.33 + shift
        let hEdge = 0.66 + shift

        let s = 1 - smoothstep(edge0: sEdge - overlap, edge1: sEdge + overlap, x: l)
        let h = smoothstep(edge0: hEdge - overlap, edge1: hEdge + overlap, x: l)
        let m = max(0, 1 - s - h)
        return (s, m, h)
    }

    /// The RGB offset a wheel contributes at full weight: hue/sat polar → small RGB push,
    /// plus a luminance lift. Scale matches a subtle, film-like range (max ±0.3 per channel).
    public static func wheelOffset(_ wheel: ColorGradingSettings.Wheel)
        -> (r: Double, g: Double, b: Double, lum: Double) {
        let strength = wheel.saturation / 100 * 0.3
        let rad = wheel.hue * .pi / 180
        // Hue angle → RGB direction on the colour wheel (0° = red, 120° = green, 240° = blue).
        let r = cos(rad)
        let g = cos(rad - 2 * .pi / 3)
        let b = cos(rad - 4 * .pi / 3)
        return (r * strength, g * strength, b * strength, wheel.luminance / 100 * 0.25)
    }

    /// Apply the full grading stack to one linear RGB pixel.
    public static func apply(_ grading: ColorGradingSettings, r: Double, g: Double, b: Double)
        -> (r: Double, g: Double, b: Double) {
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let w = rangeWeights(luminance: lum, blending: grading.blending, balance: grading.balance)

        var (or_, og, ob) = (r, g, b)
        for (wheel, weight) in [
            (grading.shadows, w.shadows),
            (grading.midtones, w.midtones),
            (grading.highlights, w.highlights),
            (grading.global, 1.0)
        ] {
            guard !wheel.isDefault, weight > 0 else { continue }
            let off = wheelOffset(wheel)
            // Colour push is strongest in midtone luminance of the *pixel* so blacks/whites
            // stay clean; luminance lift applies directly, range-weighted.
            let tonalGate = 1 - pow(abs(2 * lum - 1), 2)
            or_ += off.r * weight * tonalGate + off.lum * weight * 0.5
            og += off.g * weight * tonalGate + off.lum * weight * 0.5
            ob += off.b * weight * tonalGate + off.lum * weight * 0.5
        }
        return (clamp01(or_), clamp01(og), clamp01(ob))
    }

    static func smoothstep(edge0: Double, edge1: Double, x: Double) -> Double {
        guard edge1 > edge0 else { return x >= edge1 ? 1 : 0 }
        let t = clamp01((x - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }

    @inline(__always)
    static func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
}
