import Foundation

/// The complete, data-only description of every edit applied to a photo.
///
/// This is the non-negotiable heart of Photon's architecture: a `DevelopSettings` value is the
/// *only* thing an edit ever produces. The render pipeline is a pure function
/// `(source pixels, DevelopSettings) -> image`, re-evaluated from the original RAW on every
/// change. History entries, snapshots, virtual copies, presets, and copy/paste-settings are all
/// just `DevelopSettings` values (or subsets of one) stored in the catalog.
///
/// A default-initialised value means "no edits": rendering with it must reproduce the source
/// image unchanged (modulo RAW default rendering).
public struct DevelopSettings: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var basic: BasicAdjustments
    public var toneCurve: ToneCurveSettings
    public var hsl: HSLAdjustments
    /// Non-nil when the photo is treated as B&W; the mix panel replaces the HSL panel.
    public var blackAndWhite: BlackAndWhiteMix?
    public var colorGrading: ColorGradingSettings
    public var detail: DetailSettings
    public var lens: LensCorrectionSettings
    public var transform: TransformSettings
    public var effects: EffectsSettings
    public var calibration: CalibrationSettings
    public var crop: CropSettings?
    public var spots: [SpotEdit]
    public var masks: [PhotonMask]

    public init(
        version: Int = DevelopSettings.currentVersion,
        basic: BasicAdjustments = .init(),
        toneCurve: ToneCurveSettings = .init(),
        hsl: HSLAdjustments = .init(),
        blackAndWhite: BlackAndWhiteMix? = nil,
        colorGrading: ColorGradingSettings = .init(),
        detail: DetailSettings = .init(),
        lens: LensCorrectionSettings = .init(),
        transform: TransformSettings = .init(),
        effects: EffectsSettings = .init(),
        calibration: CalibrationSettings = .init(),
        crop: CropSettings? = nil,
        spots: [SpotEdit] = [],
        masks: [PhotonMask] = []
    ) {
        self.version = version
        self.basic = basic
        self.toneCurve = toneCurve
        self.hsl = hsl
        self.blackAndWhite = blackAndWhite
        self.colorGrading = colorGrading
        self.detail = detail
        self.lens = lens
        self.transform = transform
        self.effects = effects
        self.calibration = calibration
        self.crop = crop
        self.spots = spots
        self.masks = masks
    }

    /// True when every panel is at its default (no visible edit).
    public var isDefault: Bool { self == DevelopSettings() }
}

// MARK: - Basic panel

/// White balance + tone + presence, matching Lightroom's Basic panel.
/// Ranges follow Lightroom conventions: Exposure ±5 EV, everything else −100…+100.
public struct BasicAdjustments: Codable, Equatable, Sendable {
    /// Kelvin, meaningful for RAW sources (2000…50000). For rendered files the pipeline maps
    /// the same value onto a relative temperature shift so the slider behaves consistently.
    public var temperature: Double
    /// Green–magenta tint, −150…+150 (Lightroom range).
    public var tint: Double
    /// True until the user touches WB; the pipeline then uses "As Shot" from the RAW.
    public var whiteBalanceIsAsShot: Bool

    public var exposure: Double      // EV, −5…+5
    public var contrast: Double      // −100…+100
    public var highlights: Double    // −100…+100
    public var shadows: Double       // −100…+100
    public var whites: Double        // −100…+100
    public var blacks: Double        // −100…+100

    public var texture: Double       // −100…+100
    public var clarity: Double       // −100…+100
    public var dehaze: Double        // −100…+100

    public var vibrance: Double      // −100…+100
    public var saturation: Double    // −100…+100

    public init(
        temperature: Double = 6500, tint: Double = 0, whiteBalanceIsAsShot: Bool = true,
        exposure: Double = 0, contrast: Double = 0,
        highlights: Double = 0, shadows: Double = 0, whites: Double = 0, blacks: Double = 0,
        texture: Double = 0, clarity: Double = 0, dehaze: Double = 0,
        vibrance: Double = 0, saturation: Double = 0
    ) {
        self.temperature = temperature
        self.tint = tint
        self.whiteBalanceIsAsShot = whiteBalanceIsAsShot
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.texture = texture
        self.clarity = clarity
        self.dehaze = dehaze
        self.vibrance = vibrance
        self.saturation = saturation
    }
}

// MARK: - Tone curve

/// Parametric region sliders plus point curves (composite + per-channel), like Lightroom.
public struct ToneCurveSettings: Codable, Equatable, Sendable {
    /// Region sliders, each −100…+100.
    public var highlights: Double
    public var lights: Double
    public var darks: Double
    public var shadowsRegion: Double

    /// Point curves. The composite curve applies to luminance; R/G/B apply per channel.
    /// A curve containing exactly (0,0) and (1,1) is the identity.
    public var pointCurve: CurvePoints
    public var redCurve: CurvePoints
    public var greenCurve: CurvePoints
    public var blueCurve: CurvePoints

    public init(
        highlights: Double = 0, lights: Double = 0, darks: Double = 0, shadowsRegion: Double = 0,
        pointCurve: CurvePoints = .identity,
        redCurve: CurvePoints = .identity,
        greenCurve: CurvePoints = .identity,
        blueCurve: CurvePoints = .identity
    ) {
        self.highlights = highlights
        self.lights = lights
        self.darks = darks
        self.shadowsRegion = shadowsRegion
        self.pointCurve = pointCurve
        self.redCurve = redCurve
        self.greenCurve = greenCurve
        self.blueCurve = blueCurve
    }
}

/// An ordered list of control points in the unit square, interpolated with a monotone cubic.
public struct CurvePoints: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public var points: [Point]

    public static let identity = CurvePoints(points: [.init(x: 0, y: 0), .init(x: 1, y: 1)])

    public init(points: [Point]) {
        self.points = points.sorted { $0.x < $1.x }
    }

    public var isIdentity: Bool { self == .identity }

    /// Insert or move a point, keeping x-order and a minimum spacing so the interpolant
    /// stays well-conditioned.
    public mutating func upsert(_ point: Point, minSpacing: Double = 0.01) {
        points.removeAll { abs($0.x - point.x) < minSpacing }
        points.append(point)
        points.sort { $0.x < $1.x }
    }
}

// MARK: - HSL / B&W

public enum ColorBand: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
}

/// Per-band Hue / Saturation / Luminance shifts, each −100…+100.
public struct HSLAdjustments: Codable, Equatable, Sendable {
    public var hue: [ColorBand: Double]
    public var saturation: [ColorBand: Double]
    public var luminance: [ColorBand: Double]

    public init(
        hue: [ColorBand: Double] = [:],
        saturation: [ColorBand: Double] = [:],
        luminance: [ColorBand: Double] = [:]
    ) {
        self.hue = hue
        self.saturation = saturation
        self.luminance = luminance
    }

    public var isDefault: Bool {
        hue.values.allSatisfy { $0 == 0 } &&
        saturation.values.allSatisfy { $0 == 0 } &&
        luminance.values.allSatisfy { $0 == 0 }
    }
}

/// B&W conversion: per-band contribution to the grey mix, −100…+100.
public struct BlackAndWhiteMix: Codable, Equatable, Sendable {
    public var mix: [ColorBand: Double]
    public init(mix: [ColorBand: Double] = [:]) { self.mix = mix }
}

// MARK: - Color grading

public struct ColorGradingSettings: Codable, Equatable, Sendable {
    public struct Wheel: Codable, Equatable, Sendable {
        /// Hue in degrees 0…360.
        public var hue: Double
        /// Saturation 0…100.
        public var saturation: Double
        /// Luminance −100…+100.
        public var luminance: Double
        public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
            self.hue = hue; self.saturation = saturation; self.luminance = luminance
        }
        public var isDefault: Bool { saturation == 0 && luminance == 0 }
    }

    public var shadows: Wheel
    public var midtones: Wheel
    public var highlights: Wheel
    public var global: Wheel
    /// 0…100 — how much the ranges overlap.
    public var blending: Double
    /// −100…+100 — shifts the shadow/highlight crossover.
    public var balance: Double

    public init(
        shadows: Wheel = .init(), midtones: Wheel = .init(), highlights: Wheel = .init(),
        global: Wheel = .init(), blending: Double = 50, balance: Double = 0
    ) {
        self.shadows = shadows
        self.midtones = midtones
        self.highlights = highlights
        self.global = global
        self.blending = blending
        self.balance = balance
    }
}

// MARK: - Detail

public struct DetailSettings: Codable, Equatable, Sendable {
    public var sharpeningAmount: Double   // 0…150 (LR default 40 for RAW; we store 0 = off and
                                          // apply the RAW default at decode, keeping 0 neutral)
    public var sharpeningRadius: Double   // 0.5…3.0
    public var sharpeningDetail: Double   // 0…100
    public var sharpeningMasking: Double  // 0…100 (edge mask threshold)

    public var luminanceNR: Double        // 0…100
    public var luminanceDetail: Double    // 0…100
    public var luminanceContrast: Double  // 0…100
    public var colorNR: Double            // 0…100
    public var colorDetail: Double        // 0…100
    public var colorSmoothness: Double    // 0…100

    public init(
        sharpeningAmount: Double = 0, sharpeningRadius: Double = 1.0,
        sharpeningDetail: Double = 25, sharpeningMasking: Double = 0,
        luminanceNR: Double = 0, luminanceDetail: Double = 50, luminanceContrast: Double = 0,
        colorNR: Double = 25, colorDetail: Double = 50, colorSmoothness: Double = 50
    ) {
        self.sharpeningAmount = sharpeningAmount
        self.sharpeningRadius = sharpeningRadius
        self.sharpeningDetail = sharpeningDetail
        self.sharpeningMasking = sharpeningMasking
        self.luminanceNR = luminanceNR
        self.luminanceDetail = luminanceDetail
        self.luminanceContrast = luminanceContrast
        self.colorNR = colorNR
        self.colorDetail = colorDetail
        self.colorSmoothness = colorSmoothness
    }
}

// MARK: - Lens corrections / Transform

public struct LensCorrectionSettings: Codable, Equatable, Sendable {
    public var enableProfileCorrections: Bool
    public var removeChromaticAberration: Bool
    public var manualDistortion: Double       // −100…+100
    public var manualVignetteAmount: Double   // −100…+100
    public var manualVignetteMidpoint: Double // 0…100
    public var purpleFringeAmount: Double     // 0…20
    public var greenFringeAmount: Double      // 0…20
    public var upright: UprightMode

    public enum UprightMode: String, Codable, Sendable {
        case off, auto, level, vertical, full
    }

    public init(
        enableProfileCorrections: Bool = false,
        removeChromaticAberration: Bool = false,
        manualDistortion: Double = 0,
        manualVignetteAmount: Double = 0,
        manualVignetteMidpoint: Double = 50,
        purpleFringeAmount: Double = 0,
        greenFringeAmount: Double = 0,
        upright: UprightMode = .off
    ) {
        self.enableProfileCorrections = enableProfileCorrections
        self.removeChromaticAberration = removeChromaticAberration
        self.manualDistortion = manualDistortion
        self.manualVignetteAmount = manualVignetteAmount
        self.manualVignetteMidpoint = manualVignetteMidpoint
        self.purpleFringeAmount = purpleFringeAmount
        self.greenFringeAmount = greenFringeAmount
        self.upright = upright
    }
}

public struct TransformSettings: Codable, Equatable, Sendable {
    public var vertical: Double    // −100…+100 (keystone)
    public var horizontal: Double  // −100…+100
    public var rotate: Double      // −10…+10 degrees (fine rotation, separate from crop angle)
    public var aspect: Double      // −100…+100
    public var scale: Double       // 50…150, default 100
    public var offsetX: Double     // −100…+100
    public var offsetY: Double     // −100…+100

    public init(
        vertical: Double = 0, horizontal: Double = 0, rotate: Double = 0,
        aspect: Double = 0, scale: Double = 100, offsetX: Double = 0, offsetY: Double = 0
    ) {
        self.vertical = vertical
        self.horizontal = horizontal
        self.rotate = rotate
        self.aspect = aspect
        self.scale = scale
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    public var isDefault: Bool { self == TransformSettings() }
}

// MARK: - Effects / Calibration

public struct EffectsSettings: Codable, Equatable, Sendable {
    // Post-crop vignette
    public var vignetteAmount: Double     // −100…+100
    public var vignetteMidpoint: Double   // 0…100
    public var vignetteRoundness: Double  // −100…+100
    public var vignetteFeather: Double    // 0…100
    public var vignetteHighlights: Double // 0…100 (highlight protection)
    // Grain
    public var grainAmount: Double        // 0…100
    public var grainSize: Double          // 0…100
    public var grainRoughness: Double     // 0…100

    public init(
        vignetteAmount: Double = 0, vignetteMidpoint: Double = 50,
        vignetteRoundness: Double = 0, vignetteFeather: Double = 50,
        vignetteHighlights: Double = 0,
        grainAmount: Double = 0, grainSize: Double = 25, grainRoughness: Double = 50
    ) {
        self.vignetteAmount = vignetteAmount
        self.vignetteMidpoint = vignetteMidpoint
        self.vignetteRoundness = vignetteRoundness
        self.vignetteFeather = vignetteFeather
        self.vignetteHighlights = vignetteHighlights
        self.grainAmount = grainAmount
        self.grainSize = grainSize
        self.grainRoughness = grainRoughness
    }
}

public struct CalibrationSettings: Codable, Equatable, Sendable {
    /// Camera profile name; "Embedded" uses the RAW's default rendering.
    public var profile: String
    public var shadowTint: Double        // −100…+100
    public var redHue: Double            // −100…+100
    public var redSaturation: Double     // −100…+100
    public var greenHue: Double
    public var greenSaturation: Double
    public var blueHue: Double
    public var blueSaturation: Double

    public init(
        profile: String = "Embedded",
        shadowTint: Double = 0,
        redHue: Double = 0, redSaturation: Double = 0,
        greenHue: Double = 0, greenSaturation: Double = 0,
        blueHue: Double = 0, blueSaturation: Double = 0
    ) {
        self.profile = profile
        self.shadowTint = shadowTint
        self.redHue = redHue
        self.redSaturation = redSaturation
        self.greenHue = greenHue
        self.greenSaturation = greenSaturation
        self.blueHue = blueHue
        self.blueSaturation = blueSaturation
    }
}

// MARK: - Crop / Spot removal

/// Crop stored in normalised source coordinates (0…1, origin top-left, pre-transform), so it is
/// resolution-independent and survives re-decodes at any size.
public struct CropSettings: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Straighten angle in degrees, −45…+45.
    public var angle: Double
    /// Locked aspect ratio (w/h), nil = free.
    public var lockedAspect: Double?

    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1,
                angle: Double = 0, lockedAspect: Double? = nil) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.angle = angle; self.lockedAspect = lockedAspect
    }
}

public struct SpotEdit: Codable, Equatable, Sendable, Identifiable {
    public enum Mode: String, Codable, Sendable { case clone, heal }

    public var id: UUID
    public var mode: Mode
    /// Destination centre in normalised source coordinates.
    public var x: Double
    public var y: Double
    /// Radius as a fraction of the image's long edge.
    public var radius: Double
    /// Source patch centre in normalised coordinates.
    public var sourceX: Double
    public var sourceY: Double
    public var feather: Double  // 0…100
    public var opacity: Double  // 0…100

    public init(id: UUID = UUID(), mode: Mode, x: Double, y: Double, radius: Double,
                sourceX: Double, sourceY: Double, feather: Double = 50, opacity: Double = 100) {
        self.id = id
        self.mode = mode
        self.x = x; self.y = y; self.radius = radius
        self.sourceX = sourceX; self.sourceY = sourceY
        self.feather = feather; self.opacity = opacity
    }
}
