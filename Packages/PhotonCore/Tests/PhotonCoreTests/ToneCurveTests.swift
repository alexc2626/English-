import XCTest
@testable import PhotonCore

final class ToneCurveTests: XCTestCase {

    // MARK: Parametric curve

    func testParametricIdentityWhenAllSlidersZero() {
        let s = ToneCurveSettings()
        for i in 0...100 {
            let x = Double(i) / 100
            XCTAssertEqual(ToneCurveEvaluator.applyParametric(x, settings: s), x,
                           accuracy: 1e-12)
        }
    }

    func testParametricPreservesEndpoints() {
        var s = ToneCurveSettings()
        s.highlights = 100
        s.shadowsRegion = -100
        XCTAssertEqual(ToneCurveEvaluator.applyParametric(0, settings: s), 0, accuracy: 1e-9)
        XCTAssertEqual(ToneCurveEvaluator.applyParametric(1, settings: s), 1, accuracy: 1e-9)
    }

    func testHighlightsSliderRaisesHighlightsMoreThanShadows() {
        var s = ToneCurveSettings()
        s.highlights = 100
        let liftAt08 = ToneCurveEvaluator.applyParametric(0.8, settings: s) - 0.8
        let liftAt02 = ToneCurveEvaluator.applyParametric(0.2, settings: s) - 0.2
        XCTAssertGreaterThan(liftAt08, 0)
        XCTAssertGreaterThan(liftAt08, liftAt02)
    }

    func testShadowsSliderLowersShadows() {
        var s = ToneCurveSettings()
        s.shadowsRegion = -100
        XCTAssertLessThan(ToneCurveEvaluator.applyParametric(0.15, settings: s), 0.15)
    }

    func testRegionWeightsSumToOne() {
        for i in 0...100 {
            let x = Double(i) / 100
            let w = ToneCurveEvaluator.regionWeights(x)
            XCTAssertEqual(w.shadows + w.darks + w.lights + w.highlights, 1, accuracy: 1e-9,
                           "weights must partition unity at x=\(x)")
        }
    }

    func testParametricIsMonotone() {
        var s = ToneCurveSettings()
        s.highlights = 80
        s.lights = -60
        s.darks = 40
        s.shadowsRegion = -90
        var prev = -Double.infinity
        for i in 0...1000 {
            let x = Double(i) / 1000
            let y = ToneCurveEvaluator.applyParametric(x, settings: s)
            XCTAssertGreaterThanOrEqual(y, prev - 1e-9, "curve reversed at x=\(x)")
            prev = y
        }
    }

    // MARK: Point curve (monotone cubic)

    func testPointCurveIdentity() {
        let curve = CurvePoints.identity
        for i in 0...50 {
            let x = Double(i) / 50
            XCTAssertEqual(ToneCurveEvaluator.evaluatePointCurve(curve, at: x), x,
                           accuracy: 1e-9)
        }
    }

    func testPointCurvePassesThroughControlPoints() {
        let curve = CurvePoints(points: [
            .init(x: 0, y: 0), .init(x: 0.25, y: 0.4),
            .init(x: 0.75, y: 0.6), .init(x: 1, y: 1)
        ])
        XCTAssertEqual(ToneCurveEvaluator.evaluatePointCurve(curve, at: 0.25), 0.4,
                       accuracy: 1e-9)
        XCTAssertEqual(ToneCurveEvaluator.evaluatePointCurve(curve, at: 0.75), 0.6,
                       accuracy: 1e-9)
    }

    func testPointCurveMonotoneNoOvershoot() {
        // Classic S-curve; Fritsch–Carlson must not overshoot between points.
        let curve = CurvePoints(points: [
            .init(x: 0, y: 0), .init(x: 0.3, y: 0.1),
            .init(x: 0.7, y: 0.9), .init(x: 1, y: 1)
        ])
        var prev = -Double.infinity
        for i in 0...1000 {
            let x = Double(i) / 1000
            let y = ToneCurveEvaluator.evaluatePointCurve(curve, at: x)
            XCTAssertGreaterThanOrEqual(y, prev - 1e-9)
            XCTAssertGreaterThanOrEqual(y, 0)
            XCTAssertLessThanOrEqual(y, 1)
            prev = y
        }
    }

    func testPointCurveFlatSegmentStaysFlat() {
        let curve = CurvePoints(points: [
            .init(x: 0, y: 0.5), .init(x: 0.5, y: 0.5), .init(x: 1, y: 1)
        ])
        for i in 0...50 {
            let x = Double(i) / 100  // 0…0.5
            XCTAssertEqual(ToneCurveEvaluator.evaluatePointCurve(curve, at: x), 0.5,
                           accuracy: 1e-9, "flat segment must not wiggle at x=\(x)")
        }
    }

    func testPointCurveClampsOutsideDomain() {
        let curve = CurvePoints(points: [.init(x: 0.2, y: 0.3), .init(x: 0.8, y: 0.7)])
        XCTAssertEqual(ToneCurveEvaluator.evaluatePointCurve(curve, at: 0.0), 0.3)
        XCTAssertEqual(ToneCurveEvaluator.evaluatePointCurve(curve, at: 1.0), 0.7)
    }

    // MARK: LUTs

    func testCompositeLUTIdentityByDefault() {
        let lut = ToneCurveEvaluator.compositeLUT(settings: ToneCurveSettings(), size: 256)
        XCTAssertEqual(lut.count, 256)
        for (i, v) in lut.enumerated() {
            XCTAssertEqual(Double(v), Double(i) / 255, accuracy: 1e-6)
        }
    }

    func testChannelLUTsReflectChannelCurves() {
        var s = ToneCurveSettings()
        s.redCurve = CurvePoints(points: [.init(x: 0, y: 0.2), .init(x: 1, y: 1)])
        let luts = ToneCurveEvaluator.channelLUTs(settings: s, size: 256)
        XCTAssertEqual(Double(luts.red[0]), 0.2, accuracy: 1e-6)
        XCTAssertEqual(Double(luts.green[0]), 0.0, accuracy: 1e-6)
        XCTAssertEqual(Double(luts.blue[128]), 128.0 / 255, accuracy: 1e-4)
    }

    func testCurvePointsUpsertKeepsOrderAndSpacing() {
        var curve = CurvePoints.identity
        curve.upsert(.init(x: 0.5, y: 0.6))
        curve.upsert(.init(x: 0.505, y: 0.7))  // replaces the nearby point
        XCTAssertEqual(curve.points.count, 3)
        XCTAssertEqual(curve.points.map(\.x), curve.points.map(\.x).sorted())
        XCTAssertEqual(curve.points[1].y, 0.7)
    }
}
