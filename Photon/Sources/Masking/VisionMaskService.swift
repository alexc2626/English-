import Foundation
import Vision
import CoreImage
import CoreML
import PhotonCore

/// Runs the Vision/Core ML segmentation requests behind Photon's AI masks. All requests use
/// `.computeStageDeterministic`-free defaults so Vision schedules them on the Neural Engine
/// where available, keeping masking fast on battery. Results are single-channel CIImages in
/// the coordinate space of the supplied image.
actor VisionMaskService {

    static let shared = VisionMaskService()

    enum MaskError: Error {
        case noSubjectFound
        case noPersonFound(index: Int)
        case noObjectAtSeed
        case skyModelUnavailable
        case visionFailure(Error)
    }

    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Bundled Core ML sky-segmentation model, loaded lazily. Optional: when absent the
    /// heuristic fallback below is used and the UI labels the mask "approximate".
    private var skyModel: VNCoreMLModel?
    private var skyModelLoadAttempted = false

    // MARK: Subject

    /// Select Subject: one-click foreground instance mask.
    func subjectMask(for image: CIImage) throws -> CIImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw MaskError.visionFailure(error)
        }
        guard let observation = request.results?.first else {
            throw MaskError.noSubjectFound
        }
        let buffer = try observation.generateScaledMaskForImage(
            forInstances: observation.allInstances, from: handler)
        return CIImage(cvPixelBuffer: buffer)
    }

    // MARK: Object (point / box seed)

    /// Select Object: instance mask picked by a click point or drag box (normalised,
    /// top-left origin). Falls back to objectness saliency when instance masking finds
    /// nothing at the seed.
    func objectMask(for image: CIImage, seed: ObjectSeed) throws -> CIImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw MaskError.visionFailure(error)
        }
        if let observation = request.results?.first,
           let instances = pickInstances(observation: observation, seed: seed),
           !instances.isEmpty {
            let buffer = try observation.generateScaledMaskForImage(
                forInstances: instances, from: handler)
            return CIImage(cvPixelBuffer: buffer)
        }
        // Fallback: objectness saliency clipped to the seed region.
        return try saliencyMask(for: image, seed: seed)
    }

    /// Read the low-res instance map to find which instance covers the seed.
    private func pickInstances(observation: VNInstanceMaskObservation,
                               seed: ObjectSeed) -> IndexSet? {
        let map = observation.instanceMask
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(map)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        func instance(atX u: Double, y v: Double) -> UInt8 {
            let x = min(max(Int(u * Double(width)), 0), width - 1)
            let y = min(max(Int(v * Double(height)), 0), height - 1)
            return pixels[y * bytesPerRow + x]
        }

        switch seed.seed {
        case .point(let x, let y):
            let label = instance(atX: x, y: y)
            return label > 0 ? IndexSet(integer: Int(label)) : nil
        case .box(let x, let y, let w, let h):
            // Vote across the box; include every instance that covers >10% of samples.
            var counts: [UInt8: Int] = [:]
            let samples = 64
            for i in 0..<samples {
                for j in 0..<samples {
                    let u = x + w * (Double(i) + 0.5) / Double(samples)
                    let v = y + h * (Double(j) + 0.5) / Double(samples)
                    let label = instance(atX: u, y: v)
                    if label > 0 { counts[label, default: 0] += 1 }
                }
            }
            let threshold = samples * samples / 10
            let chosen = counts.filter { $0.value > threshold }.keys.map(Int.init)
            return chosen.isEmpty ? nil : IndexSet(chosen)
        }
    }

    private func saliencyMask(for image: CIImage, seed: ObjectSeed) throws -> CIImage {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else {
            throw MaskError.noObjectAtSeed
        }
        var mask = CIImage(cvPixelBuffer: observation.pixelBuffer)
        // Scale the low-res saliency map up to image space.
        let sx = image.extent.width / mask.extent.width
        let sy = image.extent.height / mask.extent.height
        mask = mask.transformed(by: .init(scaleX: sx, y: sy))
        // Clip to the seed box if one was given.
        if case .box(let x, let y, let w, let h) = seed.seed {
            let e = image.extent
            let rect = CGRect(x: e.minX + x * e.width,
                              y: e.minY + (1 - y - h) * e.height,
                              width: w * e.width, height: h * e.height)
            mask = mask.cropped(to: rect)
        }
        return mask
    }

    // MARK: People

    struct PersonObservationSet {
        var wholePerson: CIImage
        var faceObservations: [VNFaceObservation]
    }

    /// Select People: accurate person segmentation, plus face landmarks for sub-masks.
    /// `personIndex` selects among detected humans ordered left→right (whole-frame
    /// segmentation is shared; instance separation uses human rectangles).
    func personMasks(for image: CIImage, personIndex: Int) throws -> PersonObservationSet {
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .accurate
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let faces = VNDetectFaceLandmarksRequest()
        let humans = VNDetectHumanRectanglesRequest()

        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do {
            try handler.perform([segmentation, faces, humans])
        } catch {
            throw MaskError.visionFailure(error)
        }
        guard let segObservation = segmentation.results?.first else {
            throw MaskError.noPersonFound(index: personIndex)
        }
        var mask = CIImage(cvPixelBuffer: segObservation.pixelBuffer)
        let sx = image.extent.width / mask.extent.width
        let sy = image.extent.height / mask.extent.height
        mask = mask.transformed(by: .init(scaleX: sx, y: sy))

        // Instance separation: clip the shared segmentation to the chosen human's rect
        // (padded), ordered left-to-right for a stable index.
        let rects = (humans.results ?? [])
            .map(\.boundingBox)
            .sorted { $0.minX < $1.minX }
        if rects.indices.contains(personIndex), rects.count > 1 {
            let bb = rects[personIndex]
            let e = image.extent
            let pad = 0.05
            let rect = CGRect(
                x: e.minX + (bb.minX - pad) * e.width,
                y: e.minY + (bb.minY - pad) * e.height,
                width: (bb.width + 2 * pad) * e.width,
                height: (bb.height + 2 * pad) * e.height
            ).intersection(e)
            mask = mask.cropped(to: rect)
        } else if !rects.indices.contains(personIndex), personIndex > 0 {
            throw MaskError.noPersonFound(index: personIndex)
        }

        let sortedFaces = (faces.results ?? []).sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        return PersonObservationSet(wholePerson: mask, faceObservations: sortedFaces)
    }

    // MARK: Sky

    /// Select Sky. Uses a bundled Core ML segmentation model when present (Neural Engine);
    /// otherwise a colour/position heuristic marked approximate.
    func skyMask(for image: CIImage) async throws -> (mask: CIImage, approximate: Bool) {
        if !skyModelLoadAttempted {
            skyModelLoadAttempted = true
            if let url = Bundle.main.url(forResource: "SkySegmentation",
                                         withExtension: "mlmodelc"),
               let ml = try? MLModel(contentsOf: url, configuration: {
                   let config = MLModelConfiguration()
                   config.computeUnits = .all   // prefers ANE
                   return config
               }()),
               let vnModel = try? VNCoreMLModel(for: ml) {
                skyModel = vnModel
            }
        }

        if let skyModel {
            let request = VNCoreMLRequest(model: skyModel)
            request.imageCropAndScaleOption = .scaleFill
            let handler = VNImageRequestHandler(ciImage: image, options: [:])
            try handler.perform([request])
            if let observation = request.results?.first as? VNPixelBufferObservation {
                var mask = CIImage(cvPixelBuffer: observation.pixelBuffer)
                let sx = image.extent.width / mask.extent.width
                let sy = image.extent.height / mask.extent.height
                mask = mask.transformed(by: .init(scaleX: sx, y: sy))
                return (mask, false)
            }
        }
        return (heuristicSkyMask(for: image), true)
    }

    /// Fallback sky heuristic: bright, desaturated-to-blue pixels weighted by vertical
    /// position, then smoothed. Not Lightroom-grade — flagged as approximate in the UI.
    private func heuristicSkyMask(for image: CIImage) -> CIImage {
        let e = image.extent
        // Work at a small size; the raster is blurred and upscaled anyway.
        let targetW: CGFloat = 256
        let scale = targetW / e.width
        let small = image.transformed(by: .init(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(small, from: small.extent) else {
            return CIImage(color: .black).cropped(to: e)
        }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return CIImage(color: .black).cropped(to: e)
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var maskBytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            // CGContext rows are top-down; top of frame = y 0.
            let positionPrior = 1.0 - Double(y) / Double(height)   // favour the top
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Double(pixels[i]) / 255
                let g = Double(pixels[i + 1]) / 255
                let b = Double(pixels[i + 2]) / 255
                let brightness = (r + g + b) / 3
                let blueness = b - max(r, g) * 0.9
                let score = min(max((blueness * 2 + 0.3) * brightness * (0.3 + 0.7 * positionPrior), 0), 1)
                maskBytes[y * width + x] = UInt8(score * 255)
            }
        }
        let data = Data(maskBytes)
        var mask = CIImage(bitmapData: data, bytesPerRow: width,
                           size: CGSize(width: width, height: height),
                           format: .L8, colorSpace: nil)
        mask = mask.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 4])
        let sx = e.width / mask.extent.width
        let sy = e.height / mask.extent.height
        return mask.transformed(by: .init(scaleX: sx, y: sy)).cropped(to: e)
    }

    // MARK: Face-part rasters

    /// Build a raster for a face-landmark region (eyes / lips / teeth), in image space.
    /// The polygons come from VNFaceLandmarks2D; teeth approximate as the inner-lips region.
    nonisolated static func faceRegionRaster(
        faces: [VNFaceObservation], part: PersonMaskOptions.Part,
        extent: CGRect) -> CIImage? {

        let width = Int(min(extent.width, 1024))
        let height = Int(min(extent.height, 1024))
        guard width > 0, height > 0 else { return nil }

        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 1, alpha: 1)

        var drewSomething = false
        for face in faces {
            guard let landmarks = face.landmarks else { continue }
            let regions: [VNFaceLandmarkRegion2D?]
            switch part {
            case .eyes: regions = [landmarks.leftEye, landmarks.rightEye]
            case .lips: regions = [landmarks.outerLips]
            case .teeth: regions = [landmarks.innerLips]
            default: regions = []
            }
            for region in regions.compactMap({ $0 }) {
                let points = region.pointsInImage(imageSize:
                    CGSize(width: width, height: height))
                guard points.count > 2 else { continue }
                ctx.beginPath()
                ctx.move(to: points[0])
                for p in points.dropFirst() { ctx.addLine(to: p) }
                ctx.closePath()
                ctx.fillPath()
                drewSomething = true
            }
        }
        guard drewSomething, let cg = ctx.makeImage() else { return nil }
        var mask = CIImage(cgImage: cg)
        // Slight dilation + blur so the hard polygon feathers naturally.
        mask = mask.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 2])
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 2])
        let sx = extent.width / mask.extent.width
        let sy = extent.height / mask.extent.height
        return mask.transformed(by: .init(scaleX: sx, y: sy))
            .transformed(by: .init(translationX: extent.minX, y: extent.minY))
    }
}
