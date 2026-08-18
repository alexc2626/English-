import Foundation

/// A develop preset: a named subset of `DevelopSettings`, grouped into user folders.
public struct DevelopPreset: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var group: String
    /// Which panels this preset carries (panels outside the subset are untouched on apply).
    public var subset: SettingsSubset
    public var settings: DevelopSettings
    public var created: Date

    public init(id: UUID = UUID(), name: String, group: String = "User Presets",
                subset: SettingsSubset = .defaultCopy, settings: DevelopSettings,
                created: Date = Date()) {
        self.id = id
        self.name = name
        self.group = group
        self.subset = subset
        self.settings = settings
        self.created = created
    }

    public func apply(to base: DevelopSettings) -> DevelopSettings {
        base.applying(settings, subset: subset)
    }
}

/// Serialises presets to/from a Lightroom-style XMP sidecar (`crs:` namespace, RDF plaintext).
///
/// Photon writes the common Camera Raw slider tags (`crs:Exposure2012`, `crs:Contrast2012`,
/// `crs:HueAdjustmentRed`, …) so simple third-party Lightroom preset packs import with their
/// Basic / Tone Curve region / HSL / Effects values intact. Photon-specific state (masks,
/// spots, curves as point lists) rides alongside under a `photon:Settings` tag holding the
/// full JSON, so Photon→Photon round-trips are lossless.
public enum PresetXMP {

    // MARK: Writing

    public static func serialize(_ preset: DevelopPreset) throws -> String {
        let s = preset.settings
        var tags: [(String, String)] = []

        func tag(_ name: String, _ value: Double, scale: Double = 1) {
            let v = value * scale
            let str = v == v.rounded() ? String(Int(v)) : String(format: "%+.2f", v)
            tags.append((name, str))
        }

        // Basic (Process Version 2012 tag names)
        tag("crs:Exposure2012", s.basic.exposure)
        tag("crs:Contrast2012", s.basic.contrast)
        tag("crs:Highlights2012", s.basic.highlights)
        tag("crs:Shadows2012", s.basic.shadows)
        tag("crs:Whites2012", s.basic.whites)
        tag("crs:Blacks2012", s.basic.blacks)
        tag("crs:Texture", s.basic.texture)
        tag("crs:Clarity2012", s.basic.clarity)
        tag("crs:Dehaze", s.basic.dehaze)
        tag("crs:Vibrance", s.basic.vibrance)
        tag("crs:Saturation", s.basic.saturation)
        if !s.basic.whiteBalanceIsAsShot {
            tag("crs:Temperature", s.basic.temperature)
            tag("crs:Tint", s.basic.tint)
        }

        // Parametric tone curve
        tag("crs:ParametricHighlights", s.toneCurve.highlights)
        tag("crs:ParametricLights", s.toneCurve.lights)
        tag("crs:ParametricDarks", s.toneCurve.darks)
        tag("crs:ParametricShadows", s.toneCurve.shadowsRegion)

        // HSL
        let bandTag: [ColorBand: String] = [
            .red: "Red", .orange: "Orange", .yellow: "Yellow", .green: "Green",
            .aqua: "Aqua", .blue: "Blue", .purple: "Purple", .magenta: "Magenta"
        ]
        for band in ColorBand.allCases {
            tag("crs:HueAdjustment\(bandTag[band]!)", s.hsl.hue[band] ?? 0)
            tag("crs:SaturationAdjustment\(bandTag[band]!)", s.hsl.saturation[band] ?? 0)
            tag("crs:LuminanceAdjustment\(bandTag[band]!)", s.hsl.luminance[band] ?? 0)
        }
        if let bw = s.blackAndWhite {
            tags.append(("crs:ConvertToGrayscale", "True"))
            for band in ColorBand.allCases {
                tag("crs:GrayMixer\(bandTag[band]!)", bw.mix[band] ?? 0)
            }
        }

        // Detail
        tag("crs:Sharpness", s.detail.sharpeningAmount)
        tag("crs:SharpenRadius", s.detail.sharpeningRadius)
        tag("crs:SharpenDetail", s.detail.sharpeningDetail)
        tag("crs:SharpenEdgeMasking", s.detail.sharpeningMasking)
        tag("crs:LuminanceSmoothing", s.detail.luminanceNR)
        tag("crs:ColorNoiseReduction", s.detail.colorNR)

        // Effects
        tag("crs:PostCropVignetteAmount", s.effects.vignetteAmount)
        tag("crs:PostCropVignetteMidpoint", s.effects.vignetteMidpoint)
        tag("crs:PostCropVignetteRoundness", s.effects.vignetteRoundness)
        tag("crs:PostCropVignetteFeather", s.effects.vignetteFeather)
        tag("crs:PostCropVignetteHighlightContrast", s.effects.vignetteHighlights)
        tag("crs:GrainAmount", s.effects.grainAmount)
        tag("crs:GrainSize", s.effects.grainSize)
        tag("crs:GrainFrequency", s.effects.grainRoughness)

        // Full-fidelity Photon payload
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(preset), encoding: .utf8) ?? "{}"

        let crsLines = tags
            .map { "   \($0.0)=\"\(xmlEscape($0.1))\"" }
            .joined(separator: "\n")

        return """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Photon">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
           xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
           xmlns:photon="https://photon.local/ns/1.0/"
           crs:PresetType="Normal"
           crs:Name="\(xmlEscape(preset.name))"
           crs:Group="\(xmlEscape(preset.group))"
           crs:ProcessVersion="11.0"
        \(crsLines)>
           <photon:Settings><![CDATA[\(json)]]></photon:Settings>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
    }

    // MARK: Reading

    public enum ParseError: Error { case notXMP }

    /// Parse an XMP preset. If a `photon:Settings` payload is present it wins (lossless);
    /// otherwise the recognised `crs:` tags are mapped onto a fresh `DevelopSettings`.
    public static func parse(_ xml: String) throws -> DevelopPreset {
        guard xml.contains("adobe:ns:meta") || xml.contains("camera-raw-settings") else {
            throw ParseError.notXMP
        }

        // Lossless Photon payload?
        if let start = xml.range(of: "<photon:Settings><![CDATA["),
           let end = xml.range(of: "]]></photon:Settings>"),
           start.upperBound <= end.lowerBound {
            let json = String(xml[start.upperBound..<end.lowerBound])
            if let data = json.data(using: .utf8),
               let preset = try? JSONDecoder().decode(DevelopPreset.self, from: data) {
                return preset
            }
        }

        // Fall back to crs tag mapping.
        let attrs = crsAttributes(in: xml)
        func d(_ key: String) -> Double { Double(attrs[key] ?? "") ?? 0 }
        func has(_ key: String) -> Bool { attrs[key] != nil }

        var s = DevelopSettings()
        s.basic.exposure = d("crs:Exposure2012")
        s.basic.contrast = d("crs:Contrast2012")
        s.basic.highlights = d("crs:Highlights2012")
        s.basic.shadows = d("crs:Shadows2012")
        s.basic.whites = d("crs:Whites2012")
        s.basic.blacks = d("crs:Blacks2012")
        s.basic.texture = d("crs:Texture")
        s.basic.clarity = d("crs:Clarity2012")
        s.basic.dehaze = d("crs:Dehaze")
        s.basic.vibrance = d("crs:Vibrance")
        s.basic.saturation = d("crs:Saturation")
        if has("crs:Temperature") {
            s.basic.temperature = d("crs:Temperature")
            s.basic.tint = d("crs:Tint")
            s.basic.whiteBalanceIsAsShot = false
        }

        s.toneCurve.highlights = d("crs:ParametricHighlights")
        s.toneCurve.lights = d("crs:ParametricLights")
        s.toneCurve.darks = d("crs:ParametricDarks")
        s.toneCurve.shadowsRegion = d("crs:ParametricShadows")

        let bandTag: [ColorBand: String] = [
            .red: "Red", .orange: "Orange", .yellow: "Yellow", .green: "Green",
            .aqua: "Aqua", .blue: "Blue", .purple: "Purple", .magenta: "Magenta"
        ]
        for band in ColorBand.allCases {
            let t = bandTag[band]!
            if has("crs:HueAdjustment\(t)") { s.hsl.hue[band] = d("crs:HueAdjustment\(t)") }
            if has("crs:SaturationAdjustment\(t)") {
                s.hsl.saturation[band] = d("crs:SaturationAdjustment\(t)")
            }
            if has("crs:LuminanceAdjustment\(t)") {
                s.hsl.luminance[band] = d("crs:LuminanceAdjustment\(t)")
            }
        }
        if attrs["crs:ConvertToGrayscale"] == "True" {
            var mix = BlackAndWhiteMix()
            for band in ColorBand.allCases where has("crs:GrayMixer\(bandTag[band]!)") {
                mix.mix[band] = d("crs:GrayMixer\(bandTag[band]!)")
            }
            s.blackAndWhite = mix
        }

        s.detail.sharpeningAmount = d("crs:Sharpness")
        if has("crs:SharpenRadius") { s.detail.sharpeningRadius = d("crs:SharpenRadius") }
        if has("crs:SharpenDetail") { s.detail.sharpeningDetail = d("crs:SharpenDetail") }
        s.detail.sharpeningMasking = d("crs:SharpenEdgeMasking")
        s.detail.luminanceNR = d("crs:LuminanceSmoothing")
        if has("crs:ColorNoiseReduction") { s.detail.colorNR = d("crs:ColorNoiseReduction") }

        s.effects.vignetteAmount = d("crs:PostCropVignetteAmount")
        if has("crs:PostCropVignetteMidpoint") {
            s.effects.vignetteMidpoint = d("crs:PostCropVignetteMidpoint")
        }
        s.effects.vignetteRoundness = d("crs:PostCropVignetteRoundness")
        if has("crs:PostCropVignetteFeather") {
            s.effects.vignetteFeather = d("crs:PostCropVignetteFeather")
        }
        s.effects.grainAmount = d("crs:GrainAmount")
        if has("crs:GrainSize") { s.effects.grainSize = d("crs:GrainSize") }
        if has("crs:GrainFrequency") { s.effects.grainRoughness = d("crs:GrainFrequency") }

        let name = attrs["crs:Name"] ?? "Imported Preset"
        let group = attrs["crs:Group"] ?? "Imported"
        return DevelopPreset(name: name, group: group, subset: .defaultCopy, settings: s)
    }

    /// Extract `crs:Key="Value"` attribute pairs without a full XML parser (the attribute
    /// form is what Lightroom emits; element-form values are rare in preset packs).
    static func crsAttributes(in xml: String) -> [String: String] {
        var out: [String: String] = [:]
        var rest = Substring(xml)
        while let keyStart = rest.range(of: "crs:") {
            rest = rest[keyStart.lowerBound...]
            guard let eq = rest.firstIndex(of: "=") else { break }
            let key = String(rest[rest.startIndex..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let afterEq = rest.index(after: eq)
            guard afterEq < rest.endIndex, rest[afterEq] == "\"" else {
                rest = rest[afterEq...]
                continue
            }
            let valueStart = rest.index(after: afterEq)
            guard let closeQuote = rest[valueStart...].firstIndex(of: "\"") else { break }
            // Keys must be simple identifiers — skips matches inside text content.
            if key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == ":" }) {
                out[key] = xmlUnescape(String(rest[valueStart..<closeQuote]))
            }
            rest = rest[rest.index(after: closeQuote)...]
        }
        return out
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func xmlUnescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
