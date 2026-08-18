import Foundation

/// Lightroom-style HSL colour mixing: eight named hue bands (red, orange, yellow, green, aqua,
/// blue, purple, magenta), each with Hue / Saturation / Luminance sliders. A pixel's adjustment
/// is the weight-blended sum of the bands its hue falls between, so band edges never posterise.
///
/// The GPU kernel (`hslRemap` in PhotonKernels.ci.metal) mirrors this math exactly; the CPU
/// implementation exists for unit tests and for CPU-side mask/preview computations.
public enum HSLRemap {

    /// Band centre hues in degrees, matching Lightroom's band layout.
    public static let bandCenters: [ColorBand: Double] = [
        .red: 0, .orange: 30, .yellow: 60, .green: 120,
        .aqua: 180, .blue: 240, .purple: 280, .magenta: 320
    ]

    static let orderedBands: [ColorBand] = [
        .red, .orange, .yellow, .green, .aqua, .blue, .purple, .magenta
    ]

    /// Smooth membership weight of `hue` (degrees) in `band`: 1 at the band centre, falling as
    /// a raised cosine to 0 at the neighbouring band centres. Weights across all bands sum to 1.
    public static func bandWeight(hue: Double, band: ColorBand) -> Double {
        let centers = orderedBands.map { bandCenters[$0]! }
        guard let idx = orderedBands.firstIndex(of: band) else { return 0 }
        let center = centers[idx]
        let prev = centers[(idx + centers.count - 1) % centers.count]
        let next = centers[(idx + 1) % centers.count]

        let h = normalizedHue(hue)
        let d = hueDistanceSigned(from: center, to: h)
        if d == 0 { return 1 }
        if d > 0 {
            // Toward the next band centre (positive direction, wrap-aware).
            let span = hueDistanceSigned(from: center, to: next)
            guard span > 0, d < span else { return 0 }
            return 0.5 * (1 + cos(.pi * d / span))
        } else {
            // Toward the previous band centre (negative direction).
            let span = hueDistanceSigned(from: center, to: prev)
            guard span < 0, d > span else { return 0 }
            return 0.5 * (1 + cos(.pi * d / span))
        }
    }

    /// Apply HSL adjustments to a single HSL pixel (h in degrees, s/l in 0…1).
    /// Slider scales match Lightroom feel: full Hue slider shifts ±30°, Saturation and
    /// Luminance sliders scale multiplicatively.
    public static func apply(_ adjustments: HSLAdjustments, h: Double, s: Double, l: Double)
        -> (h: Double, s: Double, l: Double) {
        guard !adjustments.isDefault else { return (h, s, l) }

        var hueShift = 0.0
        var satScale = 0.0
        var lumScale = 0.0
        for band in orderedBands {
            let w = bandWeight(hue: h, band: band)
            guard w > 0 else { continue }
            hueShift += w * (adjustments.hue[band] ?? 0) / 100 * 30      // ±30°
            satScale += w * (adjustments.saturation[band] ?? 0) / 100    // ±100%
            lumScale += w * (adjustments.luminance[band] ?? 0) / 100     // ±100% toward bound
        }

        // Saturation gates the effect: neutral pixels shouldn't shift hue.
        let gate = min(s * 4, 1)
        let outH = normalizedHue(h + hueShift * gate)
        let outS = clamp01(s * (1 + satScale))
        // Luminance moves toward white/black proportionally, like LR's luminance slider.
        let outL: Double = lumScale >= 0
            ? l + (1 - l) * lumScale * 0.5 * gate
            : l + l * lumScale * 0.5 * gate
        return (outH, outS, clamp01(outL))
    }

    /// B&W mix: grey value from band-weighted channel contributions.
    /// Baseline is Rec.709 luminance; each band slider re-weights pixels of that hue ±.
    public static func bwMix(_ mix: BlackAndWhiteMix, h: Double, s: Double, l: Double,
                             luminance: Double) -> Double {
        var delta = 0.0
        for band in orderedBands {
            let w = bandWeight(hue: h, band: band)
            guard w > 0 else { continue }
            delta += w * (mix.mix[band] ?? 0) / 100
        }
        // Saturated pixels respond fully; neutrals are untouched.
        return clamp01(luminance + delta * 0.5 * min(s * 2, 1))
    }

    // MARK: RGB <-> HSL helpers

    public static func rgbToHSL(r: Double, g: Double, b: Double) -> (h: Double, s: Double, l: Double) {
        let maxV = max(r, g, b), minV = min(r, g, b)
        let l = (maxV + minV) / 2
        guard maxV != minV else { return (0, 0, l) }
        let d = maxV - minV
        let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        var h: Double
        if maxV == r {
            h = (g - b) / d + (g < b ? 6 : 0)
        } else if maxV == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        return (h * 60, s, l)
    }

    public static func hslToRGB(h: Double, s: Double, l: Double) -> (r: Double, g: Double, b: Double) {
        guard s != 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hueToRGB(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let hh = normalizedHue(h) / 360
        return (hueToRGB(hh + 1 / 3), hueToRGB(hh), hueToRGB(hh - 1 / 3))
    }

    // MARK: small helpers

    static func normalizedHue(_ h: Double) -> Double {
        var h = h.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        return h
    }

    /// Signed shortest angular distance from `from` to `to` in degrees (−180…180].
    static func hueDistanceSigned(from: Double, to: Double) -> Double {
        var d = (to - from).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    @inline(__always)
    static func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
}
