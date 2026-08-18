import SwiftUI
import Observation
import PhotonCore

/// The live editing session for one photo in the Develop module.
///
/// Owns the photo's `EditStack`, publishes the current preview image, and manages the
/// two-speed render loop:
///   - every settings change triggers an immediate *draft* render (low-res, never queued
///     more than one deep — stale drafts are dropped by the engine's generation counter),
///   - a debounced *screen-quality* render follows once the user pauses,
///   - history persistence and thumbnail refresh happen on gesture end, not per tick.
@Observable @MainActor
final class EditSession {

    let photo: PhotoRecord
    private let catalog: CatalogDatabase

    private(set) var stack: EditStack
    /// The settings being edited (may be mid-gesture, ahead of the last history record).
    private(set) var settings: DevelopSettings

    /// Latest rendered preview for the canvas.
    private(set) var preview: CGImage?
    private(set) var previewIsDraft = false
    private(set) var histogram: HistogramData?
    private(set) var unsupportedReason: String?

    /// Before/After: render with the import-state settings instead.
    var showBefore = false { didSet { requestRender(draft: false) } }
    /// Split view compare mode (canvas draws before|after side by side).
    var splitCompare = false
    /// Mask overlay shown on the canvas ("O" key), set by the masking panel.
    var overlayMaskID: UUID? { didSet { requestRender(draft: false) } }

    /// Fit-to-screen target size, updated by the canvas on layout.
    var screenMaxDimension: CGFloat = 1600

    private var renderTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    /// Name of the in-flight gesture (slider label) for history coalescing.
    private var activeGesture: String?

    private var maskObserver: NSObjectProtocol?

    init(photo: PhotoRecord, stack: EditStack, catalog: CatalogDatabase) {
        self.photo = photo
        self.catalog = catalog
        self.stack = stack
        self.settings = stack.current
        // AI mask rasters land asynchronously; re-render when they arrive.
        maskObserver = NotificationCenter.default.addObserver(
            forName: MaskRasterizer.maskRasterDidUpdate, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.requestRender(draft: false) }
        }
        requestRender(draft: false)
    }

    deinit {
        if let maskObserver {
            NotificationCenter.default.removeObserver(maskObserver)
        }
    }

    var beforeSettings: DevelopSettings {
        stack.history.first?.settings ?? DevelopSettings()
    }

    // MARK: Edit entry points

    /// Continuous slider change. `gesture` groups a drag into one history step.
    func update(_ gesture: String, _ mutate: (inout DevelopSettings) -> Void) {
        var s = settings
        mutate(&s)
        guard s != settings else { return }
        settings = s
        if activeGesture == nil {
            activeGesture = gesture
            stack.record(gesture, settings: s)
        } else {
            stack.amend(gesture, settings: s)
        }
        requestRender(draft: true)
        scheduleSettle()
    }

    /// Discrete change (toggle, curve point placement, mask add) — one history step, no
    /// draft pass.
    func apply(name: String, settings newSettings: DevelopSettings) {
        guard newSettings != settings else { return }
        settings = newSettings
        endGesture()
        stack.record(name, settings: newSettings)
        requestRender(draft: false)
        persist()
    }

    /// Called on slider gesture end (mouse up).
    func endGesture() {
        activeGesture = nil
        settleTask?.cancel()
        requestRender(draft: false)
        persist()
    }

    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.activeGesture = nil
            self?.requestRender(draft: false)
            self?.persist()
        }
    }

    // MARK: History / snapshots

    func undo() {
        settings = stack.undo()
        requestRender(draft: false)
        persist()
    }

    func redo() {
        settings = stack.redo()
        requestRender(draft: false)
        persist()
    }

    func jump(to entryID: UUID) {
        stack.jump(to: entryID)
        settings = stack.current
        requestRender(draft: false)
        persist()
    }

    func addSnapshot(named name: String) {
        stack.addSnapshot(named: name)
        persist()
    }

    func restoreSnapshot(_ id: UUID) {
        stack.restoreSnapshot(id)
        settings = stack.current
        requestRender(draft: false)
        persist()
    }

    func reset() {
        stack.reset()
        settings = stack.current
        requestRender(draft: false)
        persist()
    }

    // MARK: Rendering

    func requestRender(draft: Bool) {
        let renderSettings = showBefore ? beforeSettings : settings
        let quality: RenderEngine.Quality = draft
            ? .draft(maxDimension: min(screenMaxDimension, 1024))
            : .screen(maxDimension: screenMaxDimension)
        let url = photo.fileURL
        let id = photo.id
        let overlay = overlayMaskID

        renderTask?.cancel()
        renderTask = Task { [weak self] in
            let result = await RenderEngine.shared.render(
                photoID: id, url: url, settings: renderSettings,
                quality: quality, overlayMaskID: overlay)
            guard let self, let result, !Task.isCancelled else { return }
            self.preview = result.image
            self.previewIsDraft = draft
            if self.unsupportedReason == nil {
                let source = await RenderEngine.shared.source(for: url)
                self.unsupportedReason = source.unsupportedReason
            }
            if !draft {
                self.histogram = await RenderEngine.shared.histogram(
                    url: url, settings: renderSettings)
            }
        }
    }

    // MARK: Persistence

    private func persist() {
        let stackCopy = stack
        let id = photo.id
        let uuid = photo.uuid
        Task.detached(priority: .utility) { [catalog] in
            try? await catalog.saveEditStack(photoID: id, stack: stackCopy)
            _ = uuid  // thumbnail invalidation is handled by the library on module switch
        }
    }
}
