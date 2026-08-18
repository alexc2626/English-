import Foundation
import CoreImage
import Metal
import Vision
import simd
import Observation
import PhotonCore

/// Progress/cancellation handle shared by the composite workflows, observed by the UI.
/// Progress publishing is main-actor; the cancel flag is a lock-protected bool so worker
/// code can poll it synchronously from any executor.
@Observable @MainActor
final class CompositeJob {
    var stage: String = "Preparing…"
    var progress: Double = 0

    @ObservationIgnored
    private nonisolated let cancelLock = NSLock()
    @ObservationIgnored
    private nonisolated(unsafe) var cancelFlag = false

    func cancel() {
        cancelLock.lock()
        cancelFlag = true
        cancelLock.unlock()
    }

    nonisolated var cancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelFlag
    }

    nonisolated func update(stage: String, progress: Double) {
        Task { @MainActor in
            self.stage = stage
            self.progress = progress
        }
    }
}

/// Focus stacking, HDR merge, and panorama stitching. Alignment homographies come from
/// Vision's registration requests; warping, sharpness measurement, ghost-suppressed
/// accumulation and blending run as custom Metal compute kernels over unified memory.
/// Outputs are float TIFFs imported back into the catalog as first-class sources that flow
/// through the normal Develop pipeline.
actor CompositeService {

    static let shared = CompositeService()

    enum CompositeError: Error, CustomStringConvertible {
        case needAtLeast(Int)
        case decodeFailed(URL)
        case alignmentFailed
        case cancelled
        case writeFailed

        var description: String {
            switch self {
            case .needAtLeast(let n): return "Select at least \(n) photos"
            case .decodeFailed(let url): return "Could not decode \(url.lastPathComponent)"
            case .alignmentFailed: return "Image alignment failed — are these the same scene?"
            case .cancelled: return "Cancelled"
            case .writeFailed: return "Could not write the merged file"
            }
        }
    }

    private var pipelines: CompositePipelines?

    private func pipelinesInstance() throws -> CompositePipelines {
        if let pipelines { return pipelines }
        let p = try CompositePipelines(device: RenderEngine.shared.device,
                                       queue: RenderEngine.shared.commandQueue)
        pipelines = p
        return p
    }

    private var ciContext: CIContext { RenderEngine.shared.ciContext }

    // MARK: Frame loading

    /// Decode sources at full resolution with default develop settings (linear light).
    private func loadFrames(_ urls: [URL], job: CompositeJob) throws -> [CIImage] {
        var frames: [CIImage] = []
        for (i, url) in urls.enumerated() {
            if job.cancelled { throw CompositeError.cancelled }
            job.update(stage: "Decoding \(url.lastPathComponent)",
                       progress: Double(i) / Double(urls.count) * 0.2)
            let source = RawSource(url: url)
            guard let image = source.baseImage(settings: DevelopSettings()) else {
                throw CompositeError.decodeFailed(url)
            }
            frames.append(image.transformed(by: .init(translationX: -image.extent.minX,
                                                      y: -image.extent.minY)))
        }
        return frames
    }

    // MARK: Vision registration

    /// Homography mapping `floating` onto `reference` (pixel space, bottom-left origin).
    private func homography(reference: CIImage, floating: CIImage) throws -> simd_float3x3 {
        let request = VNHomographicImageRegistrationRequest(targetedCIImage: floating,
                                                            options: [:])
        let handler = VNImageRequestHandler(ciImage: reference, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else {
            throw CompositeError.alignmentFailed
        }
        return observation.warpTransform
    }

    /// Convert a bottom-left-origin pixel homography into the top-left texture space the
    /// Metal kernels sample in: T = F_dst · H · F_src⁻¹, with F flipping y.
    private func topLeftSpace(_ H: simd_float3x3,
                              srcHeight: Float, dstHeight: Float) -> simd_float3x3 {
        let fSrc = simd_float3x3(rows: [
            SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, -1, srcHeight), SIMD3<Float>(0, 0, 1)
        ])
        let fDst = simd_float3x3(rows: [
            SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, -1, dstHeight), SIMD3<Float>(0, 0, 1)
        ])
        // F matrices are involutions (F == F⁻¹).
        return fDst * H * fSrc
    }

    // MARK: Output

    private func writeFloatTIFF(_ image: CIImage, name: String,
                                into libraryURL: URL) throws -> URL {
        let dir = libraryURL.appendingPathComponent("Composites", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent("\(name).tif")
        var counter = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(name)-\(counter).tif")
            counter += 1
        }
        do {
            // Half-float TIFF: wide dynamic range for HDR grading, reasonable file size.
            try ciContext.writeTIFFRepresentation(
                of: image, to: url, format: .RGBAh,
                colorSpace: RenderEngine.workingSpace, options: [:])
        } catch {
            throw CompositeError.writeFailed
        }
        return url
    }

    // MARK: Focus stacking

    /// Align frames (translation+perspective via Vision), compute per-pixel modified-
    /// Laplacian sharpness, and keep the sharpest source per pixel with a smoothed
    /// decision map. Returns the output file URL.
    func focusStack(urls: [URL], job: CompositeJob, libraryURL: URL) throws -> URL {
        guard urls.count >= 2 else { throw CompositeError.needAtLeast(2) }
        let p = try pipelinesInstance()
        let frames = try loadFrames(urls, job: job)
        let reference = frames[0]
        let width = Int(reference.extent.width)
        let height = Int(reference.extent.height)

        let bestColor = try p.makeTexture(width: width, height: height, readWrite: true)
        let bestScore = try p.makeTexture(width: width, height: height,
                                          format: .r32Float, readWrite: true)
        let warped = try p.makeTexture(width: width, height: height)
        let score = try p.makeTexture(width: width, height: height,
                                      format: .r32Float, readWrite: true)

        guard let initBuffer = p.queue.makeCommandBuffer() else {
            throw CompositeError.writeFailed
        }
        p.clear(bestColor, commandBuffer: initBuffer)
        p.clear(bestScore, commandBuffer: initBuffer)
        initBuffer.commit()
        initBuffer.waitUntilCompleted()

        for (i, frame) in frames.enumerated() {
            if job.cancelled { throw CompositeError.cancelled }
            job.update(stage: "Aligning & measuring frame \(i + 1)/\(frames.count)",
                       progress: 0.2 + Double(i) / Double(frames.count) * 0.7)

            let srcTexture = try p.texture(from: frame, context: ciContext)

            // Warp onto the reference grid (identity for frame 0).
            var invH = matrix_identity_float3x3
            if i > 0 {
                let H = try homography(reference: reference, floating: frame)
                let flipped = topLeftSpace(H, srcHeight: Float(frame.extent.height),
                                           dstHeight: Float(height))
                invH = flipped.inverse
            }

            guard let buffer = p.queue.makeCommandBuffer(),
                  let encoder = buffer.makeComputeCommandEncoder() else {
                throw CompositeError.writeFailed
            }
            var invHCopy = invH
            encoder.setTexture(srcTexture, index: 0)
            encoder.setTexture(warped, index: 1)
            encoder.setBytes(&invHCopy, length: MemoryLayout<simd_float3x3>.size, index: 0)
            p.dispatch(p.homographyWarp, encoder: encoder, width: width, height: height)

            // Sharpness of the warped frame.
            encoder.setTexture(warped, index: 0)
            encoder.setTexture(score, index: 1)
            p.dispatch(p.sharpnessMeasure, encoder: encoder, width: width, height: height)
            encoder.endEncoding()

            // Smooth the decision map so in-focus regions win as areas, not speckle.
            p.blur(score, sigma: 6, commandBuffer: buffer)

            guard let encoder2 = buffer.makeComputeCommandEncoder() else {
                throw CompositeError.writeFailed
            }
            encoder2.setTexture(warped, index: 0)
            encoder2.setTexture(score, index: 1)
            encoder2.setTexture(bestColor, index: 2)
            encoder2.setTexture(bestScore, index: 3)
            p.dispatch(p.focusAccumulate, encoder: encoder2, width: width, height: height)
            encoder2.endEncoding()

            buffer.commit()
            buffer.waitUntilCompleted()
        }

        job.update(stage: "Writing stacked image…", progress: 0.95)
        guard let result = p.ciImage(from: bestColor) else {
            throw CompositeError.writeFailed
        }
        let name = "Stack-" + (urls.first?.deletingPathExtension().lastPathComponent ?? "Focus")
        let url = try writeFloatTIFF(result, name: name, into: libraryURL)
        job.update(stage: "Done", progress: 1)
        return url
    }

    // MARK: HDR merge

    /// Merge a bracket into linear radiance (32-bit pipeline, half-float storage) with hat
    /// weighting and ghost suppression. EVs are estimated from EXIF exposure metadata when
    /// available, else assumed evenly stepped.
    func hdrMerge(urls: [URL], job: CompositeJob, libraryURL: URL) throws -> URL {
        guard urls.count >= 2 else { throw CompositeError.needAtLeast(2) }
        let p = try pipelinesInstance()

        // Order frames dark → bright by EXIF exposure; the middle frame is the reference.
        let exposures = urls.map { url -> (URL, Double) in
            let props = ImportService.imageProperties(url: url)
            let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let shutter = exif?[kCGImagePropertyExifExposureTime] as? Double ?? 1 / 60
            let iso = (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first ?? 100
            let fnum = exif?[kCGImagePropertyExifFNumber] as? Double ?? 8
            // Relative exposure ∝ t · ISO / N²
            return (url, shutter * Double(iso) / (fnum * fnum))
        }.sorted { $0.1 < $1.1 }

        let orderedURLs = exposures.map(\.0)
        let refIndex = orderedURLs.count / 2
        let refExposure = exposures[refIndex].1

        let frames = try loadFrames(orderedURLs, job: job)
        let reference = frames[refIndex]
        let width = Int(reference.extent.width)
        let height = Int(reference.extent.height)

        let accumColor = try p.makeTexture(width: width, height: height,
                                           format: .rgba32Float, readWrite: true)
        let accumWeight = try p.makeTexture(width: width, height: height,
                                            format: .r32Float, readWrite: true)
        let warped = try p.makeTexture(width: width, height: height)
        let refTexture = try p.texture(from: reference, context: ciContext)
        let output = try p.makeTexture(width: width, height: height, format: .rgba16Float)

        guard let initBuffer = p.queue.makeCommandBuffer() else {
            throw CompositeError.writeFailed
        }
        p.clear(accumColor, commandBuffer: initBuffer)
        p.clear(accumWeight, commandBuffer: initBuffer)
        initBuffer.commit()
        initBuffer.waitUntilCompleted()

        for (i, frame) in frames.enumerated() {
            if job.cancelled { throw CompositeError.cancelled }
            job.update(stage: "Merging frame \(i + 1)/\(frames.count)",
                       progress: 0.2 + Double(i) / Double(frames.count) * 0.7)

            let srcTexture = try p.texture(from: frame, context: ciContext)
            var invH = matrix_identity_float3x3
            if i != refIndex {
                let H = try homography(reference: reference, floating: frame)
                let flipped = topLeftSpace(H, srcHeight: Float(frame.extent.height),
                                           dstHeight: Float(height))
                invH = flipped.inverse
            }

            guard let buffer = p.queue.makeCommandBuffer(),
                  let encoder = buffer.makeComputeCommandEncoder() else {
                throw CompositeError.writeFailed
            }
            var invHCopy = invH
            encoder.setTexture(srcTexture, index: 0)
            encoder.setTexture(warped, index: 1)
            encoder.setBytes(&invHCopy, length: MemoryLayout<simd_float3x3>.size, index: 0)
            p.dispatch(p.homographyWarp, encoder: encoder, width: width, height: height)

            var exposureFactor = Float(exposures[i].1 / refExposure)
            var ghost: Float = 8
            encoder.setTexture(warped, index: 0)
            encoder.setTexture(refTexture, index: 1)
            encoder.setTexture(accumColor, index: 2)
            encoder.setTexture(accumWeight, index: 3)
            encoder.setBytes(&exposureFactor, length: 4, index: 0)
            encoder.setBytes(&ghost, length: 4, index: 1)
            p.dispatch(p.hdrAccumulate, encoder: encoder, width: width, height: height)
            encoder.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
        }

        // Resolve.
        guard let buffer = p.queue.makeCommandBuffer(),
              let encoder = buffer.makeComputeCommandEncoder() else {
            throw CompositeError.writeFailed
        }
        encoder.setTexture(accumColor, index: 0)
        encoder.setTexture(accumWeight, index: 1)
        encoder.setTexture(refTexture, index: 2)
        encoder.setTexture(output, index: 3)
        p.dispatch(p.weightedResolve, encoder: encoder, width: width, height: height)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()

        job.update(stage: "Writing HDR…", progress: 0.95)
        guard let result = p.ciImage(from: output) else { throw CompositeError.writeFailed }
        let name = "HDR-" + (urls.first?.deletingPathExtension().lastPathComponent ?? "Merge")
        let url = try writeFloatTIFF(result, name: name, into: libraryURL)
        job.update(stage: "Done", progress: 1)
        return url
    }

    // MARK: Panorama

    enum Projection: Int, CaseIterable, Sendable {
        case perspective = 0
        case cylindrical = 1
        case spherical = 2

        var label: String {
            switch self {
            case .perspective: return "Perspective"
            case .cylindrical: return "Cylindrical"
            case .spherical: return "Spherical"
            }
        }
    }

    struct PanoramaResult: Sendable {
        var url: URL
        /// Auto-crop suggestion in normalised coordinates of the stitched image.
        var suggestedCrop: CropSettings?
    }

    /// Stitch overlapping frames: chain homographies to the middle reference frame, warp
    /// through the chosen projection, feather-blend, and compute an auto-crop suggestion
    /// from the coverage map.
    func panorama(urls: [URL], projection: Projection, job: CompositeJob,
                  libraryURL: URL) throws -> PanoramaResult {
        guard urls.count >= 2 else { throw CompositeError.needAtLeast(2) }
        let p = try pipelinesInstance()
        let frames = try loadFrames(urls, job: job)
        let refIndex = frames.count / 2

        // Chain pairwise homographies to the reference: H_i maps frame i → reference plane.
        job.update(stage: "Estimating alignment…", progress: 0.25)
        var toReference = [simd_float3x3](repeating: matrix_identity_float3x3,
                                          count: frames.count)
        for i in stride(from: refIndex - 1, through: 0, by: -1) {
            if job.cancelled { throw CompositeError.cancelled }
            let pairwise = try homography(reference: frames[i + 1], floating: frames[i])
            toReference[i] = toReference[i + 1] * pairwise
        }
        for i in (refIndex + 1)..<frames.count {
            if job.cancelled { throw CompositeError.cancelled }
            let pairwise = try homography(reference: frames[i - 1], floating: frames[i])
            toReference[i] = toReference[i - 1] * pairwise
        }

        // Canvas bounds: project each frame's corners through its homography.
        let refExtent = frames[refIndex].extent
        var minX: Float = 0, minY: Float = 0
        var maxX = Float(refExtent.width), maxY = Float(refExtent.height)
        for (i, frame) in frames.enumerated() {
            let w = Float(frame.extent.width), h = Float(frame.extent.height)
            for corner in [SIMD3<Float>(0, 0, 1), SIMD3<Float>(w, 0, 1),
                           SIMD3<Float>(0, h, 1), SIMD3<Float>(w, h, 1)] {
                let q = toReference[i] * corner
                guard abs(q.z) > 1e-6 else { continue }
                minX = min(minX, q.x / q.z)
                maxX = max(maxX, q.x / q.z)
                minY = min(minY, q.y / q.z)
                maxY = max(maxY, q.y / q.z)
            }
        }
        // Clamp the canvas to a sane maximum (tiling handles bigger later).
        let canvasW = min(Int(maxX - minX), 16384)
        let canvasH = min(Int(maxY - minY), 16384)
        guard canvasW > 16, canvasH > 16 else { throw CompositeError.alignmentFailed }

        let accumColor = try p.makeTexture(width: canvasW, height: canvasH,
                                           format: .rgba32Float, readWrite: true)
        let accumWeight = try p.makeTexture(width: canvasW, height: canvasH,
                                            format: .r32Float, readWrite: true)
        let output = try p.makeTexture(width: canvasW, height: canvasH, format: .rgba16Float)

        guard let initBuffer = p.queue.makeCommandBuffer() else {
            throw CompositeError.writeFailed
        }
        p.clear(accumColor, commandBuffer: initBuffer)
        p.clear(accumWeight, commandBuffer: initBuffer)
        initBuffer.commit()
        initBuffer.waitUntilCompleted()

        // Focal estimate for cylindrical/spherical: reference width (≈50mm-ish FOV default).
        let focal = Float(refExtent.width)
        let center = SIMD2<Float>(Float(refExtent.width) / 2 - minX,
                                  Float(refExtent.height) / 2 - minY)

        for (i, frame) in frames.enumerated() {
            if job.cancelled { throw CompositeError.cancelled }
            job.update(stage: "Warping frame \(i + 1)/\(frames.count)",
                       progress: 0.35 + Double(i) / Double(frames.count) * 0.5)

            let srcTexture = try p.texture(from: frame, context: ciContext)

            // Canvas plane coords are reference coords offset by (minX, minY); the kernel
            // works around the pano centre, so bake the offset into the homography.
            let offset = simd_float3x3(rows: [
                SIMD3<Float>(1, 0, center.x + minX - Float(refExtent.width) / 2),
                SIMD3<Float>(0, 1, center.y + minY - Float(refExtent.height) / 2),
                SIMD3<Float>(0, 0, 1)
            ])
            // plane (centred reference space) → source pixels, in top-left texture space.
            let flipped = topLeftSpace(toReference[i],
                                       srcHeight: Float(frame.extent.height),
                                       dstHeight: Float(refExtent.height))
            var invH = (flipped.inverse) * offsetForTopLeft(offset,
                                                            refHeight: Float(refExtent.height))

            guard let buffer = p.queue.makeCommandBuffer(),
                  let encoder = buffer.makeComputeCommandEncoder() else {
                throw CompositeError.writeFailed
            }
            var proj = Int32(projection.rawValue)
            var canvasCenter = SIMD2<Float>(center.x, Float(canvasH) - center.y)
            var focalCopy = focal
            encoder.setTexture(srcTexture, index: 0)
            encoder.setTexture(accumColor, index: 1)
            encoder.setTexture(accumWeight, index: 2)
            encoder.setBytes(&invH, length: MemoryLayout<simd_float3x3>.size, index: 0)
            encoder.setBytes(&proj, length: 4, index: 1)
            encoder.setBytes(&canvasCenter, length: MemoryLayout<SIMD2<Float>>.size, index: 2)
            encoder.setBytes(&focalCopy, length: 4, index: 3)
            p.dispatch(p.panoWarpAccumulate, encoder: encoder,
                       width: canvasW, height: canvasH)
            encoder.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
        }

        // Resolve (fallback = black where uncovered).
        guard let buffer = p.queue.makeCommandBuffer(),
              let encoder = buffer.makeComputeCommandEncoder() else {
            throw CompositeError.writeFailed
        }
        encoder.setTexture(accumColor, index: 0)
        encoder.setTexture(accumWeight, index: 1)
        encoder.setTexture(accumColor, index: 2)
        encoder.setTexture(output, index: 3)
        p.dispatch(p.weightedResolve, encoder: encoder, width: canvasW, height: canvasH)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()

        job.update(stage: "Computing crop…", progress: 0.92)
        let crop = try autoCrop(accumWeight: accumWeight, pipelines: p,
                                width: canvasW, height: canvasH)

        job.update(stage: "Writing panorama…", progress: 0.96)
        guard let result = p.ciImage(from: output) else { throw CompositeError.writeFailed }
        let name = "Pano-" + (urls.first?.deletingPathExtension().lastPathComponent ?? "Stitch")
        let url = try writeFloatTIFF(result, name: name, into: libraryURL)
        job.update(stage: "Done", progress: 1)
        return PanoramaResult(url: url, suggestedCrop: crop)
    }

    /// Offset matrix converted to top-left space for composition with flipped homographies.
    private func offsetForTopLeft(_ offset: simd_float3x3, refHeight: Float) -> simd_float3x3 {
        let f = simd_float3x3(rows: [
            SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, -1, refHeight), SIMD3<Float>(0, 0, 1)
        ])
        return f * offset * f
    }

    /// Largest well-covered axis-aligned rectangle, found by shrinking rows/columns whose
    /// coverage falls under 98% — a fast, good-enough auto-crop for irregular pano edges.
    private func autoCrop(accumWeight: MTLTexture, pipelines p: CompositePipelines,
                          width: Int, height: Int) throws -> CropSettings? {
        // Downsample the coverage map to the CPU at ~512px for analysis.
        let coverage = try p.makeTexture(width: width, height: height, format: .r32Float,
                                         readWrite: true)
        guard let buffer = p.queue.makeCommandBuffer(),
              let encoder = buffer.makeComputeCommandEncoder() else { return nil }
        encoder.setTexture(accumWeight, index: 0)
        encoder.setTexture(coverage, index: 1)
        p.dispatch(p.coverageMap, encoder: encoder, width: width, height: height)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()

        guard let ci = p.ciImage(from: coverage) else { return nil }
        let scale = 512.0 / Double(max(width, height))
        let small = ci.transformed(by: .init(scaleX: scale, y: scale))
        let e = small.extent.integral
        let w = Int(e.width), h = Int(e.height)
        guard w > 4, h > 4 else { return nil }
        var pixels = [Float](repeating: 0, count: w * h * 4)
        ciContext.render(small, toBitmap: &pixels, rowBytes: w * 16, bounds: e,
                         format: .RGBAf, colorSpace: nil)

        func covered(_ x: Int, _ y: Int) -> Bool { pixels[(y * w + x) * 4] > 0.5 }

        var left = 0, right = w - 1, top = 0, bottom = h - 1
        func rowCoverage(_ y: Int) -> Double {
            var c = 0
            for x in left...right where covered(x, y) { c += 1 }
            return Double(c) / Double(right - left + 1)
        }
        func colCoverage(_ x: Int) -> Double {
            var c = 0
            for y in top...bottom where covered(x, y) { c += 1 }
            return Double(c) / Double(bottom - top + 1)
        }
        // Iteratively trim the worst edge until all edges are ≥98% covered.
        for _ in 0..<(w + h) {
            guard right - left > 8, bottom - top > 8 else { break }
            let edges = [
                ("top", rowCoverage(top)), ("bottom", rowCoverage(bottom)),
                ("left", colCoverage(left)), ("right", colCoverage(right))
            ]
            guard let worst = edges.min(by: { $0.1 < $1.1 }), worst.1 < 0.98 else { break }
            switch worst.0 {
            case "top": top += 1
            case "bottom": bottom -= 1
            case "left": left += 1
            default: right -= 1
            }
        }
        // Normalised top-left crop (CI bitmap row 0 is bottom; flip vertically).
        let cropX = Double(left) / Double(w)
        let cropW = Double(right - left + 1) / Double(w)
        let cropH = Double(bottom - top + 1) / Double(h)
        let cropYFromBottom = Double(top) / Double(h)
        let cropY = 1 - cropYFromBottom - cropH
        guard cropW < 0.999 || cropH < 0.999 else { return nil }
        return CropSettings(x: cropX, y: cropY, width: cropW, height: cropH)
    }
}
