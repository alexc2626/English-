import XCTest
@testable import PhotonCore

final class HSLRemapTests: XCTestCase {

    // MARK: Band weights

    func testBandWeightIsOneAtOwnCenter() {
        for (band, center) in HSLRemap.bandCenters {
            XCTAssertEqual(HSLRemap.bandWeight(hue: center, band: band), 1, accuracy: 1e-9,
                           "\(band) at its own centre")
        }
    }

    func testBandWeightIsZeroAtNeighborCenters() {
        XCTAssertEqual(HSLRemap.bandWeight(hue: 30, band: .red), 0, accuracy: 1e-9)
        XCTAssertEqual(HSLRemap.bandWeight(hue: 320, band: .red), 0, accuracy: 1e-9)
        XCTAssertEqual(HSLRemap.bandWeight(hue: 60, band: .green), 0, accuracy: 1e-9)
    }

    func testBandWeightsPartitionUnity() {
        for deg in stride(from: 0.0, through: 359.0, by: 7.3) {
            let total = ColorBand.allCases
                .map { HSLRemap.bandWeight(hue: deg, band: $0) }
                .reduce(0, +)
            XCTAssertEqual(total, 1, accuracy: 1e-9, "weights at hue \(deg)°")
        }
    }

    func testBandWeightWrapsAroundRed() {
        // 350° sits between magenta (320°) and red (0°/360°).
        let red = HSLRemap.bandWeight(hue: 350, band: .red)
        let magenta = HSLRemap.bandWeight(hue: 350, band: .magenta)
        XCTAssertGreaterThan(red, 0)
        XCTAssertGreaterThan(magenta, 0)
        XCTAssertEqual(red + magenta, 1, accuracy: 1e-9)
        XCTAssertGreaterThan(red, magenta, "350° is closer to red than magenta")
    }

    // MARK: Remap behaviour

    func testDefaultAdjustmentsAreIdentity() {
        let adj = HSLAdjustments()
        let (h, s, l) = HSLRemap.apply(adj, h: 200, s: 0.5, l: 0.4)
        XCTAssertEqual(h, 200, accuracy: 1e-9)
        XCTAssertEqual(s, 0.5, accuracy: 1e-9)
        XCTAssertEqual(l, 0.4, accuracy: 1e-9)
    }

    func testHueSliderShiftsOnlyItsBand() {
        var adj = HSLAdjustments()
        adj.hue[.blue] = 100   // full slider = +30° at band centre
        let blue = HSLRemap.apply(adj, h: 240, s: 1.0, l: 0.5)
        XCTAssertEqual(blue.h, 270, accuracy: 1e-6)
        // Red (0°) is outside blue's lobe entirely.
        let red = HSLRemap.apply(adj, h: 0, s: 1.0, l: 0.5)
        XCTAssertEqual(red.h, 0, accuracy: 1e-9)
    }

    func testSaturationSliderScalesSaturation() {
        var adj = HSLAdjustments()
        adj.saturation[.green] = -100
        let out = HSLRemap.apply(adj, h: 120, s: 0.8, l: 0.5)
        XCTAssertEqual(out.s, 0, accuracy: 1e-9, "full desaturation of the green band")
        adj.saturation[.green] = 50
        let boosted = HSLRemap.apply(adj, h: 120, s: 0.4, l: 0.5)
        XCTAssertEqual(boosted.s, 0.6, accuracy: 1e-9)
    }

    func testLuminanceSliderMovesTowardBoundsWithoutClipping() {
        var adj = HSLAdjustments()
        adj.luminance[.red] = 100
        let up = HSLRemap.apply(adj, h: 0, s: 1, l: 0.5)
        XCTAssertGreaterThan(up.l, 0.5)
        XCTAssertLessThanOrEqual(up.l, 1)
        adj.luminance[.red] = -100
        let down = HSLRemap.apply(adj, h: 0, s: 1, l: 0.5)
        XCTAssertLessThan(down.l, 0.5)
        XCTAssertGreaterThanOrEqual(down.l, 0)
    }

    func testNeutralPixelsAreProtectedFromHueShift() {
        var adj = HSLAdjustments()
        adj.hue[.red] = 100
        let grey = HSLRemap.apply(adj, h: 0, s: 0.0, l: 0.5)
        XCTAssertEqual(grey.h, 0, accuracy: 1e-9, "zero-saturation pixels must not shift")
    }

    // MARK: RGB <-> HSL round trip

    func testRGBHSLRoundTrip() {
        let cases: [(Double, Double, Double)] = [
            (1, 0, 0), (0, 1, 0), (0, 0, 1), (0.5, 0.5, 0.5),
            (0.8, 0.4, 0.1), (0.05, 0.9, 0.6), (0, 0, 0), (1, 1, 1)
        ]
        for (r, g, b) in cases {
            let hsl = HSLRemap.rgbToHSL(r: r, g: g, b: b)
            let rgb = HSLRemap.hslToRGB(h: hsl.h, s: hsl.s, l: hsl.l)
            XCTAssertEqual(rgb.r, r, accuracy: 1e-9)
            XCTAssertEqual(rgb.g, g, accuracy: 1e-9)
            XCTAssertEqual(rgb.b, b, accuracy: 1e-9)
        }
    }

    // MARK: B&W mix

    func testBWMixDefaultIsLuminance() {
        let mix = BlackAndWhiteMix()
        let grey = HSLRemap.bwMix(mix, h: 30, s: 0.9, l: 0.5, luminance: 0.42)
        XCTAssertEqual(grey, 0.42, accuracy: 1e-9)
    }

    func testBWMixSliderDarkensItsBand() {
        var mix = BlackAndWhiteMix()
        mix.mix[.orange] = -100
        let darkened = HSLRemap.bwMix(mix, h: 30, s: 1, l: 0.5, luminance: 0.6)
        XCTAssertLessThan(darkened, 0.6)
        // Blue pixels unaffected by the orange slider.
        let blue = HSLRemap.bwMix(mix, h: 240, s: 1, l: 0.5, luminance: 0.6)
        XCTAssertEqual(blue, 0.6, accuracy: 1e-9)
    }
}
