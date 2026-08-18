import Foundation

/// Export file-naming templates: a token string like
/// `"{name}-{date:yyyyMMdd}-{seq:3}"` rendered per exported photo.
///
/// Supported tokens:
///   {name}          original filename without extension
///   {seq}, {seq:N}  1-based sequence number, zero-padded to N digits
///   {date}, {date:FMT}  capture date (falls back to export date), default FMT yyyy-MM-dd
///   {rating}        star rating 0–5
///   {camera}        camera model
///   {iso}           ISO value
public struct NamingTemplate: Codable, Equatable, Sendable {
    public var template: String

    public init(template: String = "{name}") {
        self.template = template
    }

    public struct Context {
        public var originalName: String
        public var sequence: Int
        public var captureDate: Date?
        public var rating: Int
        public var camera: String
        public var iso: Int?

        public init(originalName: String, sequence: Int, captureDate: Date? = nil,
                    rating: Int = 0, camera: String = "", iso: Int? = nil) {
            self.originalName = originalName
            self.sequence = sequence
            self.captureDate = captureDate
            self.rating = rating
            self.camera = camera
            self.iso = iso
        }
    }

    public func render(_ ctx: Context, now: Date = Date()) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                out += rest[open...]
                return sanitize(out)
            }
            let token = String(rest[rest.index(after: open)..<close])
            out += expand(token: token, ctx: ctx, now: now)
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return sanitize(out)
    }

    private func expand(token: String, ctx: Context, now: Date) -> String {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        let key = parts.first ?? ""
        let arg = parts.count > 1 ? parts[1] : nil

        switch key {
        case "name":
            return ctx.originalName
        case "seq":
            let width = arg.flatMap(Int.init) ?? 1
            return String(format: "%0\(max(width, 1))d", ctx.sequence)
        case "date":
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = arg ?? "yyyy-MM-dd"
            return fmt.string(from: ctx.captureDate ?? now)
        case "rating":
            return String(ctx.rating)
        case "camera":
            return ctx.camera
        case "iso":
            return ctx.iso.map(String.init) ?? ""
        default:
            return "{\(token)}"  // unknown tokens pass through verbatim
        }
    }

    /// Strip filesystem-hostile characters.
    private func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var out = ""
        for scalar in s.unicodeScalars {
            out.unicodeScalars.append(bad.contains(scalar) ? "_" : scalar)
        }
        return out
    }
}
