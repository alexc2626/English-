import XCTest
@testable import PhotonCore

final class ColorGradingTests: XCTestCase {

    func testRangeWeightsPartitionUnity() {
        for i in 0...100 {
            let l = Double(i) / 100
            let w = ColorGradingMath.rangeWeights(luminance: l, blending: 50, balance: 0)
            XCTAssertEqual(w.shadows + w.midtones + w.highlights, 1, accuracy: 1e-9)
            XCTAssertGreaterThanOrEqual(w.midtones, 0)
        }
    }

    func testShadowsDominateDarkPixels() {
        let w = ColorGradingMath.rangeWeights(luminance: 0.05, blending: 50, balance: 0)
        XCTAssertGreaterThan(w.shadows, 0.9)
        XCTAssertLessThan(w.highlights, 0.01)
    }

    func testHighlightsDominateBrightPixels() {
        let w = ColorGradingMath.rangeWeights(luminance: 0.95, blending: 50, balance: 0)
        XCTAssertGreaterThan(w.highlights, 0.9)
        XCTAssertLessThan(w.shadows, 0.01)
    }

    func testBalanceShiftsCrossover() {
        // Positive balance pushes the shadow range upward: a midtone pixel reads more
        // "shadow" than before.
        let neutral = ColorGradingMath.rangeWeights(luminance: 0.4, blending: 50, balance: 0)
        let shifted = ColorGradingMath.rangeWeights(luminance: 0.4, blending: 50, balance: 100)
        XCTAssertGreaterThan(shifted.shadows, neutral.shadows)
    }

    func testBlendingWidensOverlap() {
        // With wider blending, a dark-midtone pixel keeps more shadow membership.
        let tight = ColorGradingMath.rangeWeights(luminance: 0.45, blending: 0, balance: 0)
        let wide = ColorGradingMath.rangeWeights(luminance: 0.45, blending: 100, balance: 0)
        XCTAssertGreaterThan(wide.shadows, tight.shadows)
    }

    func testDefaultGradingIsIdentity() {
        let g = ColorGradingSettings()
        let out = ColorGradingMath.apply(g, r: 0.3, g: 0.6, b: 0.2)
        XCTAssertEqual(out.r, 0.3, accuracy: 1e-9)
        XCTAssertEqual(out.g, 0.6, accuracy: 1e-9)
        XCTAssertEqual(out.b, 0.2, accuracy: 1e-9)
    }

    func testWarmShadowWheelWarmsDarkPixelsOnly() {
        var g = ColorGradingSettings()
        g.shadows = .init(hue: 30, saturation: 60, luminance: 0)  // warm orange push
        let dark = ColorGradingMath.apply(g, r: 0.15, g: 0.15, b: 0.15)
        XCTAssertGreaterThan(dark.r, dark.b, "warm shadows: red above blue in the darks")
        let bright = ColorGradingMath.apply(g, r: 0.9, g: 0.9, b: 0.9)
        XCTAssertEqual(bright.r, bright.b, accuracy: 1e-3,
                       "highlight pixels barely touched by the shadows wheel")
    }

    func testWheelLuminanceLifts() {
        var g = ColorGradingSettings()
        g.midtones = .init(hue: 0, saturation: 0, luminance: 100)
        let mid = ColorGradingMath.apply(g, r: 0.5, g: 0.5, b: 0.5)
        XCTAssertGreaterThan(mid.r, 0.5)
        XCTAssertEqual(mid.r, mid.g, accuracy: 1e-9, "pure luminance lift stays neutral")
    }
}
