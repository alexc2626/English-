import Foundation
import CoreImage
import Vision
import PhotonCore

/// Turns `MaskComponent` instructions into coverage rasters (single-channel CIImages) for
/// the pipeline. Geometric masks rasterise synchronously with GPU kernels; AI masks resolve
/// asynchronously through VisionMaskService and are cached — while computing, the provider
/// returns nil for that component and posts `maskRasterDidUpdate` when the raster lands so
/// the edit session re-renders.
///
/// Masks are cached against the *source* pixel space and rescaled to whatever working
/// resolution the pipeline is rendering, so they stay resolution-independent like the
/// instruction data they come from.
final class MaskRasterizer: @unchecked Sendable {

    static let shared = MaskRasterizer()
    static let maskRasterDidUpdate = Notification.Name("MaskRasterizerDidUpdate")

    private let kernels = KernelLibrary.shared
    private let lock = NSLock()

    /// The image currently being rendered (set per render by the engine) — needed for
    /// image-dependent masks (colour/luminance range, brush auto-mask).
    private var currentImage: CIImage?
    private var currentURL: URL?

    /// Cached AI rasters keyed by component identity + source URL.
    private var aiCache: [String: CIImage] = [:]
    /// Components whose AI computation is in flight (avoid duplicate requests).
    private var inFlight: Set<String> = []
    /// Cached brush rasters keyed by stroke-content hash.
    private var brushCache: [Int: CIImage] = [:]

    /// Install as the render engine's mask provider and set per-render context.
    func beginRender(image: CIImage, url: URL) {
        lock.lock()
        currentImage = image
        currentURL = url
        lock.unlock()
    }

    func invalidate(url: URL) {
        lock.lock()
        let prefix = url.absoluteString
        aiCache = aiCache.filter { !$0.key.hasPrefix(prefix) }
        lock.unlock()
    }

    // MARK: Provider

    /// PipelineBuilder.MaskProvider entry point. Must be synchronous; AI masks return their
    /// cached raster or nil while computing.
    func raster(for component: MaskComponent, extent: CGRect) -> CIImage? {
        switch component.kind {
        case .linearGradient(let g):
            return kernels.linearGradientMask.apply(extent: extent, arguments: [
                CIVector(x: extent.minX + g.startX * extent.width,
                         y: extent.minY + (1 - g.startY) * extent.height),
                CIVector(x: extent.minX + g.endX * extent.width,
                         y: extent.minY + (1 - g.endY) * extent.height)
            ])
        case .radialGradient(let g):
            return kernels.radialGradientMask.apply(extent: extent, arguments: [
                CIVector(x: extent.minX + g.centerX * extent.width,
                         y: extent.minY + (1 - g.centerY) * extent.height),
                CIVector(x: g.radiusX * extent.width, y: g.radiusY * extent.height),
                g.rotation * .pi / 180,
                max(g.feather / 100, 0.001)
            ])
        case .luminanceRange(let r):
            guard let image = snapshotImage() else { return nil }
            return kernels.luminanceRangeMask.apply(extent: extent, arguments: [
                image, r.low, r.high, r.smoothness
            ])
        case .colorRange(let c):
            guard let image = snapshotImage() else { return nil }
            var vectors = c.samples.prefix(5).map {
                CIVector(x: $0.r, y: $0.g, z: $0.b, w: 1)
            }
            while vectors.count < 5 {
                vectors.append(CIVector(x: 0, y: 0, z: 0, w: -1))
            }
            let width = 0.05 + (c.refine / 100) * 0.45
            return kernels.colorRangeMask.apply(extent: extent, arguments: [
                image, vectors[0], vectors[1], vectors[2], vectors[3], vectors[4], width
            ])
        case .depthRange(let d):
            guard let url = snapshotURL(),
                  let depth = RawSource.depthImage(url: url) else { return nil }
            let scaled = scaleToFill(depth, extent: extent)
            return kernels.depthRangeMask.apply(extent: extent, arguments: [
                scaled, d.near, d.far, d.smoothness
            ])
        case .brush(let brush):
            return brushRaster(brush, extent: extent)
        case .subject, .sky, .person, .object:
            return aiRaster(for: component, extent: extent)
        }
    }

    private func snapshotImage() -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        return currentImage
    }

    private func snapshotURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return currentURL
    }

    // MARK: Brush

    private func brushRaster(_ brush: BrushMask, extent: CGRect) -> CIImage? {
        guard !brush.strokes.isEmpty else { return nil }
        var hasher = Hasher()
        for stroke in brush.strokes {
            hasher.combine(stroke.isEraser)
            hasher.combine(stroke.radius)
            hasher.combine(stroke.flow)
            hasher.combine(stroke.density)
            hasher.combine(stroke.feather)
            hasher.combine(stroke.dabs.count)
            if let first = stroke.dabs.first { hasher.combine(first.x); hasher.combine(first.y) }
            if let last = stroke.dabs.last { hasher.combine(last.x); hasher.combine(last.y) }
        }
        hasher.combine(Int(extent.width))
        let key = hasher.finalize()

        lock.lock()
        if let cached = brushCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Rasterise strokes into a grayscale bitmap at a bounded resolution.
        let maxDim: CGFloat = 2048
        let scale = min(1, maxDim / max(extent.width, extent.height))
        let width = max(Int(extent.width * scale), 8)
        let height = max(Int(extent.height * scale), 8)
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let longEdge = CGFloat(max(width, height))
        for stroke in brush.strokes {
            let radius = CGFloat(stroke.radius) * longEdge
            let alpha = CGFloat(stroke.flow / 100) * CGFloat(stroke.density / 100)
            ctx.setBlendMode(stroke.isEraser ? .destinationOut : .normal)
            for dab in stroke.dabs {
                let cx = CGFloat(dab.x) * CGFloat(width)
                let cy = (1 - CGFloat(dab.y)) * CGFloat(height)   // CG bottom-left origin
                let r = radius * CGFloat(0.5 + dab.pressure * 0.5)
                // Feathered dab: radial gradient from full alpha to zero.
                let inner = r * CGFloat(1 - stroke.feather / 100)
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                             colors: [
                                                CGColor(gray: 1, alpha: alpha),
                                                CGColor(gray: 1, alpha: alpha),
                                                CGColor(gray: 1, alpha: 0)
                                             ] as CFArray,
                                             locations: [0, inner / max(r, 1), 1]) {
                    ctx.drawRadialGradient(gradient,
                                           startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                                           endCenter: CGPoint(x: cx, y: cy), endRadius: r,
                                           options: [])
                }
            }
        }
        ctx.setBlendMode(.normal)
        guard let cg = ctx.makeImage() else { return nil }
        var raster = CIImage(cgImage: cg)
        raster = scaleToFill(raster, extent: extent)

        // Auto-mask: constrain the stroke to colours similar to the first dab's colour.
        if let autoStroke = brush.strokes.first(where: { $0.autoMask }),
           let firstDab = autoStroke.dabs.first,
           let image = snapshotImage() {
            let sampleColor = averageColor(of: image, atNormalizedX: firstDab.x, y: firstDab.y)
            if let sample = sampleColor {
                let similar = kernels.colorRangeMask.apply(extent: extent, arguments: [
                    image,
                    CIVector(x: sample.r, y: sample.g, z: sample.b, w: 1),
                    CIVector(x: 0, y: 0, z: 0, w: -1), CIVector(x: 0, y: 0, z: 0, w: -1),
                    CIVector(x: 0, y: 0, z: 0, w: -1), CIVector(x: 0, y: 0, z: 0, w: -1),
                    0.35
                ])
                if let similar {
                    raster = kernels.maskCombine.apply(extent: extent, arguments: [
                        raster, similar, 2.0, 0.0, 1.0   // intersect
                    ]) ?? raster
                }
            }
        }

        lock.lock()
        brushCache[key] = raster
        if brushCache.count > 24 { brushCache.removeAll() }
        lock.unlock()
        return raster
    }

    /// Small CPU sample of the image around a normalised point (for brush auto-mask).
    private func averageColor(of image: CIImage, atNormalizedX x: Double, y: Double)
        -> (r: Double, g: Double, b: Double)? {
        let e = image.extent
        let px = e.minX + CGFloat(x) * e.width
        let py = e.minY + (1 - CGFloat(y)) * e.height
        let region = CGRect(x: px - 4, y: py - 4, width: 8, height: 8).intersection(e)
        guard !region.isEmpty else { return nil }
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let avg = image.applyingFilter("CIAreaAverage",
                                       parameters: [kCIInputExtentKey: CIVector(cgRect: region)])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(avg, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    // MARK: AI masks

    private func aiRaster(for component: MaskComponent, extent: CGRect) -> CIImage? {
        guard let url = snapshotURL() else { return nil }
        let key = cacheKey(url: url, component: component)

        lock.lock()
        if let cached = aiCache[key] {
            lock.unlock()
            return scaleToFill(cached, extent: extent)
        }
        let alreadyRunning = inFlight.contains(key)
        if !alreadyRunning { inFlight.insert(key) }
        guard let image = currentImage else {
            lock.unlock()
            return nil
        }
        lock.unlock()
        guard !alreadyRunning else { return nil }

        let kind = component.kind
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var raster: CIImage?
            do {
                switch kind {
                case .subject:
                    raster = try await VisionMaskService.shared.subjectMask(for: image)
                case .sky:
                    raster = try await VisionMaskService.shared.skyMask(for: image).mask
                case .object(let seed):
                    raster = try await VisionMaskService.shared.objectMask(for: image, seed: seed)
                case .person(let options):
                    raster = try await self.personRaster(image: image, options: options)
                default:
                    break
                }
            } catch {
                NSLog("AI mask failed: \(error)")
            }
            self.lock.lock()
            self.inFlight.remove(key)
            if let raster {
                self.aiCache[key] = raster
                if self.aiCache.count > 32 { self.aiCache.removeAll() }
            }
            self.lock.unlock()
            if raster != nil {
                NotificationCenter.default.post(name: Self.maskRasterDidUpdate, object: nil)
            }
        }
        return nil
    }

    /// Person masks with Lightroom-style sub-part selection.
    private func personRaster(image: CIImage, options: PersonMaskOptions) async throws -> CIImage {
        let result = try await VisionMaskService.shared.personMasks(
            for: image, personIndex: options.personIndex)
        let extent = image.extent
        let person = result.wholePerson

        if options.parts.contains(.entirePerson) || options.parts.isEmpty {
            return person
        }

        var combined: CIImage?
        func union(_ raster: CIImage?) {
            guard let raster else { return }
            if let existing = combined {
                combined = kernels.maskCombine.apply(extent: extent, arguments: [
                    existing, raster, 0.0, 0.0, 1.0   // add
                ]) ?? existing
            } else {
                combined = raster
            }
        }

        // Face-landmark parts.
        for part in [PersonMaskOptions.Part.eyes, .lips, .teeth]
        where options.parts.contains(part) {
            union(VisionMaskService.faceRegionRaster(
                faces: result.faceObservations, part: part, extent: extent))
        }

        // Region-heuristic parts derived from the person silhouette + face boxes:
        //   skin ≈ person ∩ face/neck+hands regions; hair ≈ top band above the face;
        //   clothing ≈ person − (face ∪ hair). These follow Lightroom's part taxonomy with
        //   documented approximation where Vision offers no per-part segmentation.
        if let face = result.faceObservations.first {
            let bb = face.boundingBox   // normalised, bottom-left origin
            let faceRect = CGRect(x: extent.minX + bb.minX * extent.width,
                                  y: extent.minY + bb.minY * extent.height,
                                  width: bb.width * extent.width,
                                  height: bb.height * extent.height)
            if options.parts.contains(.skin) {
                let skinRegion = faceRect.insetBy(dx: -faceRect.width * 0.15,
                                                  dy: -faceRect.height * 0.25)
                union(person.cropped(to: skinRegion.intersection(extent)))
            }
            if options.parts.contains(.hair) {
                let hairRegion = CGRect(x: faceRect.minX - faceRect.width * 0.25,
                                        y: faceRect.maxY - faceRect.height * 0.2,
                                        width: faceRect.width * 1.5,
                                        height: faceRect.height * 0.9)
                union(person.cropped(to: hairRegion.intersection(extent)))
            }
            if options.parts.contains(.clothing) {
                // Person minus the head region.
                let headRegion = faceRect.insetBy(dx: -faceRect.width * 0.3,
                                                  dy: -faceRect.height * 0.4)
                let headMask = CIImage(color: .white).cropped(to: headRegion.intersection(extent))
                    .composited(over: CIImage(color: .black).cropped(to: extent))
                union(kernels.maskCombine.apply(extent: extent, arguments: [
                    person, headMask, 1.0, 0.0, 1.0   // subtract head
                ]))
            }
        } else if options.parts.contains(.clothing) || options.parts.contains(.skin) {
            union(person)   // no face found: fall back to the whole silhouette
        }

        return combined ?? person
    }

    private func cacheKey(url: URL, component: MaskComponent) -> String {
        var suffix = ""
        switch component.kind {
        case .subject: suffix = "subject"
        case .sky: suffix = "sky"
        case .object(let seed):
            switch seed.seed {
            case .point(let x, let y): suffix = "object-\(x)-\(y)"
            case .box(let x, let y, let w, let h): suffix = "object-\(x)-\(y)-\(w)-\(h)"
            }
        case .person(let options):
            suffix = "person-\(options.personIndex)-\(options.parts.map(\.rawValue).sorted().joined(separator: ","))"
        default: break
        }
        return "\(url.absoluteString)#\(suffix)"
    }

    // MARK: Helpers

    private func scaleToFill(_ image: CIImage, extent: CGRect) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        let sx = extent.width / e.width
        let sy = extent.height / e.height
        return image
            .transformed(by: .init(scaleX: sx, y: sy))
            .transformed(by: .init(translationX: extent.minX - e.minX * sx,
                                   y: extent.minY - e.minY * sy))
            .cropped(to: extent)
    }
}
