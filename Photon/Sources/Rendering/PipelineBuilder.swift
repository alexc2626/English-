import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import PhotonCore

/// Builds the full develop render graph: a pure function from (base image, DevelopSettings)
/// to a CIImage. Nothing here touches pixels on the CPU — the graph is lazily evaluated by
/// Core Image on the GPU when the render engine draws it.
///
/// Stage order (mirrors Lightroom's processing model, not its panel order):
///   RAW decode (WB, profile, RAW NR/sharpen — inside CIRAWFilter, upstream of this builder)
///   → calibration → WB (non-RAW) → lens manual corrections → transform → crop/straighten
///   → spot removal → basic tone → texture/clarity/dehaze → tone curve → HSL / B&W
///   → color grading → output sharpening for non-RAW → masks (local adjustments)
///   → post-crop vignette → grain
struct PipelineBuilder {

    let kernels = KernelLibrary.shared

    /// Provides rasterised mask coverages (single-channel CIImages, white = selected) for a
    /// mask component in the working image's pixel space. AI components resolve through the
    /// Vision-backed MaskRasterizer; geometric ones rasterise directly. Returning nil skips
    /// the component (e.g. AI mask still computing) — the UI re-renders when it lands.
    typealias MaskProvider = (MaskComponent, CGRect) -> CIImage?

    var maskProvider: MaskProvider?

    // MARK: Entry point

    func build(base: CIImage, settings: DevelopSettings, isRAW: Bool,
               overlayMaskID: UUID? = nil) -> CIImage {
        var image = base

        image = applyCalibration(image, settings.calibration)
        if !isRAW {
            image = applyWhiteBalanceNonRAW(image, settings.basic)
        }
        image = applyManualLens(image, settings.lens)
        image = applyTransform(image, settings.transform)
        image = applyCropStraighten(image, settings.crop)
        image = applySpots(image, settings.spots)
        image = applyBasicTone(image, settings.basic)
        image = applyPresence(image, settings.basic)
        image = applyToneCurve(image, settings.toneCurve)
        if let bw = settings.blackAndWhite {
            image = applyBWMix(image, bw)
        } else {
            image = applyHSL(image, settings.hsl)
        }
        image = applyColorGrading(image, settings.colorGrading)
        if !isRAW {
            image = applyDetail(image, settings.detail)
        } else {
            // RAW NR/base sharpening ran in the decoder; still honour amounts beyond the
            // decoder's range with the post filter for parity with Lightroom's Detail panel.
            image = applyDetail(image, settings.detail, attenuated: true)
        }
        image = applyMasks(image, settings, overlayMaskID: overlayMaskID)
        image = applyEffects(image, settings.effects)

        return image
    }

    // MARK: Stages

    private func applyCalibration(_ image: CIImage, _ c: CalibrationSettings) -> CIImage {
        guard c != CalibrationSettings() else { return image }
        return kernels.calibration.apply(extent: image.extent, arguments: [
            image,
            CIVector(x: c.redHue / 100, y: c.redSaturation / 100),
            CIVector(x: c.greenHue / 100, y: c.greenSaturation / 100),
            CIVector(x: c.blueHue / 100, y: c.blueSaturation / 100),
            c.shadowTint / 100
        ]) ?? image
    }

    private func applyWhiteBalanceNonRAW(_ image: CIImage, _ b: BasicAdjustments) -> CIImage {
        guard !b.whiteBalanceIsAsShot else { return image }
        // Map Kelvin onto a relative shift around D65 for rendered files.
        let temp = (6500 - b.temperature) / 4500 * -1   // warm > 0
        let tint = b.tint / 150
        return kernels.whiteBalance.apply(extent: image.extent,
                                          arguments: [image, temp, tint]) ?? image
    }

    private func applyManualLens(_ image: CIImage, _ l: LensCorrectionSettings) -> CIImage {
        var out = image
        if l.manualDistortion != 0 {
            let extent = out.extent
            let center = CIVector(x: extent.midX, y: extent.midY)
            let normScale = 2.0 / Double(max(extent.width, extent.height))
            let k = l.manualDistortion / 100 * 0.3
            // ROI grows by the max displacement; pad conservatively.
            let pad = abs(k) * Double(max(extent.width, extent.height)) * 0.5
            out = kernels.radialDistortWarp.apply(
                extent: extent,
                roiCallback: { _, rect in rect.insetBy(dx: -pad, dy: -pad) },
                image: out,
                arguments: [center, normScale, k]) ?? out
        }
        if l.purpleFringeAmount > 0 || l.greenFringeAmount > 0 {
            out = kernels.defringe.apply(extent: out.extent, arguments: [
                out, l.purpleFringeAmount / 20, l.greenFringeAmount / 20
            ]) ?? out
        }
        if l.manualVignetteAmount != 0 {
            let e = out.extent
            out = kernels.lensVignette.apply(extent: e, arguments: [
                out, CIVector(cgRect: e), l.manualVignetteAmount / 100,
                l.manualVignetteMidpoint / 100
            ]) ?? out
        }
        if l.removeChromaticAberration {
            // Approximate CA removal: tiny opposing scales on R/B channels.
            out = removeLateralCA(out)
        }
        return out
    }

    private func removeLateralCA(_ image: CIImage) -> CIImage {
        let e = image.extent
        guard e.width > 0 else { return image }
        let scaleR: CGFloat = 1.0005
        let scaleB: CGFloat = 0.9995
        func scaled(_ img: CIImage, _ s: CGFloat) -> CIImage {
            let t = CGAffineTransform(translationX: e.midX, y: e.midY)
                .scaledBy(x: s, y: s)
                .translatedBy(x: -e.midX, y: -e.midY)
            return img.transformed(by: t).cropped(to: e)
        }
        let red = scaled(image, scaleR)
        let blue = scaled(image, scaleB)
        let matrixR = CIFilter.colorMatrix()
        matrixR.inputImage = red
        matrixR.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        matrixR.gVector = .init(x: 0, y: 0, z: 0, w: 0)
        matrixR.bVector = .init(x: 0, y: 0, z: 0, w: 0)
        matrixR.aVector = .init(x: 0, y: 0, z: 0, w: 0)
        let matrixG = CIFilter.colorMatrix()
        matrixG.inputImage = image
        matrixG.rVector = .init(x: 0, y: 0, z: 0, w: 0)
        matrixG.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        matrixG.bVector = .init(x: 0, y: 0, z: 0, w: 0)
        matrixG.aVector = .init(x: 0, y: 0, z: 0, w: 1)
        let matrixB = CIFilter.colorMatrix()
        matrixB.inputImage = blue
        matrixB.rVector = .init(x: 0, y: 0, z: 0, w: 0)
        matrixB.gVector = .init(x: 0, y: 0, z: 0, w: 0)
        matrixB.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        matrixB.aVector = .init(x: 0, y: 0, z: 0, w: 0)
        guard let r = matrixR.outputImage, let g = matrixG.outputImage,
              let b = matrixB.outputImage else { return image }
        let add1 = CIFilter.additionCompositing()
        add1.inputImage = r
        add1.backgroundImage = g
        let add2 = CIFilter.additionCompositing()
        add2.inputImage = add1.outputImage
        add2.backgroundImage = b
        return add2.outputImage?.cropped(to: e) ?? image
    }

    private func applyTransform(_ image: CIImage, _ t: TransformSettings) -> CIImage {
        guard !t.isDefault else { return image }
        let e = image.extent
        var out = image

        // Keystone correction via CIPerspectiveTransform: move the corners opposite to the
        // perceived lean. vertical>0 tilts the top away (converging verticals corrected).
        let v = CGFloat(t.vertical / 100) * e.width * 0.25
        let h = CGFloat(t.horizontal / 100) * e.height * 0.25
        let persp = CIFilter.perspectiveTransform()
        persp.inputImage = out
        persp.topLeft = CGPoint(x: e.minX + v - h * 0, y: e.maxY + h)
        persp.topRight = CGPoint(x: e.maxX - v, y: e.maxY - h)
        persp.bottomLeft = CGPoint(x: e.minX - v, y: e.minY + h)
        persp.bottomRight = CGPoint(x: e.maxX + v, y: e.minY - h)
        out = persp.outputImage ?? out

        // Rotate, aspect, scale, offset as one affine.
        var affine = CGAffineTransform.identity
        let cx = out.extent.midX, cy = out.extent.midY
        affine = affine.translatedBy(x: cx, y: cy)
        affine = affine.rotated(by: CGFloat(t.rotate) * .pi / 180)
        let aspect = CGFloat(t.aspect / 100)
        affine = affine.scaledBy(x: 1 + max(aspect, 0) * 0.5, y: 1 - min(aspect, 0) * -0.5)
        let s = CGFloat(t.scale / 100)
        affine = affine.scaledBy(x: s, y: s)
        affine = affine.translatedBy(x: -cx, y: -cy)
        affine = affine.translatedBy(x: CGFloat(t.offsetX / 100) * e.width,
                                     y: CGFloat(-t.offsetY / 100) * e.height)
        out = out.transformed(by: affine)
        return out.cropped(to: e)
    }

    private func applyCropStraighten(_ image: CIImage, _ crop: CropSettings?) -> CIImage {
        guard let crop else { return image }
        var out = image
        let e = image.extent

        if crop.angle != 0 {
            // Straighten: rotate about the centre, then the crop rect (already sized by the
            // UI to stay inside) selects the final region.
            let rad = CGFloat(-crop.angle) * .pi / 180
            let t = CGAffineTransform(translationX: e.midX, y: e.midY)
                .rotated(by: rad)
                .translatedBy(x: -e.midX, y: -e.midY)
            out = out.transformed(by: t)
        }

        // Normalised (top-left origin) → CI pixel rect (bottom-left origin).
        let rect = CGRect(
            x: e.minX + CGFloat(crop.x) * e.width,
            y: e.minY + (1 - CGFloat(crop.y) - CGFloat(crop.height)) * e.height,
            width: CGFloat(crop.width) * e.width,
            height: CGFloat(crop.height) * e.height
        ).integral
        // Re-origin so downstream stages (vignette) see the crop as the full canvas.
        return out.cropped(to: rect)
            .transformed(by: .init(translationX: -rect.minX, y: -rect.minY))
    }

    private func applySpots(_ image: CIImage, _ spots: [SpotEdit]) -> CIImage {
        guard !spots.isEmpty else { return image }
        var out = image
        let e = image.extent
        let longEdge = max(e.width, e.height)

        // Low-frequency layer shared by all heal spots.
        let blur = CIFilter.gaussianBlur()
        for spot in spots {
            let radius = CGFloat(spot.radius) * longEdge
            let center = CIVector(x: e.minX + CGFloat(spot.x) * e.width,
                                  y: e.minY + (1 - CGFloat(spot.y)) * e.height)
            let dx = CGFloat(spot.sourceX - spot.x) * e.width
            let dy = -CGFloat(spot.sourceY - spot.y) * e.height
            let shifted = out.transformed(by: .init(translationX: -dx, y: -dy))
                .clampedToExtent()

            blur.inputImage = out.clampedToExtent()
            blur.radius = Float(radius / 2)
            let low = (blur.outputImage ?? out).cropped(to: e)
            blur.inputImage = shifted
            let lowShifted = (blur.outputImage ?? shifted).cropped(to: e)

            out = kernels.spotPatch.apply(extent: e, arguments: [
                out, shifted.cropped(to: e), low, lowShifted,
                center, radius, spot.feather / 100, spot.opacity / 100,
                spot.mode == .heal ? 1.0 : 0.0
            ]) ?? out
        }
        return out
    }

    private func applyBasicTone(_ image: CIImage, _ b: BasicAdjustments) -> CIImage {
        guard b.exposure != 0 || b.contrast != 0 || b.highlights != 0 || b.shadows != 0
                || b.whites != 0 || b.blacks != 0 else { return image }
        return kernels.basicTone.apply(extent: image.extent, arguments: [
            image, b.exposure, b.contrast / 100,
            b.highlights / 100, b.shadows / 100, b.whites / 100, b.blacks / 100
        ]) ?? image
    }

    private func applyPresence(_ image: CIImage, _ b: BasicAdjustments) -> CIImage {
        var out = image
        let e = image.extent

        if b.texture != 0 || b.clarity != 0 {
            let small = CIFilter.gaussianBlur()
            small.inputImage = out.clampedToExtent()
            small.radius = 3
            let large = CIFilter.gaussianBlur()
            large.inputImage = out.clampedToExtent()
            large.radius = 30
            if let s = small.outputImage?.cropped(to: e),
               let l = large.outputImage?.cropped(to: e) {
                out = kernels.detailBoost.apply(extent: e, arguments: [
                    out, s, l, b.texture / 100, b.clarity / 100
                ]) ?? out
            }
        }

        if b.dehaze != 0 {
            // Local dark channel: min-filter then blur, all GPU.
            let minFilter = CIFilter.morphologyMinimum()
            minFilter.inputImage = out.clampedToExtent()
            minFilter.radius = 15
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = minFilter.outputImage
            blur.radius = 20
            if let minBlur = blur.outputImage?.cropped(to: e) {
                out = kernels.dehaze.apply(extent: e, arguments: [
                    out, minBlur, b.dehaze / 100,
                    CIVector(x: 1.0, y: 1.0, z: 1.0)
                ]) ?? out
            }
        }

        if b.vibrance != 0 || b.saturation != 0 {
            out = kernels.vibranceSaturation.apply(extent: e, arguments: [
                out, b.vibrance / 100, b.saturation / 100
            ]) ?? out
        }
        return out
    }

    private func applyToneCurve(_ image: CIImage, _ tc: ToneCurveSettings) -> CIImage {
        guard tc != ToneCurveSettings() else { return image }
        let lutImage = Self.lutStrip(for: tc)
        let size = ToneCurveEvaluator.lutSize
        return kernels.toneCurveLUT.apply(
            extent: image.extent,
            roiCallback: { index, rect in
                index == 1 ? CGRect(x: 0, y: 0, width: size, height: 4) : rect
            },
            arguments: [image, lutImage, Float(size)]) ?? image
    }

    /// 1024×4 float strip: row 0 composite curve, rows 1–3 per-channel curves.
    /// Cached by settings value — slider drags hit the cache for unchanged curves.
    static func lutStrip(for settings: ToneCurveSettings) -> CIImage {
        lutCacheLock.lock()
        defer { lutCacheLock.unlock() }
        if let cached = lutCache.first(where: { $0.0 == settings }) {
            return cached.1
        }
        let size = ToneCurveEvaluator.lutSize
        let composite = ToneCurveEvaluator.compositeLUT(settings: settings, size: size)
        let channels = ToneCurveEvaluator.channelLUTs(settings: settings, size: size)
        var pixels = [Float]()
        pixels.reserveCapacity(size * 4)
        pixels.append(contentsOf: composite)
        pixels.append(contentsOf: channels.red)
        pixels.append(contentsOf: channels.green)
        pixels.append(contentsOf: channels.blue)
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: data, bytesPerRow: size * MemoryLayout<Float>.size,
                            size: CGSize(width: size, height: 4),
                            format: .Lf, colorSpace: nil)
        lutCache.append((settings, image))
        if lutCache.count > 8 { lutCache.removeFirst() }
        return image
    }
    private static var lutCache: [(ToneCurveSettings, CIImage)] = []
    private static let lutCacheLock = NSLock()

    private func applyHSL(_ image: CIImage, _ hsl: HSLAdjustments) -> CIImage {
        guard !hsl.isDefault else { return image }
        func vec(_ dict: [ColorBand: Double], _ bands: [ColorBand]) -> CIVector {
            CIVector(x: CGFloat((dict[bands[0]] ?? 0) / 100),
                     y: CGFloat((dict[bands[1]] ?? 0) / 100),
                     z: CGFloat((dict[bands[2]] ?? 0) / 100),
                     w: CGFloat((dict[bands[3]] ?? 0) / 100))
        }
        let a: [ColorBand] = [.red, .orange, .yellow, .green]
        let b: [ColorBand] = [.aqua, .blue, .purple, .magenta]
        return kernels.hslRemap.apply(extent: image.extent, arguments: [
            image,
            vec(hsl.hue, a), vec(hsl.hue, b),
            vec(hsl.saturation, a), vec(hsl.saturation, b),
            vec(hsl.luminance, a), vec(hsl.luminance, b)
        ]) ?? image
    }

    private func applyBWMix(_ image: CIImage, _ bw: BlackAndWhiteMix) -> CIImage {
        func vec(_ bands: [ColorBand]) -> CIVector {
            CIVector(x: CGFloat((bw.mix[bands[0]] ?? 0) / 100),
                     y: CGFloat((bw.mix[bands[1]] ?? 0) / 100),
                     z: CGFloat((bw.mix[bands[2]] ?? 0) / 100),
                     w: CGFloat((bw.mix[bands[3]] ?? 0) / 100))
        }
        return kernels.bwMix.apply(extent: image.extent, arguments: [
            image, vec([.red, .orange, .yellow, .green]), vec([.aqua, .blue, .purple, .magenta])
        ]) ?? image
    }

    private func applyColorGrading(_ image: CIImage, _ g: ColorGradingSettings) -> CIImage {
        guard g != ColorGradingSettings() else { return image }
        func off(_ w: ColorGradingSettings.Wheel) -> CIVector {
            let o = ColorGradingMath.wheelOffset(w)
            return CIVector(x: o.r, y: o.g, z: o.b, w: o.lum)
        }
        return kernels.colorGrade.apply(extent: image.extent, arguments: [
            image, off(g.shadows), off(g.midtones), off(g.highlights), off(g.global),
            g.blending / 100, g.balance / 100
        ]) ?? image
    }

    private func applyDetail(_ image: CIImage, _ d: DetailSettings,
                             attenuated: Bool = false) -> CIImage {
        var out = image
        let e = image.extent
        let factor = attenuated ? 0.35 : 1.0   // RAW already sharpened/denoised in decode

        if d.sharpeningAmount > 0 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = out.clampedToExtent()
            blur.radius = Float(d.sharpeningRadius)
            // Edge energy for masking: gradient magnitude approximated by
            // |image − blur| on luminance, spread slightly.
            let edges = CIFilter.gaussianBlur()
            if let blurred = blur.outputImage?.cropped(to: e) {
                let diff = out.applyingFilter("CIDifferenceBlendMode",
                                              parameters: [kCIInputBackgroundImageKey: blurred])
                edges.inputImage = diff.clampedToExtent()
                edges.radius = 2
                let edgeEnergy = edges.outputImage?.cropped(to: e) ?? diff
                out = kernels.sharpen.apply(extent: e, arguments: [
                    out, blurred, edgeEnergy,
                    d.sharpeningAmount / 150 * factor,
                    d.sharpeningDetail / 100,
                    d.sharpeningMasking / 100
                ]) ?? out
            }
        }

        if !attenuated && (d.luminanceNR > 0 || d.colorNR > 0) {
            let nr = CIFilter.noiseReduction()
            nr.inputImage = out
            nr.noiseLevel = Float(d.luminanceNR / 100 * 0.1)
            nr.sharpness = Float(1 - d.luminanceNR / 100 * 0.5)
            out = nr.outputImage ?? out
        }
        return out
    }

    // MARK: Masks

    private func applyMasks(_ image: CIImage, _ settings: DevelopSettings,
                            overlayMaskID: UUID?) -> CIImage {
        guard !settings.masks.isEmpty else { return image }
        var out = image
        let e = image.extent

        for mask in settings.masks where mask.enabled {
            guard let coverage = rasterise(mask: mask, extent: e) else { continue }
            if !mask.adjustments.isDefault {
                let adjusted = applyLocalAdjustments(out, mask.adjustments)
                let amount = max(mask.adjustments.amount, 0) / 100
                out = kernels.maskedBlend.apply(extent: e, arguments: [
                    out, adjusted, coverage, amount
                ]) ?? out
            }
            if mask.id == overlayMaskID {
                out = kernels.maskOverlay.apply(extent: e, arguments: [
                    out, coverage, 1.0
                ]) ?? out
            }
        }
        return out
    }

    /// Combine a mask's components into a single coverage raster.
    func rasterise(mask: PhotonMask, extent: CGRect) -> CIImage? {
        var acc: CIImage? = nil
        var started = false
        for comp in mask.components {
            guard var raster = maskProvider?(comp, extent) else { continue }
            if comp.feather > 0 {
                let blur = CIFilter.gaussianBlur()
                blur.inputImage = raster.clampedToExtent()
                blur.radius = Float(comp.feather / 100 * Double(max(extent.width, extent.height)) * 0.02)
                raster = blur.outputImage?.cropped(to: extent) ?? raster
            }
            let base = acc ?? CIImage(color: .black).cropped(to: extent)
            acc = kernels.maskCombine.apply(extent: extent, arguments: [
                base, raster,
                comp.mode == .add ? 0.0 : (comp.mode == .subtract ? 1.0 : 2.0),
                comp.inverted ? 1.0 : 0.0,
                started ? 1.0 : 0.0
            ]) ?? base
            if comp.mode != .subtract { started = true }
        }
        guard var result = acc else { return nil }
        if mask.inverted {
            result = kernels.maskInvert.apply(extent: extent, arguments: [result]) ?? result
        }
        return result
    }

    /// The masked-region version of the image: the mask's sliders applied globally; the
    /// maskedBlend kernel then lerps by coverage.
    private func applyLocalAdjustments(_ image: CIImage, _ a: LocalAdjustments) -> CIImage {
        var out = image
        let e = image.extent

        if a.exposure != 0 || a.contrast != 0 || a.highlights != 0 || a.shadows != 0
            || a.whites != 0 || a.blacks != 0 {
            out = kernels.basicTone.apply(extent: e, arguments: [
                out, a.exposure, a.contrast / 100, a.highlights / 100,
                a.shadows / 100, a.whites / 100, a.blacks / 100
            ]) ?? out
        }
        if a.texture != 0 || a.clarity != 0 {
            let small = CIFilter.gaussianBlur()
            small.inputImage = out.clampedToExtent()
            small.radius = 3
            let large = CIFilter.gaussianBlur()
            large.inputImage = out.clampedToExtent()
            large.radius = 30
            if let s = small.outputImage?.cropped(to: e),
               let l = large.outputImage?.cropped(to: e) {
                out = kernels.detailBoost.apply(extent: e, arguments: [
                    out, s, l, a.texture / 100, a.clarity / 100
                ]) ?? out
            }
        }
        if a.dehaze != 0 {
            let minFilter = CIFilter.morphologyMinimum()
            minFilter.inputImage = out.clampedToExtent()
            minFilter.radius = 15
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = minFilter.outputImage
            blur.radius = 20
            if let minBlur = blur.outputImage?.cropped(to: e) {
                out = kernels.dehaze.apply(extent: e, arguments: [
                    out, minBlur, a.dehaze / 100, CIVector(x: 1, y: 1, z: 1)
                ]) ?? out
            }
        }
        if a.temperature != 0 || a.tint != 0 || a.hueShift != 0 || a.saturation != 0 {
            out = kernels.localColor.apply(extent: e, arguments: [
                out, a.temperature / 100, a.tint / 100, a.hueShift / 100, a.saturation / 100
            ]) ?? out
        }
        if a.sharpness > 0 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = out.clampedToExtent()
            blur.radius = 1.5
            if let blurred = blur.outputImage?.cropped(to: e) {
                out = kernels.sharpen.apply(extent: e, arguments: [
                    out, blurred, blurred, a.sharpness / 100, 0.5, 0.0
                ]) ?? out
            }
        } else if a.sharpness < 0 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = out.clampedToExtent()
            blur.radius = Float(-a.sharpness / 100 * 4)
            out = blur.outputImage?.cropped(to: e) ?? out
        }
        if a.noise > 0 {
            let nr = CIFilter.noiseReduction()
            nr.inputImage = out
            nr.noiseLevel = Float(a.noise / 100 * 0.1)
            nr.sharpness = 0.7
            out = nr.outputImage ?? out
        }
        if a.defringe > 0 {
            out = kernels.defringe.apply(extent: e, arguments: [
                out, a.defringe / 100, a.defringe / 100
            ]) ?? out
        }
        return out
    }

    private func applyEffects(_ image: CIImage, _ fx: EffectsSettings) -> CIImage {
        var out = image
        let e = image.extent
        if fx.vignetteAmount != 0 {
            out = kernels.postCropVignette.apply(extent: e, arguments: [
                out, CIVector(cgRect: e),
                fx.vignetteAmount / 100, fx.vignetteMidpoint / 100,
                fx.vignetteRoundness / 100, fx.vignetteFeather / 100,
                fx.vignetteHighlights / 100
            ]) ?? out
        }
        if fx.grainAmount > 0 {
            out = kernels.filmGrain.apply(extent: e, arguments: [
                out, fx.grainAmount / 100,
                1 + fx.grainSize / 100 * 5,   // cell size in pixels
                fx.grainRoughness / 100,
                7.0                            // stable seed → grain doesn't shimmer per frame
            ]) ?? out
        }
        return out
    }
}
