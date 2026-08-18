import XCTest
@testable import PhotonCore

final class PresetXMPTests: XCTestCase {

    private func samplePreset() -> DevelopPreset {
        var s = DevelopSettings()
        s.basic.exposure = 0.85
        s.basic.contrast = 22
        s.basic.clarity = 15
        s.basic.vibrance = 10
        s.toneCurve.highlights = -30
        s.toneCurve.pointCurve = CurvePoints(points: [
            .init(x: 0, y: 0.05), .init(x: 0.5, y: 0.55), .init(x: 1, y: 0.98)
        ])
        s.hsl.saturation[.orange] = -20
        s.hsl.luminance[.blue] = 35
        s.effects.grainAmount = 25
        s.masks = [PhotonMask(name: "Sky", components: [
            MaskComponent(kind: .sky)
        ], adjustments: LocalAdjustments(exposure: -0.5))]
        return DevelopPreset(name: "Test <Preset> & Co", group: "My \"Group\"", settings: s)
    }

    func testRoundTripIsLossless() throws {
        let preset = samplePreset()
        let xml = try PresetXMP.serialize(preset)
        let parsed = try PresetXMP.parse(xml)
        XCTAssertEqual(parsed, preset, "Photon → Photon round trip must be lossless")
    }

    func testRoundTripPreservesMasks() throws {
        let preset = samplePreset()
        let parsed = try PresetXMP.parse(try PresetXMP.serialize(preset))
        XCTAssertEqual(parsed.settings.masks.count, 1)
        XCTAssertEqual(parsed.settings.masks[0].name, "Sky")
        XCTAssertEqual(parsed.settings.masks[0].components[0].kind, .sky)
        XCTAssertEqual(parsed.settings.masks[0].adjustments.exposure, -0.5)
    }

    func testSerializedXMPContainsCRSTags() throws {
        let xml = try PresetXMP.serialize(samplePreset())
        XCTAssertTrue(xml.contains("crs:Exposure2012=\"+0.85\""))
        XCTAssertTrue(xml.contains("crs:Contrast2012=\"22\""))
        XCTAssertTrue(xml.contains("crs:SaturationAdjustmentOrange=\"-20\""))
        XCTAssertTrue(xml.contains("crs:ParametricHighlights=\"-30\""))
        XCTAssertTrue(xml.contains("crs:GrainAmount=\"25\""))
    }

    func testXMLSpecialCharactersAreEscaped() throws {
        let xml = try PresetXMP.serialize(samplePreset())
        XCTAssertTrue(xml.contains("crs:Name=\"Test &lt;Preset&gt; &amp; Co\""))
        XCTAssertFalse(xml.contains("crs:Name=\"Test <Preset>"))
    }

    func testParsesForeignLightroomStyleXMP() throws {
        // A minimal preset as Lightroom-ish tools emit it — no Photon payload.
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 5.6">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
           xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
           crs:Name="Punchy Film"
           crs:Exposure2012="+0.40"
           crs:Contrast2012="+18"
           crs:Highlights2012="-45"
           crs:Shadows2012="+30"
           crs:Vibrance="+12"
           crs:HueAdjustmentGreen="-15"
           crs:LuminanceAdjustmentBlue="+25"
           crs:ConvertToGrayscale="False"
           crs:GrainAmount="40"/>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let preset = try PresetXMP.parse(xml)
        XCTAssertEqual(preset.name, "Punchy Film")
        XCTAssertEqual(preset.settings.basic.exposure, 0.4, accuracy: 1e-9)
        XCTAssertEqual(preset.settings.basic.contrast, 18)
        XCTAssertEqual(preset.settings.basic.highlights, -45)
        XCTAssertEqual(preset.settings.basic.shadows, 30)
        XCTAssertEqual(preset.settings.hsl.hue[.green], -15)
        XCTAssertEqual(preset.settings.hsl.luminance[.blue], 25)
        XCTAssertEqual(preset.settings.effects.grainAmount, 40)
        XCTAssertNil(preset.settings.blackAndWhite)
    }

    func testParsesGrayscaleConversion() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
           crs:Name="Mono" crs:ConvertToGrayscale="True"
           crs:GrayMixerRed="+20" crs:GrayMixerBlue="-40"/>
        </x:xmpmeta>
        """
        let preset = try PresetXMP.parse(xml)
        XCTAssertNotNil(preset.settings.blackAndWhite)
        XCTAssertEqual(preset.settings.blackAndWhite?.mix[.red], 20)
        XCTAssertEqual(preset.settings.blackAndWhite?.mix[.blue], -40)
    }

    func testRejectsNonXMPInput() {
        XCTAssertThrowsError(try PresetXMP.parse("{\"not\": \"xmp\"}"))
    }

    func testApplyRespectsSubset() {
        var source = DevelopSettings()
        source.basic.exposure = 1
        source.effects.grainAmount = 50
        let preset = DevelopPreset(name: "BasicOnly", subset: [.basic], settings: source)

        var base = DevelopSettings()
        base.basic.contrast = 5
        let applied = preset.apply(to: base)
        XCTAssertEqual(applied.basic.exposure, 1)
        XCTAssertEqual(applied.effects.grainAmount, 0, "effects were outside the subset")
    }
}
