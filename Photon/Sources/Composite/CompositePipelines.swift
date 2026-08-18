import Foundation
import Metal
import MetalPerformanceShaders
import CoreImage
import simd

/// Compiles and hosts the composite Metal compute kernels (focus stack, HDR, panorama).
/// The kernel source ships as a bundle resource and is compiled once at first use —
/// keeping the compute library independent of the -fcikernel CI library.
final class CompositePipelines {

    enum PipelineError: Error, CustomStringConvertible {
        case sourceMissing
        case compileFailed(String)
        case textureAllocFailed

        var description: String {
            switch self {
            case .sourceMissing: return "CompositeKernels.metal missing from app bundle"
            case .compileFailed(let m): return "Metal compile failed: \(m)"
            case .textureAllocFailed: return "Could not allocate GPU texture"
            }
        }
    }

    let device: MTLDevice
    let queue: MTLCommandQueue

    let sharpnessMeasure: MTLComputePipelineState
    let focusAccumulate: MTLComputePipelineState
    let hdrAccumulate: MTLComputePipelineState
    let weightedResolve: MTLComputePipelineState
    let panoWarpAccumulate: MTLComputePipelineState
    let coverageMap: MTLComputePipelineState
    let homographyWarp: MTLComputePipelineState
    let clearTexture: MTLComputePipelineState

    init(device: MTLDevice, queue: MTLCommandQueue) throws {
        self.device = device
        self.queue = queue

        let url = Bundle.main.url(forResource: "CompositeKernels", withExtension: "metal",
                                  subdirectory: "Shaders")
            ?? Bundle.main.url(forResource: "CompositeKernels", withExtension: "metal")
        guard let url, let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw PipelineError.sourceMissing
        }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw PipelineError.compileFailed(String(describing: error))
        }

        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let fn = library.makeFunction(name: name) else {
                throw PipelineError.compileFailed("missing function \(name)")
            }
            return try device.makeComputePipelineState(function: fn)
        }

        sharpnessMeasure = try pipeline("sharpnessMeasure")
        focusAccumulate = try pipeline("focusAccumulate")
        hdrAccumulate = try pipeline("hdrAccumulate")
        weightedResolve = try pipeline("weightedResolve")
        panoWarpAccumulate = try pipeline("panoWarpAccumulate")
        coverageMap = try pipeline("coverageMap")
        homographyWarp = try pipeline("homographyWarp")
        clearTexture = try pipeline("clearTexture")
    }

    // MARK: Texture helpers

    func makeTexture(width: Int, height: Int, format: MTLPixelFormat = .rgba16Float,
                     readWrite: Bool = false) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        desc.usage = readWrite ? [.shaderRead, .shaderWrite] : [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw PipelineError.textureAllocFailed
        }
        return tex
    }

    /// Render a CIImage into a Metal texture (linear light), staying on the GPU.
    func texture(from image: CIImage, context: CIContext,
                 format: MTLPixelFormat = .rgba16Float) throws -> MTLTexture {
        let extent = image.extent.integral
        let tex = try makeTexture(width: Int(extent.width), height: Int(extent.height),
                                  format: format)
        guard let buffer = queue.makeCommandBuffer() else {
            throw PipelineError.textureAllocFailed
        }
        context.render(image, to: tex, commandBuffer: buffer,
                       bounds: extent,
                       colorSpace: RenderEngine.workingSpace)
        buffer.commit()
        buffer.waitUntilCompleted()
        return tex
    }

    /// Wrap a texture back into CIImage for export through the normal pipeline.
    func ciImage(from texture: MTLTexture) -> CIImage? {
        var image = CIImage(mtlTexture: texture,
                            options: [.colorSpace: RenderEngine.workingSpace])
        // MTLTexture origin is top-left; CIImage expects bottom-left.
        image = image?.oriented(.downMirrored)
        return image
    }

    // MARK: Dispatch helpers

    func dispatch(_ pipeline: MTLComputePipelineState,
                  encoder: MTLComputeCommandEncoder,
                  width: Int, height: Int) {
        encoder.setComputePipelineState(pipeline)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
    }

    /// Gaussian-blur a texture in place (MPS), used to smooth focus decision maps.
    func blur(_ texture: MTLTexture, sigma: Float, commandBuffer: MTLCommandBuffer) {
        let kernel = MPSImageGaussianBlur(device: device, sigma: sigma)
        kernel.edgeMode = .clamp
        var tex: MTLTexture = texture
        kernel.encode(commandBuffer: commandBuffer, inPlaceTexture: &tex, fallbackCopyAllocator: nil)
    }

    /// Zero-fill a float texture with the clearTexture kernel.
    func clear(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setTexture(texture, index: 0)
        dispatch(clearTexture, encoder: encoder, width: texture.width, height: texture.height)
        encoder.endEncoding()
    }
}

// MARK: - simd bridging

extension simd_float3x3 {
    /// Row-major 9-value initialiser (matches Vision's homography alignment matrix layout).
    init(rowMajor m: [Float]) {
        self.init(rows: [
            SIMD3<Float>(m[0], m[1], m[2]),
            SIMD3<Float>(m[3], m[4], m[5]),
            SIMD3<Float>(m[6], m[7], m[8])
        ])
    }
}
