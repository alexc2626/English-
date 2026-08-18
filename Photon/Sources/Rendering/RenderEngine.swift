import Foundation
import CoreImage
import Metal
import AppKit
import PhotonCore

/// GPU render orchestrator. Owns the Metal device + CIContext shared by every canvas and
/// export path, caches decoded sources, and coalesces render requests so slider drags render
/// the newest state only — intermediate requests are dropped, keeping interaction at frame
/// rate while full-quality renders trail behind.
actor RenderEngine {

    static let shared = RenderEngine()

    /// Preview tiers, matching the cache design: cheap drafts while dragging, full-quality
    /// when idle, 1:1/full-res only for zoom and export.
    enum Quality: Sendable {
        /// Fast draft: RAW decoded at reduced scale — used during slider drags.
        case draft(maxDimension: CGFloat)
        /// Fit-to-screen render at display resolution.
        case screen(maxDimension: CGFloat)
        /// Full sensor resolution (1:1 zoom, export).
        case full
    }

    nonisolated let device: MTLDevice
    nonisolated let commandQueue: MTLCommandQueue
    nonisolated let ciContext: CIContext

    /// Wide-gamut linear working space; output converted per destination.
    nonisolated static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    nonisolated static let displaySpace = CGColorSpace(name: CGColorSpace.displayP3)!

    private var pipeline = PipelineBuilder()

    // Decoded-source LRU (CIRAWFilter holds the demosaic; re-creating it per render would
    // re-decode the file).
    private var sourceCache: [URL: RawSource] = [:]
    private var sourceOrder: [URL] = []
    private let sourceCacheLimit = 6

    /// Monotonic generation per photo — a render whose generation is stale by completion
    /// time is discarded before the expensive draw call.
    private var generations: [Int64: UInt64] = [:]

    init() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else {
            fatalError("Metal is required")
        }
        device = dev
        commandQueue = queue
        ciContext = CIContext(mtlCommandQueue: queue, options: [
            .workingColorSpace: Self.workingSpace,
            .workingFormat: CIFormat.RGBAh,          // half-float working format, GPU-resident
            .cacheIntermediates: true,
            .allowLowPower: false,
            .name: "PhotonRenderContext"
        ])
        pipeline.maskProvider = { component, extent in
            MaskRasterizer.shared.raster(for: component, extent: extent)
        }
    }

    /// Install the mask rasteriser (wired by the masking subsystem at startup).
    func setMaskProvider(_ provider: @escaping PipelineBuilder.MaskProvider) {
        pipeline.maskProvider = provider
    }

    // MARK: Source management

    func source(for url: URL) -> RawSource {
        if let cached = sourceCache[url] {
            sourceOrder.removeAll { $0 == url }
            sourceOrder.append(url)
            return cached
        }
        let source = RawSource(url: url)
        sourceCache[url] = source
        sourceOrder.append(url)
        if sourceOrder.count > sourceCacheLimit {
            let evicted = sourceOrder.removeFirst()
            sourceCache[evicted] = nil
        }
        return source
    }

    func invalidateSource(url: URL) {
        sourceCache[url] = nil
        sourceOrder.removeAll { $0 == url }
    }

    // MARK: Rendering

    struct RenderResult: Sendable {
        let image: CGImage
        let fullPixelSize: CGSize
        let generation: UInt64
    }

    /// Render a photo with the given settings. Stale requests (superseded by a newer call for
    /// the same photo) return nil early. The result is a CGImage in display space, produced
    /// entirely on the GPU (single readback into the destination surface).
    func render(photoID: Int64, url: URL, settings: DevelopSettings,
                quality: Quality, overlayMaskID: UUID? = nil) -> RenderResult? {
        let generation = (generations[photoID] ?? 0) &+ 1
        generations[photoID] = generation

        let source = source(for: url)
        guard let fullSize = source.pixelSize else { return nil }

        let scaleHint: Double
        switch quality {
        case .draft(let maxDim):
            scaleHint = min(1, Double(maxDim) / Double(max(fullSize.width, fullSize.height)))
        case .screen(let maxDim):
            // Decode at 2× the target for quality headroom, capped at full res.
            scaleHint = min(1, Double(maxDim * 2) / Double(max(fullSize.width, fullSize.height)))
        case .full:
            scaleHint = 1
        }

        guard let base = source.baseImage(settings: settings, scaleHint: scaleHint) else {
            return nil
        }
        MaskRasterizer.shared.beginRender(image: base, url: url)
        var image = pipeline.build(base: base, settings: settings, isRAW: source.isRAW,
                                   overlayMaskID: overlayMaskID)

        // Scale to the requested output size.
        if case .screen(let maxDim) = quality {
            let scale = min(1, maxDim / max(image.extent.width, image.extent.height))
            if scale < 1 {
                image = image.transformed(by: .init(scaleX: scale, y: scale))
            }
        }
        if case .draft = quality {
            // Draft renders skip the most expensive stages implicitly by low resolution.
        }

        // Drop if a newer request arrived while we built the graph.
        guard generations[photoID] == generation else { return nil }

        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0,
              let cg = ciContext.createCGImage(image, from: extent,
                                               format: .RGBA8,
                                               colorSpace: Self.displaySpace) else {
            return nil
        }
        return RenderResult(image: cg, fullPixelSize: fullSize, generation: generation)
    }

    /// Render the pipeline output as a CIImage for direct Metal canvas drawing (no CGImage
    /// readback). The canvas draws it via CIRenderDestination into its drawable.
    func renderImage(url: URL, settings: DevelopSettings, quality: Quality,
                     overlayMaskID: UUID? = nil) -> CIImage? {
        let source = source(for: url)
        guard let fullSize = source.pixelSize else { return nil }
        let scaleHint: Double
        switch quality {
        case .draft(let maxDim), .screen(let maxDim):
            scaleHint = min(1, Double(maxDim * 2) / Double(max(fullSize.width, fullSize.height)))
        case .full:
            scaleHint = 1
        }
        guard let base = source.baseImage(settings: settings, scaleHint: scaleHint) else {
            return nil
        }
        MaskRasterizer.shared.beginRender(image: base, url: url)
        return pipeline.build(base: base, settings: settings, isRAW: source.isRAW,
                              overlayMaskID: overlayMaskID)
    }

    /// Histogram samples: renders a small thumbnail and returns RGB counts (256 bins each).
    /// Small enough to be cheap; called after edits settle, not per drag tick.
    func histogram(url: URL, settings: DevelopSettings) -> HistogramData? {
        guard let result = render(photoID: -1, url: url, settings: settings,
                                  quality: .draft(maxDimension: 256)) else { return nil }
        return HistogramData(cgImage: result.image)
    }
}

/// 256-bin RGB + luminance histogram computed from a small preview.
struct HistogramData: Sendable {
    var red: [Int]
    var green: [Int]
    var blue: [Int]
    var luminance: [Int]

    init?(cgImage: CGImage) {
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var r = [Int](repeating: 0, count: 256)
        var g = [Int](repeating: 0, count: 256)
        var b = [Int](repeating: 0, count: 256)
        var l = [Int](repeating: 0, count: 256)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let pr = Int(pixels[i]), pg = Int(pixels[i + 1]), pb = Int(pixels[i + 2])
            r[pr] += 1
            g[pg] += 1
            b[pb] += 1
            l[min(255, Int(0.2126 * Double(pr) + 0.7152 * Double(pg) + 0.0722 * Double(pb)))] += 1
        }
        red = r; green = g; blue = b; luminance = l
    }
}
