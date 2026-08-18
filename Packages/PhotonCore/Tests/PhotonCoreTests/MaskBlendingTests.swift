import XCTest
@testable import PhotonCore

final class MaskBlendingTests: XCTestCase {

    typealias C = MaskBlending.Component

    // MARK: Combine semantics

    func testEmptyMaskIsZero() {
        XCTAssertEqual(MaskBlending.combine([]), 0)
    }

    func testSingleAdd() {
        XCTAssertEqual(MaskBlending.combine([C(mode: .add, coverage: 0.7)]), 0.7,
                       accuracy: 1e-9)
    }

    func testAddIsScreenUnion() {
        // 0.5 ∪ 0.5 = 0.75 (screen), not 1.0 and not 0.5.
        let m = MaskBlending.combine([
            C(mode: .add, coverage: 0.5), C(mode: .add, coverage: 0.5)
        ])
        XCTAssertEqual(m, 0.75, accuracy: 1e-9)
    }

    func testAddIsOrderIndependent() {
        let a = MaskBlending.combine([C(mode: .add, coverage: 0.3), C(mode: .add, coverage: 0.9)])
        let b = MaskBlending.combine([C(mode: .add, coverage: 0.9), C(mode: .add, coverage: 0.3)])
        XCTAssertEqual(a, b, accuracy: 1e-12)
    }

    func testSubtractRemovesCoverage() {
        let m = MaskBlending.combine([
            C(mode: .add, coverage: 1.0), C(mode: .subtract, coverage: 0.4)
        ])
        XCTAssertEqual(m, 0.6, accuracy: 1e-9)
    }

    func testFullSubtractZeroes() {
        let m = MaskBlending.combine([
            C(mode: .add, coverage: 0.8), C(mode: .subtract, coverage: 1.0)
        ])
        XCTAssertEqual(m, 0, accuracy: 1e-9)
    }

    func testIntersectMultiplies() {
        let m = MaskBlending.combine([
            C(mode: .add, coverage: 0.8), C(mode: .intersect, coverage: 0.5)
        ])
        XCTAssertEqual(m, 0.4, accuracy: 1e-9)
    }

    func testIntersectAsFirstComponentSelectsItself() {
        // Lightroom: an intersect with an empty mask acts as a plain selection.
        let m = MaskBlending.combine([C(mode: .intersect, coverage: 0.6)])
        XCTAssertEqual(m, 0.6, accuracy: 1e-9)
    }

    func testComponentInvert() {
        let m = MaskBlending.combine([C(mode: .add, coverage: 0.3, inverted: true)])
        XCTAssertEqual(m, 0.7, accuracy: 1e-9)
    }

    func testMaskLevelInvert() {
        let m = MaskBlending.combine([C(mode: .add, coverage: 0.3)], maskInverted: true)
        XCTAssertEqual(m, 0.7, accuracy: 1e-9)
    }

    func testResultAlwaysInUnitInterval() {
        let combos: [[C]] = [
            [C(mode: .add, coverage: 1.5)],                        // over-range input
            [C(mode: .subtract, coverage: 0.5)],                   // subtract from empty
            [C(mode: .add, coverage: 1), C(mode: .add, coverage: 1)],
            [C(mode: .intersect, coverage: -0.2)]
        ]
        for combo in combos {
            let m = MaskBlending.combine(combo)
            XCTAssertGreaterThanOrEqual(m, 0)
            XCTAssertLessThanOrEqual(m, 1)
        }
    }

    // MARK: Range coverage (luminance / depth masks)

    func testRangeCoverageInsideIsOne() {
        XCTAssertEqual(MaskBlending.rangeCoverage(value: 0.5, low: 0.3, high: 0.7,
                                                  smoothness: 0.1), 1)
    }

    func testRangeCoverageOutsideShouldersIsZero() {
        XCTAssertEqual(MaskBlending.rangeCoverage(value: 0.95, low: 0.3, high: 0.7,
                                                  smoothness: 0.1), 0)
    }

    func testRangeCoverageShouldersAreSmooth() {
        // Halfway down the shoulder = 0.5.
        let mid = MaskBlending.rangeCoverage(value: 0.75, low: 0.3, high: 0.7, smoothness: 0.1)
        XCTAssertEqual(mid, 0.5, accuracy: 1e-9)
        // Shoulder is monotone.
        var prev = 1.0
        for i in 0...20 {
            let v = 0.7 + Double(i) / 20 * 0.1
            let c = MaskBlending.rangeCoverage(value: v, low: 0.3, high: 0.7, smoothness: 0.1)
            XCTAssertLessThanOrEqual(c, prev + 1e-12)
            prev = c
        }
    }

    // MARK: Gradient geometry

    func testLinearGradientFullBeforeStartZeroAfterEnd() {
        let g = LinearGradientMask(startX: 0.5, startY: 0.4, endX: 0.5, endY: 0.6)
        XCTAssertEqual(MaskBlending.linearGradientCoverage(g, x: 0.5, y: 0.1), 1,
                       accuracy: 1e-9, "before the start line")
        XCTAssertEqual(MaskBlending.linearGradientCoverage(g, x: 0.5, y: 0.9), 0,
                       accuracy: 1e-9, "past the end line")
        XCTAssertEqual(MaskBlending.linearGradientCoverage(g, x: 0.5, y: 0.5), 0.5,
                       accuracy: 1e-9, "midpoint")
    }

    func testLinearGradientIsPerpendicularInvariant() {
        let g = LinearGradientMask(startX: 0.3, startY: 0.3, endX: 0.7, endY: 0.7)
        let a = MaskBlending.linearGradientCoverage(g, x: 0.5, y: 0.5)
        // Any point on the same perpendicular line has equal coverage.
        let b = MaskBlending.linearGradientCoverage(g, x: 0.6, y: 0.4)
        XCTAssertEqual(a, b, accuracy: 1e-9)
    }

    func testRadialGradientCenterIsFullOutsideIsZero() {
        let g = RadialGradientMask(centerX: 0.5, centerY: 0.5, radiusX: 0.2, radiusY: 0.1,
                                   rotation: 0, feather: 50)
        XCTAssertEqual(MaskBlending.radialGradientCoverage(g, x: 0.5, y: 0.5), 1,
                       accuracy: 1e-9)
        XCTAssertEqual(MaskBlending.radialGradientCoverage(g, x: 0.95, y: 0.5), 0,
                       accuracy: 1e-9)
    }

    func testRadialGradientRespectsRotation() {
        // Narrow ellipse rotated 90°: a point along x at 0.15 falls outside pre-rotation
        // radiusX but inside after rotation swaps the axes… and vice versa for y.
        let unrotated = RadialGradientMask(centerX: 0.5, centerY: 0.5,
                                           radiusX: 0.3, radiusY: 0.05, rotation: 0, feather: 10)
        let rotated = RadialGradientMask(centerX: 0.5, centerY: 0.5,
                                         radiusX: 0.3, radiusY: 0.05, rotation: 90, feather: 10)
        let alongX = MaskBlending.radialGradientCoverage(unrotated, x: 0.7, y: 0.5)
        let alongXRotated = MaskBlending.radialGradientCoverage(rotated, x: 0.7, y: 0.5)
        XCTAssertGreaterThan(alongX, 0)
        XCTAssertEqual(alongXRotated, 0, accuracy: 1e-9)
    }

    // MARK: Colour range

    func testColorRangeMatchesSampledColor() {
        let mask = ColorRangeMask(samples: [.init(r: 0.9, g: 0.1, b: 0.1)], refine: 50)
        let exact = MaskBlending.colorRangeCoverage(mask, r: 0.9, g: 0.1, b: 0.1)
        XCTAssertEqual(exact, 1, accuracy: 1e-9)
        let far = MaskBlending.colorRangeCoverage(mask, r: 0.1, g: 0.2, b: 0.9)
        XCTAssertEqual(far, 0, accuracy: 1e-6)
    }

    func testColorRangeRefineWidensSelection() {
        let target = (r: 0.85, g: 0.25, b: 0.15)
        let tight = ColorRangeMask(samples: [.init(r: 0.9, g: 0.1, b: 0.1)], refine: 0)
        let loose = ColorRangeMask(samples: [.init(r: 0.9, g: 0.1, b: 0.1)], refine: 100)
        let cTight = MaskBlending.colorRangeCoverage(tight, r: target.r, g: target.g, b: target.b)
        let cLoose = MaskBlending.colorRangeCoverage(loose, r: target.r, g: target.g, b: target.b)
        XCTAssertGreaterThan(cLoose, cTight)
    }
}
