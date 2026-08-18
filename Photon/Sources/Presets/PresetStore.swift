import SwiftUI
import Observation
import PhotonCore

/// Preset management: catalog-backed storage, group organisation, XMP import/export, and
/// live hover previews (small renders of the current photo with the preset applied).
@Observable @MainActor
final class PresetStore {

    private let catalog: CatalogDatabase
    private(set) var presets: [DevelopPreset] = []

    /// Hover-preview cache: preset id → preview CGImage for the current photo.
    private var previewCache: [UUID: CGImage] = [:]
    private var previewPhotoID: Int64?

    init(catalog: CatalogDatabase) {
        self.catalog = catalog
        Task { await reload() }
    }

    func reload() async {
        presets = (try? await catalog.presets()) ?? []
    }

    var groups: [String] {
        var seen = Set<String>()
        return presets.map(\.group).filter { seen.insert($0).inserted }
    }

    func presets(in group: String) -> [DevelopPreset] {
        presets.filter { $0.group == group }.sorted { $0.name < $1.name }
    }

    // MARK: Save / delete

    func saveCurrent(name: String, group: String, subset: SettingsSubset,
                     settings: DevelopSettings) async {
        let preset = DevelopPreset(name: name, group: group, subset: subset,
                                   settings: settings)
        try? await catalog.savePreset(preset)
        await reload()
    }

    func delete(_ preset: DevelopPreset) async {
        try? await catalog.deletePreset(id: preset.id)
        previewCache[preset.id] = nil
        await reload()
    }

    // MARK: XMP import / export

    /// Import .xmp preset files (Photon's own or Lightroom-style packs).
    func importXMPFiles(_ urls: [URL]) async -> (imported: Int, failed: Int) {
        var imported = 0, failed = 0
        for url in urls {
            guard let xml = try? String(contentsOf: url, encoding: .utf8) else {
                failed += 1
                continue
            }
            do {
                var preset = try PresetXMP.parse(xml)
                if preset.group.isEmpty { preset.group = "Imported" }
                try? await catalog.savePreset(preset)
                imported += 1
            } catch {
                failed += 1
            }
        }
        await reload()
        return (imported, failed)
    }

    func exportXMP(_ preset: DevelopPreset, to directory: URL) throws {
        let xml = try PresetXMP.serialize(preset)
        let safeName = preset.name.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent("\(safeName).xmp")
        try xml.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Hover previews

    /// Small render of `photo` with `preset` applied, cached per photo. Called on hover;
    /// completes asynchronously and re-fires the view via the published cache.
    func preview(for preset: DevelopPreset, photo: PhotoRecord) -> CGImage? {
        if previewPhotoID != photo.id {
            previewCache.removeAll()
            previewPhotoID = photo.id
        }
        if let cached = previewCache[preset.id] {
            return cached
        }
        let applied = preset.apply(to: photo.settings)
        let url = photo.fileURL
        Task { [weak self] in
            let result = await RenderEngine.shared.render(
                photoID: -3, url: url, settings: applied,
                quality: .draft(maxDimension: 240))
            guard let self, let cg = result?.image else { return }
            self.previewCache[preset.id] = cg
        }
        return nil
    }
}
