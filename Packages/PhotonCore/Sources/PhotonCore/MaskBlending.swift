import Foundation

/// Combines mask component coverages using Lightroom's Add / Subtract / Intersect semantics.
///
/// Coverages are scalar values in [0, 1]. The combination runs left to right over the
/// component list, exactly as the Masking panel displays it:
///   - add:        union            m' = m + c − m·c   (screen — order-independent, no clip loss)
///   - subtract:   set difference   m' = m · (1 − c)
///   - intersect:  intersection     m' = m · c
///
/// The GPU compositor (`maskCombine` kernel) applies the same per-pixel formulas on component
/// rasters; this scalar version defines the semantics and is unit-tested.
public enum MaskBlending {

    public struct Component: Sendable {
        public var mode: MaskComponent.Mode
        public var coverage: Double
        public var inverted: Bool

        public init(mode: MaskComponent.Mode, coverage: Double, inverted: Bool = false) {
            self.mode = mode
            self.coverage = coverage
            self.inverted = inverted
        }
    }

    /// Combined coverage of an ordered component list at one point.
    /// An empty list yields 0 (no mask). The first component always behaves as `add` on an
    /// empty mask — except `intersect`, which intersects with "everything" (1), matching
    /// Lightroom's behaviour where an intersect-first mask acts as a plain selection.
    public static func combine(_ components: [Component], maskInverted: Bool = false) -> Double {
        var m = 0.0
        var started = false
        for comp in components {
            var c = clamp01(comp.coverage)
            if comp.inverted { c = 1 - c }
            switch comp.mode {
            case .add:
                m = m + c - m * c
                started = true
            case .subtract:
                m *= (1 - c)
            case .intersect:
                if !started {
                    m = c
                    started = true
                } else {
                    m *= c
                }
            }
        }
        return clamp01(maskInverted ? 1 - m : m)
    }

    /// Smooth range selector used by Luminance Range and Depth Range masks: 1 inside
    /// [low, high], raised-cosine shoulders of width `smoothness` outside.
    public static func rangeCoverage(value: Double, low: Double, high: Double,
                                     smoothness: Double) -> Double {
        let s = max(smoothness, 1e-6)
        if value >= low && value <= high { return 1 }
        let d = value < low ? low - value : value - high
        guard d < s else { return 0 }
        return 0.5 * (1 + cos(.pi * d / s))
    }

    /// Coverage of a linear gradient mask at a normalised point: 1 on the near side of the
    /// start line, 0 past the end line, smoothstep between.
    public static func linearGradientCoverage(_ g: LinearGradientMask, x: Double, y: Double) -> Double {
        let dx = g.endX - g.startX
        let dy = g.endY - g.startY
        let lenSq = dx * dx + dy * dy
        guard lenSq > 1e-12 else { return 0 }
        // Project the point onto the gradient axis; t=0 at start, t=1 at end.
        let t = ((x - g.startX) * dx + (y - g.startY) * dy) / lenSq
        return smoothstep(1 - clamp01(t))
    }

    /// Coverage of a radial gradient at a normalised point: 1 at the centre, feathered
    /// falloff across the ellipse boundary.
    public static func radialGradientCoverage(_ g: RadialGradientMask, x: Double, y: Double) -> Double {
        let rad = g.rotation * .pi / 180
        let dx = x - g.centerX
        let dy = y - g.centerY
        let rx = dx * cos(rad) + dy * sin(rad)
        let ry = -dx * sin(rad) + dy * cos(rad)
        guard g.radiusX > 1e-9, g.radiusY > 1e-9 else { return 0 }
        // Normalised elliptical distance: 1.0 on the boundary.
        let d = sqrt(pow(rx / g.radiusX, 2) + pow(ry / g.radiusY, 2))
        let feather = max(g.feather / 100, 0.001)
        // Feather is centred on the boundary: fully inside at 1−feather, zero at 1+feather.
        let t = (d - (1 - feather)) / (2 * feather)
        return smoothstep(1 - clamp01(t))
    }

    /// Colour-range coverage: proximity of a pixel to the nearest sample in a
    /// hue-weighted RGB metric, sharpened by the `refine` slider.
    public static func colorRangeCoverage(_ mask: ColorRangeMask,
                                          r: Double, g: Double, b: Double) -> Double {
        guard !mask.samples.isEmpty else { return 0 }
        var best = Double.greatestFiniteMagnitude
        for s in mask.samples {
            // Weighted RGB distance; hue differences dominate over brightness.
            let (h1, s1, _) = HSLRemap.rgbToHSL(r: r, g: g, b: b)
            let (h2, s2, _) = HSLRemap.rgbToHSL(r: s.r, g: s.g, b: s.b)
            let dh = abs(HSLRemap.hueDistanceSigned(from: h1, to: h2)) / 180
            let ds = abs(s1 - s2)
            let drgb = sqrt(pow(r - s.r, 2) + pow(g - s.g, 2) + pow(b - s.b, 2)) / sqrt(3.0)
            best = min(best, dh * 0.6 + ds * 0.2 + drgb * 0.2)
        }
        // refine 0 → very tight (falloff width 0.05); 100 → loose (width 0.5)
        let width = 0.05 + (mask.refine / 100) * 0.45
        guard best < width else { return 0 }
        return 0.5 * (1 + cos(.pi * best / width))
    }

    @inline(__always)
    static func smoothstep(_ t: Double) -> Double {
        let t = clamp01(t)
        return t * t * (3 - 2 * t)
    }

    @inline(__always)
    static func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
}
