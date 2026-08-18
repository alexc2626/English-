import SwiftUI
import AppKit
import PhotonCore

/// The develop canvas: an AppKit-backed pixel view with zoom (fit / 1:1 / scroll-wheel),
/// pan, split before/after compare, and a loupe. The preview CGImage comes from the render
/// engine (GPU pipeline, single readback); the layer draws it without further copies.
struct CanvasView: NSViewRepresentable {
    let session: EditSession

    func makeNSView(context: Context) -> CanvasNSView {
        let view = CanvasNSView()
        view.session = session
        return view
    }

    func updateNSView(_ view: CanvasNSView, context: Context) {
        view.session = session
        view.currentImage = session.preview
        view.splitCompare = session.splitCompare
        if view.splitCompare, view.beforeImage == nil {
            view.requestBeforeImage()
        }
        view.needsLayout = true
        view.needsDisplay = true
    }
}

final class CanvasNSView: NSView {

    weak var session: EditSession?

    var currentImage: CGImage? {
        didSet { imageLayer.contents = currentImage }
    }
    var beforeImage: CGImage? {
        didSet { beforeLayer.contents = beforeImage }
    }
    var splitCompare = false {
        didSet {
            beforeLayer.isHidden = !splitCompare
            splitLine.isHidden = !splitCompare
        }
    }

    /// Zoom: nil = fit to view, 1.0 = 1:1 pixels.
    private var zoom: CGFloat? = nil
    private var panOffset = CGPoint.zero

    private let imageLayer = CALayer()
    private let beforeLayer = CALayer()
    private let splitLine = CALayer()
    private let loupeLayer = CALayer()
    private var splitFraction: CGFloat = 0.5

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .linear
        beforeLayer.contentsGravity = .resize
        beforeLayer.isHidden = true
        splitLine.backgroundColor = NSColor.white.withAlphaComponent(0.8).cgColor
        splitLine.isHidden = true
        loupeLayer.isHidden = true
        loupeLayer.borderColor = NSColor.white.cgColor
        loupeLayer.borderWidth = 2
        loupeLayer.cornerRadius = 60
        loupeLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(beforeLayer)
        layer?.addSublayer(splitLine)
        layer?.addSublayer(loupeLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        session?.screenMaxDimension = max(bounds.width, bounds.height) * (window?.backingScaleFactor ?? 2)
        positionLayers()
    }

    private func positionLayers() {
        guard let image = currentImage else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let imageSize = CGSize(width: image.width, height: image.height)
        let scale: CGFloat
        if let zoom {
            scale = zoom / (window?.backingScaleFactor ?? 2)
        } else {
            scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height, 1)
        }
        let displaySize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        var origin = CGPoint(x: (bounds.width - displaySize.width) / 2 + panOffset.x,
                             y: (bounds.height - displaySize.height) / 2 + panOffset.y)
        // Clamp pan so the image can't be pushed fully out of view.
        if displaySize.width > bounds.width {
            origin.x = min(0, max(bounds.width - displaySize.width, origin.x))
        }
        if displaySize.height > bounds.height {
            origin.y = min(0, max(bounds.height - displaySize.height, origin.y))
        }

        let frame = CGRect(origin: origin, size: displaySize)
        imageLayer.frame = frame

        if splitCompare {
            beforeLayer.frame = frame
            // Mask the before layer to the left split.
            let mask = CALayer()
            mask.backgroundColor = NSColor.black.cgColor
            mask.frame = CGRect(x: 0, y: 0, width: displaySize.width * splitFraction,
                                height: displaySize.height)
            beforeLayer.mask = mask
            splitLine.frame = CGRect(x: frame.minX + displaySize.width * splitFraction - 0.5,
                                     y: frame.minY, width: 1, height: displaySize.height)
        }
    }

    func requestBeforeImage() {
        guard let session else { return }
        let url = session.photo.fileURL
        let before = session.beforeSettings
        let maxDim = session.screenMaxDimension
        Task { @MainActor [weak self] in
            let result = await RenderEngine.shared.render(
                photoID: -2, url: url, settings: before,
                quality: .screen(maxDimension: maxDim))
            self?.beforeImage = result?.image
        }
    }

    // MARK: Interaction

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if splitCompare, abs(p.x - splitLine.frame.midX) < 12 {
            draggingSplit = true
            return
        }
        lastDrag = p
    }

    private var draggingSplit = false
    private var lastDrag: CGPoint?

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if draggingSplit {
            let f = imageLayer.frame
            guard f.width > 0 else { return }
            splitFraction = min(max((p.x - f.minX) / f.width, 0.02), 0.98)
            positionLayers()
            return
        }
        if let last = lastDrag, zoom != nil {
            panOffset.x += p.x - last.x
            panOffset.y += p.y - last.y
            positionLayers()
        }
        lastDrag = p
    }

    override func mouseUp(with event: NSEvent) {
        draggingSplit = false
        lastDrag = nil
        if event.clickCount == 2 {
            toggleZoom(at: convert(event.locationInWindow, from: nil))
        }
    }

    /// Double-click toggles fit ↔ 1:1 centred on the click, like Lightroom.
    private func toggleZoom(at point: CGPoint) {
        if zoom == nil {
            zoom = 1.0
            // Centre the clicked image point.
            let f = imageLayer.frame
            if f.width > 0 {
                let u = (point.x - f.minX) / f.width
                let v = (point.y - f.minY) / f.height
                if let image = currentImage {
                    let scale = 1.0 / (window?.backingScaleFactor ?? 2)
                    let dw = CGFloat(image.width) * scale
                    let dh = CGFloat(image.height) * scale
                    panOffset = CGPoint(x: bounds.midX - u * dw - (bounds.width - dw) / 2,
                                        y: bounds.midY - v * dh - (bounds.height - dh) / 2)
                }
            }
            // 1:1 needs the full-res render.
            if let session {
                let url = session.photo.fileURL
                let settings = session.settings
                let id = session.photo.id
                Task { @MainActor [weak self] in
                    let result = await RenderEngine.shared.render(
                        photoID: id, url: url, settings: settings, quality: .full)
                    if let cg = result?.image { self?.currentImage = cg }
                    self?.positionLayers()
                }
            }
        } else {
            zoom = nil
            panOffset = .zero
            session?.requestRender(draft: false)
        }
        positionLayers()
    }

    override func scrollWheel(with event: NSEvent) {
        guard zoom != nil else { return }
        panOffset.x += event.scrollingDeltaX
        panOffset.y += event.scrollingDeltaY
        positionLayers()
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "\\":
            session?.showBefore.toggle()
        case "o", "O":
            // Toggle mask overlay for the active mask (masking panel sets the id).
            if let session, let first = session.settings.masks.first {
                session.overlayMaskID = session.overlayMaskID == nil ? first.id : nil
            }
        default:
            super.keyDown(with: event)
        }
    }
}
