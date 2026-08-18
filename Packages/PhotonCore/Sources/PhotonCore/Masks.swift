import Foundation

/// A named mask in the Masking panel: an ordered list of components combined with
/// add / subtract / intersect, plus its own scoped set of develop adjustments.
///
/// Masks are pure instruction data — geometry is normalised to the unit square of the
/// *pre-crop* source image, AI masks store their seed (not a bitmap) plus an optional cached
/// raster keyed by resolution, so masks re-render correctly at any output size and stay
/// editable forever.
public struct PhotonMask: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var inverted: Bool
    public var components: [MaskComponent]
    public var adjustments: LocalAdjustments

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, inverted: Bool = false,
                components: [MaskComponent] = [], adjustments: LocalAdjustments = .init()) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.inverted = inverted
        self.components = components
        self.adjustments = adjustments
    }
}

public struct MaskComponent: Codable, Equatable, Sendable, Identifiable {
    public enum Mode: String, Codable, Sendable {
        case add, subtract, intersect
    }

    public var id: UUID
    public var mode: Mode
    public var kind: MaskKind
    /// Extra feather applied to this component's raster, 0…100.
    public var feather: Double
    /// Per-component invert (Lightroom allows inverting individual components).
    public var inverted: Bool

    public init(id: UUID = UUID(), mode: Mode = .add, kind: MaskKind,
                feather: Double = 0, inverted: Bool = false) {
        self.id = id
        self.mode = mode
        self.kind = kind
        self.feather = feather
        self.inverted = inverted
    }
}

/// Every mask type in the Masking panel. Serialised with an explicit type discriminator so the
/// catalog format stays stable as cases gain fields.
public enum MaskKind: Equatable, Sendable {
    case subject
    case sky
    case person(PersonMaskOptions)
    /// AI-refined object selection seeded by a click point or a drag box (normalised coords).
    case object(ObjectSeed)
    case brush(BrushMask)
    case linearGradient(LinearGradientMask)
    case radialGradient(RadialGradientMask)
    case colorRange(ColorRangeMask)
    case luminanceRange(LuminanceRangeMask)
    case depthRange(DepthRangeMask)

    public var displayName: String {
        switch self {
        case .subject: return "Subject"
        case .sky: return "Sky"
        case .person: return "Person"
        case .object: return "Object"
        case .brush: return "Brush"
        case .linearGradient: return "Linear Gradient"
        case .radialGradient: return "Radial Gradient"
        case .colorRange: return "Color Range"
        case .luminanceRange: return "Luminance Range"
        case .depthRange: return "Depth Range"
        }
    }
}

// MARK: MaskKind Codable (type-discriminated)

extension MaskKind: Codable {
    private enum CodingKeys: String, CodingKey { case type, payload }

    private enum Discriminator: String, Codable {
        case subject, sky, person, object, brush
        case linearGradient, radialGradient, colorRange, luminanceRange, depthRange
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Discriminator.self, forKey: .type) {
        case .subject: self = .subject
        case .sky: self = .sky
        case .person: self = .person(try c.decode(PersonMaskOptions.self, forKey: .payload))
        case .object: self = .object(try c.decode(ObjectSeed.self, forKey: .payload))
        case .brush: self = .brush(try c.decode(BrushMask.self, forKey: .payload))
        case .linearGradient:
            self = .linearGradient(try c.decode(LinearGradientMask.self, forKey: .payload))
        case .radialGradient:
            self = .radialGradient(try c.decode(RadialGradientMask.self, forKey: .payload))
        case .colorRange: self = .colorRange(try c.decode(ColorRangeMask.self, forKey: .payload))
        case .luminanceRange:
            self = .luminanceRange(try c.decode(LuminanceRangeMask.self, forKey: .payload))
        case .depthRange: self = .depthRange(try c.decode(DepthRangeMask.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .subject: try c.encode(Discriminator.subject, forKey: .type)
        case .sky: try c.encode(Discriminator.sky, forKey: .type)
        case .person(let p):
            try c.encode(Discriminator.person, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .object(let p):
            try c.encode(Discriminator.object, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .brush(let p):
            try c.encode(Discriminator.brush, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .linearGradient(let p):
            try c.encode(Discriminator.linearGradient, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .radialGradient(let p):
            try c.encode(Discriminator.radialGradient, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .colorRange(let p):
            try c.encode(Discriminator.colorRange, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .luminanceRange(let p):
            try c.encode(Discriminator.luminanceRange, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .depthRange(let p):
            try c.encode(Discriminator.depthRange, forKey: .type)
            try c.encode(p, forKey: .payload)
        }
    }
}

// MARK: - AI mask payloads

/// Person masks mirror Lightroom's people masking: whole person or a set of parts.
public struct PersonMaskOptions: Codable, Equatable, Sendable {
    public enum Part: String, Codable, CaseIterable, Sendable {
        case entirePerson, skin, hair, clothing, eyes, lips, teeth
    }

    /// Which detected person (index into Vision's instance list, stable-sorted left-to-right).
    public var personIndex: Int
    public var parts: Set<Part>

    public init(personIndex: Int = 0, parts: Set<Part> = [.entirePerson]) {
        self.personIndex = personIndex
        self.parts = parts
    }
}

public struct ObjectSeed: Codable, Equatable, Sendable {
    public enum Seed: Equatable, Sendable {
        case point(x: Double, y: Double)
        case box(x: Double, y: Double, width: Double, height: Double)
    }
    public var seed: Seed

    public init(seed: Seed) { self.seed = seed }

    private enum CodingKeys: String, CodingKey { case kind, x, y, width, height }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let x = try c.decode(Double.self, forKey: .x)
        let y = try c.decode(Double.self, forKey: .y)
        if kind == "box" {
            seed = .box(x: x, y: y,
                        width: try c.decode(Double.self, forKey: .width),
                        height: try c.decode(Double.self, forKey: .height))
        } else {
            seed = .point(x: x, y: y)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch seed {
        case .point(let x, let y):
            try c.encode("point", forKey: .kind)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
        case .box(let x, let y, let w, let h):
            try c.encode("box", forKey: .kind)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(w, forKey: .width)
            try c.encode(h, forKey: .height)
        }
    }
}

// MARK: - Geometric mask payloads

public struct BrushMask: Codable, Equatable, Sendable {
    public struct Stroke: Codable, Equatable, Sendable {
        public struct Dab: Codable, Equatable, Sendable {
            public var x: Double
            public var y: Double
            /// Per-dab pressure 0…1 (tablet support).
            public var pressure: Double
            public init(x: Double, y: Double, pressure: Double = 1) {
                self.x = x; self.y = y; self.pressure = pressure
            }
        }
        /// True = erase stroke.
        public var isEraser: Bool
        /// Radius as a fraction of the image long edge.
        public var radius: Double
        public var feather: Double  // 0…100
        public var flow: Double     // 0…100
        public var density: Double  // 0…100 (opacity ceiling)
        /// Auto-mask: restrict the stroke to regions of similar colour to the initial dab.
        public var autoMask: Bool
        public var dabs: [Dab]

        public init(isEraser: Bool = false, radius: Double, feather: Double = 50,
                    flow: Double = 100, density: Double = 100, autoMask: Bool = false,
                    dabs: [Dab] = []) {
            self.isEraser = isEraser
            self.radius = radius
            self.feather = feather
            self.flow = flow
            self.density = density
            self.autoMask = autoMask
            self.dabs = dabs
        }
    }

    public var strokes: [Stroke]
    public init(strokes: [Stroke] = []) { self.strokes = strokes }
}

/// Linear gradient: full effect on the near side of `start`, fading to zero past `end`.
/// Points in normalised image coordinates.
public struct LinearGradientMask: Codable, Equatable, Sendable {
    public var startX: Double
    public var startY: Double
    public var endX: Double
    public var endY: Double

    public init(startX: Double, startY: Double, endX: Double, endY: Double) {
        self.startX = startX; self.startY = startY
        self.endX = endX; self.endY = endY
    }
}

/// Radial gradient ellipse; effect inside by default, feather across the boundary.
public struct RadialGradientMask: Codable, Equatable, Sendable {
    public var centerX: Double
    public var centerY: Double
    /// Radii as fractions of image width/height respectively.
    public var radiusX: Double
    public var radiusY: Double
    /// Rotation in degrees.
    public var rotation: Double
    public var feather: Double  // 0…100

    public init(centerX: Double, centerY: Double, radiusX: Double, radiusY: Double,
                rotation: Double = 0, feather: Double = 50) {
        self.centerX = centerX; self.centerY = centerY
        self.radiusX = radiusX; self.radiusY = radiusY
        self.rotation = rotation; self.feather = feather
    }
}

public struct ColorRangeMask: Codable, Equatable, Sendable {
    /// Sampled reference colours (linear RGB 0…1); Lightroom allows up to 5 eyedropper samples.
    public struct Sample: Codable, Equatable, Sendable {
        public var r: Double
        public var g: Double
        public var b: Double
        public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    }
    public var samples: [Sample]
    /// Tolerance 0…100 (Lightroom's "Refine" slider).
    public var refine: Double

    public init(samples: [Sample], refine: Double = 50) {
        self.samples = samples
        self.refine = refine
    }
}

public struct LuminanceRangeMask: Codable, Equatable, Sendable {
    /// Selected range 0…1 with smooth falloff shoulders.
    public var low: Double
    public var high: Double
    /// Shoulder width 0…1 on each side (Lightroom's "Smoothness").
    public var smoothness: Double

    public init(low: Double = 0, high: Double = 1, smoothness: Double = 0.1) {
        self.low = low; self.high = high; self.smoothness = smoothness
    }
}

public struct DepthRangeMask: Codable, Equatable, Sendable {
    /// Selected normalised depth range (0 = nearest, 1 = farthest).
    public var near: Double
    public var far: Double
    public var smoothness: Double

    public init(near: Double = 0, far: Double = 1, smoothness: Double = 0.1) {
        self.near = near; self.far = far; self.smoothness = smoothness
    }
}

// MARK: - Per-mask adjustments

/// The Basic-panel-style sliders scoped to a single mask, matching Lightroom's local
/// adjustment set.
public struct LocalAdjustments: Codable, Equatable, Sendable {
    public var exposure: Double      // −4…+4 EV (Lightroom local range)
    public var contrast: Double      // −100…+100
    public var highlights: Double
    public var shadows: Double
    public var whites: Double
    public var blacks: Double
    public var texture: Double
    public var clarity: Double
    public var dehaze: Double
    public var saturation: Double
    public var temperature: Double   // −100…+100 relative shift for locals
    public var tint: Double          // −100…+100
    public var hueShift: Double      // −100…+100 (Lightroom's local Hue)
    public var sharpness: Double     // −100…+100
    public var noise: Double         // 0…100 (local NR)
    public var moire: Double         // 0…100
    public var defringe: Double      // 0…100
    /// Overall mask amount −100…+100 (Lightroom's per-mask Amount slider); 100 = as-set.
    public var amount: Double

    public init(
        exposure: Double = 0, contrast: Double = 0,
        highlights: Double = 0, shadows: Double = 0, whites: Double = 0, blacks: Double = 0,
        texture: Double = 0, clarity: Double = 0, dehaze: Double = 0, saturation: Double = 0,
        temperature: Double = 0, tint: Double = 0, hueShift: Double = 0,
        sharpness: Double = 0, noise: Double = 0, moire: Double = 0, defringe: Double = 0,
        amount: Double = 100
    ) {
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.texture = texture
        self.clarity = clarity
        self.dehaze = dehaze
        self.saturation = saturation
        self.temperature = temperature
        self.tint = tint
        self.hueShift = hueShift
        self.sharpness = sharpness
        self.noise = noise
        self.moire = moire
        self.defringe = defringe
        self.amount = amount
    }

    public var isDefault: Bool { self == LocalAdjustments() }
}
