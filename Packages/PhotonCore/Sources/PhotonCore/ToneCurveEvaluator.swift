import Foundation

/// Evaluates Photon's tone curve model into lookup tables the GPU pipeline samples.
///
/// The full curve is the composition of:
///  1. the parametric region curve (Highlights / Lights / Darks / Shadows sliders), and
///  2. the composite point curve,
/// with the per-channel R/G/B point curves applied on top of the composite result.
///
/// All math operates on normalised luminance/channel values in [0, 1]. The same evaluation is
/// mirrored in `PhotonKernels.ci.metal` by sampling the LUTs this type produces.
public enum ToneCurveEvaluator {

    public static let lutSize = 1024

    // MARK: Parametric region curve

    /// Smooth membership weights of the four Lightroom tone regions at luminance `x`.
    /// The weights are raised-cosine lobes centred on shadows→highlights and always sum to 1,
    /// so region slider effects blend seamlessly and the identity is exactly preserved when
    /// all sliders are 0.
    public static func regionWeights(_ x: Double) -> (shadows: Double, darks: Double, lights: Double, highlights: Double) {
        // Region centres/edges follow Lightroom's default 25/50/75 split points.
        func lobe(_ x: Double, center: Double, halfWidth: Double) -> Double {
            let t = (x - center) / halfWidth
            guard abs(t) < 1 else { return 0 }
            return 0.5 * (1 + cos(.pi * t))
        }
        var s = lobe(x, center: 0.0, halfWidth: 0.35)
        var d = lobe(x, center: 0.30, halfWidth: 0.35)
        var l = lobe(x, center: 0.65, halfWidth: 0.35)
        var h = lobe(x, center: 1.0, halfWidth: 0.35)
        let sum = s + d + l + h
        if sum > 0 { s /= sum; d /= sum; l /= sum; h /= sum }
        return (s, d, l, h)
    }

    /// Apply the four region sliders (each −100…+100) to a luminance value.
    ///
    /// The parametric curve is built as a monotone cubic through six control points: fixed
    /// black/white endpoints plus one point per region (centred at 12.5% / 37.5% / 62.5% /
    /// 87.5%, matching Lightroom's default 25/50/75 splits). A full slider shifts its control
    /// point by ±0.2; control-point ys are then clamped to stay strictly increasing, so the
    /// resulting curve is monotone *by construction* even with extreme opposing sliders.
    public static func applyParametric(_ x: Double, settings: ToneCurveSettings) -> Double {
        let curve = parametricCurve(settings)
        return evaluatePointCurve(curve, at: x)
    }

    /// The parametric region sliders expressed as a point curve.
    public static func parametricCurve(_ settings: ToneCurveSettings) -> CurvePoints {
        let scale = 0.2
        let raw: [(Double, Double)] = [
            (0.0, 0.0),
            (0.125, 0.125 + settings.shadowsRegion / 100 * scale),
            (0.375, 0.375 + settings.darks / 100 * scale),
            (0.625, 0.625 + settings.lights / 100 * scale),
            (0.875, 0.875 + settings.highlights / 100 * scale),
            (1.0, 1.0)
        ]
        // Forward clamp: each y at least a hair above its predecessor, capped at 1.
        var points: [CurvePoints.Point] = []
        var floor = 0.0
        for (i, (x, y)) in raw.enumerated() {
            var yy = min(max(y, 0), 1)
            if i > 0 { yy = max(yy, floor + 1e-4) }
            yy = min(yy, 1)
            points.append(.init(x: x, y: yy))
            floor = yy
        }
        return CurvePoints(points: points)
    }

    // MARK: Monotone cubic point curve (Fritsch–Carlson)

    /// Interpolate a point curve at `x` using monotone piecewise-cubic Hermite interpolation,
    /// which never overshoots between control points (matching Lightroom's point-curve feel).
    public static func evaluatePointCurve(_ curve: CurvePoints, at x: Double) -> Double {
        let pts = curve.points
        guard pts.count >= 2 else { return clamp01(x) }
        if x <= pts.first!.x { return clamp01(pts.first!.y) }
        if x >= pts.last!.x { return clamp01(pts.last!.y) }

        let n = pts.count
        var h = [Double](repeating: 0, count: n - 1)
        var slope = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            h[i] = pts[i + 1].x - pts[i].x
            slope[i] = h[i] > 0 ? (pts[i + 1].y - pts[i].y) / h[i] : 0
        }

        // Fritsch–Carlson tangents.
        var m = [Double](repeating: 0, count: n)
        m[0] = slope[0]
        m[n - 1] = slope[n - 2]
        for i in 1..<(n - 1) {
            if slope[i - 1] * slope[i] <= 0 {
                m[i] = 0
            } else {
                let wSum = h[i - 1] + h[i]
                m[i] = 3 * wSum / ((wSum + h[i]) / slope[i - 1] + (wSum + h[i - 1]) / slope[i])
            }
        }
        // Enforce monotonicity limits.
        for i in 0..<(n - 1) where slope[i] == 0 {
            m[i] = 0
            m[i + 1] = 0
        }

        // Locate segment.
        var seg = 0
        for i in 0..<(n - 1) where x >= pts[i].x { seg = i }

        let t = (x - pts[seg].x) / h[seg]
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        let y = h00 * pts[seg].y + h10 * h[seg] * m[seg]
              + h01 * pts[seg + 1].y + h11 * h[seg] * m[seg + 1]
        return clamp01(y)
    }

    // MARK: LUT generation

    /// Full composite luminance curve: parametric regions then the composite point curve.
    public static func compositeLUT(settings: ToneCurveSettings, size: Int = lutSize) -> [Float] {
        let parametric = parametricCurve(settings)
        return (0..<size).map { i in
            let x = Double(i) / Double(size - 1)
            let y = evaluatePointCurve(parametric, at: x)
            return Float(evaluatePointCurve(settings.pointCurve, at: y))
        }
    }

    /// Per-channel LUTs (identity when the channel curve is untouched). Each channel samples
    /// the composite result first, matching Lightroom's stacking order.
    public static func channelLUTs(settings: ToneCurveSettings, size: Int = lutSize)
        -> (red: [Float], green: [Float], blue: [Float]) {
        func lut(_ curve: CurvePoints) -> [Float] {
            (0..<size).map { i in
                let x = Double(i) / Double(size - 1)
                return Float(evaluatePointCurve(curve, at: x))
            }
        }
        return (lut(settings.redCurve), lut(settings.greenCurve), lut(settings.blueCurve))
    }

    @inline(__always)
    static func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
}
