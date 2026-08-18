import Foundation
import CoreImage
import Metal

/// Loads Photon's custom CIKernels from the app's default metallib (compiled from
/// PhotonKernels.ci.metal with -fcikernel). One shared instance; kernels are immutable
/// and thread-safe to apply.
final class KernelLibrary: @unchecked Sendable {

    static let shared = KernelLibrary()

    // Colour kernels
    let basicTone: CIColorKernel
    let whiteBalance: CIColorKernel
    let vibranceSaturation: CIColorKernel
    let hslRemap: CIColorKernel
    let bwMix: CIColorKernel
    let colorGrade: CIColorKernel
    let detailBoost: CIColorKernel
    let dehaze: CIColorKernel
    let sharpen: CIColorKernel
    let sharpenMaskPreview: CIColorKernel
    let postCropVignette: CIColorKernel
    let filmGrain: CIColorKernel
    let calibration: CIColorKernel
    let defringe: CIColorKernel
    let lensVignette: CIColorKernel
    let localColor: CIColorKernel
    let spotPatch: CIColorKernel

    // Mask kernels
    let maskCombine: CIColorKernel
    let maskInvert: CIColorKernel
    let maskedBlend: CIColorKernel
    let maskOverlay: CIColorKernel
    let luminanceRangeMask: CIColorKernel
    let colorRangeMask: CIColorKernel
    let linearGradientMask: CIColorKernel
    let radialGradientMask: CIColorKernel
    let depthRangeMask: CIColorKernel

    // General/warp kernels
    let toneCurveLUT: CIKernel
    let radialDistortWarp: CIWarpKernel

    private init() {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else {
            fatalError("Photon.metallib missing from bundle — check MTL_COMPILER_FLAGS=-fcikernel")
        }

        func color(_ name: String) -> CIColorKernel {
            guard let k = try? CIColorKernel(functionName: name, fromMetalLibraryData: data) else {
                fatalError("CI kernel \(name) failed to load")
            }
            return k
        }

        basicTone = color("basicTone")
        whiteBalance = color("whiteBalance")
        vibranceSaturation = color("vibranceSaturation")
        hslRemap = color("hslRemap")
        bwMix = color("bwMix")
        colorGrade = color("colorGrade")
        detailBoost = color("detailBoost")
        dehaze = color("dehaze")
        sharpen = color("sharpen")
        sharpenMaskPreview = color("sharpenMaskPreview")
        postCropVignette = color("postCropVignette")
        filmGrain = color("filmGrain")
        calibration = color("calibration")
        defringe = color("defringe")
        lensVignette = color("lensVignette")
        localColor = color("localColor")
        spotPatch = color("spotPatch")

        maskCombine = color("maskCombine")
        maskInvert = color("maskInvert")
        maskedBlend = color("maskedBlend")
        maskOverlay = color("maskOverlay")
        luminanceRangeMask = color("luminanceRangeMask")
        colorRangeMask = color("colorRangeMask")
        linearGradientMask = color("linearGradientMask")
        radialGradientMask = color("radialGradientMask")
        depthRangeMask = color("depthRangeMask")

        guard let curveK = try? CIKernel(functionName: "toneCurveLUT",
                                         fromMetalLibraryData: data) else {
            fatalError("toneCurveLUT kernel failed to load")
        }
        toneCurveLUT = curveK
        guard let warpK = try? CIWarpKernel(functionName: "radialDistortWarp",
                                            fromMetalLibraryData: data) else {
            fatalError("radialDistortWarp kernel failed to load")
        }
        radialDistortWarp = warpK
    }
}
