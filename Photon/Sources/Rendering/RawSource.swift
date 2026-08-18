import Foundation
import CoreImage
import PhotonCore

/// Decodes a photo's source file into a linear-light CIImage, GPU-resident from the first
/// stage. RAW files go through CIRAWFilter (Apple Silicon-accelerated, supports most camera
/// formats); rendered files through CIImage(contentsOf:). White balance and RAW-domain
/// parameters (from DevelopSettings) are applied inside the RAW decoder itself, where they
/// belong photometrically.
struct RawSource {

    enum DecodeResult {
        case raw(CIRAWFilter)
        case rendered(CIImage)
        case unsupported(String)
    }

    let url: URL
    let result: DecodeResult

    static let rawExtensions: Set<String> = [
        "arw", "cr2", "cr3", "nef", "nrw", "orf", "raf", "rw2", "pef", "srw", "dng", "erf",
        "kdc", "mrw", "raw", "sr2", "srf", "x3f", "iiq", "3fr", "fff"
    ]

    init(url: URL) {
        self.url = url
        let ext = url.pathExtension.lowercased()
        if Self.rawExtensions.contains(ext) {
            if let filter = CIRAWFilter(imageURL: url) {
                result = .raw(filter)
            } else {
                // CIRAWFilter returned nil — camera model/format not supported by this OS.
                result = .unsupported("RAW format not supported by Core Image: .\(ext)")
            }
        } else if let image = CIImage(contentsOf: url,
                                      options: [.applyOrientationProperty: true]) {
            result = .rendered(image)
        } else {
            result = .unsupported("Unreadable image file")
        }
    }

    var isRAW: Bool {
        if case .raw = result { return true }
        return false
    }

    var unsupportedReason: String? {
        if case .unsupported(let reason) = result { return reason }
        return nil
    }

    /// Produce the base image with RAW-domain settings applied.
    /// `scaleHint` (0…1] asks the RAW decoder for a downscaled draft decode — dramatically
    /// faster for fit-to-screen previews of 60MP files; pass 1 for full resolution.
    func baseImage(settings: DevelopSettings, scaleHint: Double = 1.0) -> CIImage? {
        switch result {
        case .raw(let filter):
            // Configure the RAW-domain parameters. CIRAWFilter state is cheap to mutate;
            // decode happens lazily when the output image is rendered.
            if !settings.basic.whiteBalanceIsAsShot {
                filter.neutralTemperature = Float(settings.basic.temperature)
                filter.neutralTint = Float(settings.basic.tint)
            }
            // Keep the default boost curve; tone is Photon's job downstream.
            filter.boostAmount = 0
            filter.extendedDynamicRangeAmount = 2   // full headroom for highlight recovery
            // RAW-domain detail (demosaic-aware, better than post-hoc filters):
            filter.sharpnessAmount = Float(settings.detail.sharpeningAmount / 150 * 2)
            filter.luminanceNoiseReductionAmount = Float(settings.detail.luminanceNR / 100)
            filter.colorNoiseReductionAmount = Float(settings.detail.colorNR / 100)
            filter.detailAmount = Float(settings.detail.sharpeningDetail / 100 * 3)
            filter.contrastAmount = 0
            filter.isLensCorrectionEnabled = settings.lens.enableProfileCorrections
            if scaleHint < 1.0 {
                filter.scaleFactor = Float(max(scaleHint, 0.05))
            } else {
                filter.scaleFactor = 1.0
            }
            return filter.outputImage
        case .rendered(let image):
            if scaleHint < 1.0 {
                return image.transformed(by: .init(scaleX: scaleHint, y: scaleHint))
            }
            return image
        case .unsupported:
            return nil
        }
    }

    /// Full-resolution pixel size of the source (post-orientation).
    var pixelSize: CGSize? {
        switch result {
        case .raw(let filter):
            return filter.outputImage?.extent.size
        case .rendered(let image):
            return image.extent.size
        case .unsupported:
            return nil
        }
    }

    /// Depth data availability (portrait captures) for Depth Range masks.
    static func depthImage(url: URL) -> CIImage? {
        CIImage(contentsOf: url, options: [.auxiliaryDepth: true])
            ?? CIImage(contentsOf: url, options: [.auxiliaryDisparity: true])
    }
}
