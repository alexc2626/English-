import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import AppKit
import PhotonCore

/// Batch export: renders each photo's full non-destructive stack (masks, composites and all)
/// to final pixels — the only place in Photon where edits become pixels. Supports format,
/// bit depth, colour space, long-edge resizing, output sharpening, text watermarking, and
/// naming templates.
actor ExportService {

    static let shared = ExportService()

    enum Format: String, CaseIterable, Sendable {
        case jpeg = "JPEG"
        case tiff8 = "TIFF (8-bit)"
        case tiff16 = "TIFF (16-bit)"
        case png = "PNG"
        case heif = "HEIF"

        var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .tiff8, .tiff16: return "tif"
            case .png: return "png"
            case .heif: return "heic"
            }
        }
    }

    enum ColorSpaceChoice: String, CaseIterable, Sendable {
        case sRGB = "sRGB"
        case adobeRGB = "Adobe RGB"
        case displayP3 = "Display P3"
        case proPhoto = "ProPhoto RGB"

        var cgColorSpace: CGColorSpace {
            switch self {
            case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)!
            case .adobeRGB: return CGColorSpace(name: CGColorSpace.adobeRGB1998)!
            case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)!
            case .proPhoto: return CGColorSpace(name: CGColorSpace.rommrgb)!
            }
        }
    }

    struct Options: Sendable {
        var format: Format = .jpeg
        var jpegQuality: Double = 0.9
        var colorSpace: ColorSpaceChoice = .sRGB
        /// Resize so the long edge is at most this many pixels; nil = full resolution.
        var maxLongEdge: Int?
        /// Output sharpening 0…100 (screen/print sharpening applied after resize).
        var outputSharpening: Double = 0
        /// Watermark text drawn bottom-right; empty = none.
        var watermarkText: String = ""
        var watermarkOpacity: Double = 0.5
        var naming = NamingTemplate(template: "{name}")
        var destination: URL
    }

    struct Progress: Sendable {
        var completed: Int
        var total: Int
        var currentFile: String
    }

    enum ExportError: Error, CustomStringConvertible {
        case renderFailed(String)
        case writeFailed(String)
        var description: String {
            switch self {
            case .renderFailed(let f): return "Render failed for \(f)"
            case .writeFailed(let f): return "Write failed for \(f)"
            }
        }
    }

    /// Export a batch. Returns the written URLs.
    func export(photos: [PhotoRecord], options: Options,
                progress: (@Sendable (Progress) -> Void)? = nil) async throws -> [URL] {
        var written: [URL] = []
        let pipeline = PipelineBuilder(maskProvider: { component, extent in
            MaskRasterizer.shared.raster(for: component, extent: extent)
        })

        for (index, photo) in photos.enumerated() {
            progress?(Progress(completed: index, total: photos.count,
                               currentFile: photo.fileName))
            try Task.checkCancellation()

            let url = try renderOne(photo: photo, options: options, sequence: index + 1,
                                    pipeline: pipeline)
            written.append(url)
        }
        progress?(Progress(completed: photos.count, total: photos.count, currentFile: ""))
        return written
    }

    private func renderOne(photo: PhotoRecord, options: Options, sequence: Int,
                           pipeline: PipelineBuilder) throws -> URL {
        let context = RenderEngine.shared.ciContext

        // Full-resolution decode + full instruction stack. AI mask rasters must already be
        // cached from editing; if not, they compute on first use via the provider's async
        // path and this render picks them up on retry.
        let source = RawSource(url: photo.fileURL)
        guard let base = source.baseImage(settings: photo.settings, scaleHint: 1.0) else {
            throw ExportError.renderFailed(photo.fileName)
        }
        MaskRasterizer.shared.beginRender(image: base, url: photo.fileURL)
        var image = pipeline.build(base: base, settings: photo.settings,
                                   isRAW: source.isRAW)

        // Resize.
        if let maxEdge = options.maxLongEdge {
            let longEdge = max(image.extent.width, image.extent.height)
            let scale = CGFloat(maxEdge) / longEdge
            if scale < 1 {
                image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0
                ])
            }
        }

        // Output sharpening (post-resize, like Lightroom's output sharpening).
        if options.outputSharpening > 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: options.outputSharpening / 100 * 0.8
            ])
        }

        // Watermark.
        if !options.watermarkText.isEmpty {
            image = Self.applyWatermark(text: options.watermarkText,
                                        opacity: options.watermarkOpacity, to: image)
        }

        // Naming.
        let stem = (photo.fileName as NSString).deletingPathExtension
        let name = options.naming.render(.init(
            originalName: stem, sequence: sequence, captureDate: photo.captureDate,
            rating: photo.rating, camera: photo.cameraModel, iso: photo.iso))
        var outputURL = options.destination
            .appendingPathComponent("\(name).\(options.format.fileExtension)")
        var counter = 1
        while FileManager.default.fileExists(atPath: outputURL.path) {
            outputURL = options.destination
                .appendingPathComponent("\(name)-\(counter).\(options.format.fileExtension)")
            counter += 1
        }

        // Encode. All writes convert from the linear working space to the chosen output
        // space here, at the very end.
        let space = options.colorSpace.cgColorSpace
        let qualityKey = CIImageRepresentationOption(
            rawValue: kCGImageDestinationLossyCompressionQuality as String)
        do {
            switch options.format {
            case .jpeg:
                try context.writeJPEGRepresentation(
                    of: image, to: outputURL, colorSpace: space,
                    options: [qualityKey: options.jpegQuality])
            case .tiff8:
                try context.writeTIFFRepresentation(
                    of: image, to: outputURL, format: .RGBA8, colorSpace: space, options: [:])
            case .tiff16:
                try context.writeTIFFRepresentation(
                    of: image, to: outputURL, format: .RGBA16, colorSpace: space, options: [:])
            case .png:
                try context.writePNGRepresentation(
                    of: image, to: outputURL, format: .RGBA8, colorSpace: space, options: [:])
            case .heif:
                try context.writeHEIFRepresentation(
                    of: image, to: outputURL, format: .RGBA8, colorSpace: space,
                    options: [qualityKey: options.jpegQuality])
            }
        } catch {
            throw ExportError.writeFailed(photo.fileName)
        }
        return outputURL
    }

    /// Draw a text watermark bottom-right at ~2.5% of the long edge.
    static func applyWatermark(text: String, opacity: Double, to image: CIImage) -> CIImage {
        let extent = image.extent
        let fontSize = max(extent.width, extent.height) * 0.025
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let padding = fontSize * 0.6

        let width = Int(ceil(textSize.width + padding * 2))
        let height = Int(ceil(textSize.height + padding * 2))
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
                                            pixelsHigh: height, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                            bitsPerPixel: 0) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        // Soft shadow for legibility on light backgrounds.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = fontSize * 0.08
        let shadowed: [NSAttributedString.Key: Any] = attributes.merging(
            [.shadow: shadow]) { $1 }
        NSAttributedString(string: text, attributes: shadowed)
            .draw(at: NSPoint(x: padding, y: padding))
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = bitmap.cgImage else { return image }
        var mark = CIImage(cgImage: cg)
        mark = mark.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
        ])
        let margin = fontSize
        mark = mark.transformed(by: .init(
            translationX: extent.maxX - mark.extent.width - margin,
            y: extent.minY + margin))
        return mark.composited(over: image)
    }
}
