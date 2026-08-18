import SwiftUI
import Observation
import PhotonCore

/// Top-level application state: library location, catalog handle, current module, photo list,
/// selection, and clipboard for copy/paste settings. UI-facing; all catalog I/O hops onto the
/// CatalogDatabase actor.
@Observable @MainActor
final class AppState {

    enum Module: String, CaseIterable {
        case library = "Library"
        case develop = "Develop"
    }

    // MARK: Library / catalog

    private(set) var catalog: CatalogDatabase?
    private(set) var thumbnails: ThumbnailStore?
    private(set) var importService: ImportService?
    var libraryURL: URL?

    // MARK: UI state

    var module: Module = .library
    var photos: [PhotoRecord] = []
    var folders: [FolderRecord] = []
    var collections: [CollectionRecord] = []
    var keywords: [KeywordRecord] = []
    var selection: Set<Int64> = []
    var activePhotoID: Int64?
    var filter = LibraryFilter() { didSet { Task { await reloadPhotos() } } }
    var sort: LibrarySort = .captureDate { didSet { Task { await reloadPhotos() } } }
    var selectedFolderID: Int64? { didSet { Task { await reloadPhotos() } } }
    var selectedCollectionID: Int64? { didSet { Task { await reloadPhotos() } } }

    var isImportDialogPresented = false
    var isSyncDialogPresented = false
    var importProgress: ImportService.Progress?

    /// The develop-module editing session for the active photo.
    var editSession: EditSession?

    /// Copy Settings clipboard.
    var settingsClipboard: (settings: DevelopSettings, subset: SettingsSubset)?

    var activePhoto: PhotoRecord? {
        guard let id = activePhotoID else { return nil }
        return photos.first { $0.id == id }
    }

    // MARK: Bootstrap

    func bootstrap() async {
        // Restore the library from a saved security-scoped bookmark; else prompt.
        if let bookmarkData = UserDefaults.standard.data(forKey: "libraryBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmarkData,
                                  options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() {
                await openLibrary(at: url)
                return
            }
        }
        chooseLibraryFolder()
    }

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Photon Library Folder"
        panel.message = "Photon stores its catalog, previews and presets here. Photos stay wherever they are unless you import with Copy."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use as Library"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
            UserDefaults.standard.set(bookmark, forKey: "libraryBookmark")
        }
        _ = url.startAccessingSecurityScopedResource()
        Task { await openLibrary(at: url) }
    }

    func openLibrary(at url: URL) async {
        do {
            let cat = try CatalogDatabase(libraryURL: url)
            catalog = cat
            libraryURL = url
            thumbnails = ThumbnailStore(libraryURL: url)
            importService = ImportService(catalog: cat, libraryURL: url)
            await reloadAll()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: Data loading

    func reloadAll() async {
        await reloadPhotos()
        await reloadSidebar()
    }

    func reloadPhotos() async {
        guard let catalog else { return }
        do {
            photos = try await catalog.photos(filter: filter, sort: sort,
                                              folderID: selectedFolderID,
                                              collectionID: selectedCollectionID)
        } catch {
            NSLog("Photo reload failed: \(error)")
        }
    }

    func reloadSidebar() async {
        guard let catalog else { return }
        folders = (try? await catalog.folders()) ?? []
        collections = (try? await catalog.collections()) ?? []
        keywords = (try? await catalog.keywords()) ?? []
    }

    // MARK: Import

    func runImport(urls: [URL], options: ImportService.Options) {
        guard let importService else { return }
        Task {
            do {
                _ = try await importService.importURLs(urls, options: options) { progress in
                    Task { @MainActor in self.importProgress = progress }
                }
            } catch {
                NSLog("Import failed: \(error)")
            }
            importProgress = nil
            await reloadAll()
        }
    }

    // MARK: Selection actions

    func setRatingOnSelection(_ rating: Int) {
        guard let catalog else { return }
        let ids = selection.isEmpty ? Set([activePhotoID].compactMap { $0 }) : selection
        Task {
            for id in ids {
                try? await catalog.updateRating(photoID: id, rating: rating)
            }
            await reloadPhotos()
        }
    }

    func setFlagOnSelection(_ flag: PhotoRecord.Flag) {
        guard let catalog else { return }
        let ids = selection.isEmpty ? Set([activePhotoID].compactMap { $0 }) : selection
        Task {
            for id in ids {
                let current = photos.first { $0.id == id }?.flag
                // Toggling the same flag clears it, like Lightroom.
                try? await catalog.updateFlag(photoID: id, flag: current == flag ? .unflagged : flag)
            }
            await reloadPhotos()
        }
    }

    func setColorLabelOnSelection(_ label: PhotoRecord.ColorLabel?) {
        guard let catalog else { return }
        let ids = selection.isEmpty ? Set([activePhotoID].compactMap { $0 }) : selection
        Task {
            for id in ids {
                try? await catalog.updateColorLabel(photoID: id, label: label)
            }
            await reloadPhotos()
        }
    }

    func createVirtualCopy() {
        guard let catalog, let photo = activePhoto else { return }
        Task {
            _ = try? await catalog.createVirtualCopy(of: photo)
            await reloadPhotos()
        }
    }

    // MARK: Develop navigation

    func openInDevelop(photoID: Int64) {
        activePhotoID = photoID
        selection = [photoID]
        module = .develop
        Task { await startEditSession(photoID: photoID) }
    }

    func startEditSession(photoID: Int64) async {
        guard let catalog, let photo = try? await catalog.photo(id: photoID), let photo else {
            return
        }
        let stack = (try? await catalog.editStack(photoID: photoID)) ?? nil
        editSession = EditSession(photo: photo,
                                  stack: stack ?? EditStack(initial: photo.settings),
                                  catalog: catalog)
    }

    // MARK: Copy / paste / sync settings

    func copySettings(subset: SettingsSubset = .defaultCopy) {
        guard let session = editSession else {
            if let photo = activePhoto {
                settingsClipboard = (photo.settings, subset)
            }
            return
        }
        settingsClipboard = (session.settings, subset)
    }

    func pasteSettings() {
        guard let clipboard = settingsClipboard else { return }
        if let session = editSession {
            let merged = session.settings.applying(clipboard.settings, subset: clipboard.subset)
            session.apply(name: "Paste Settings", settings: merged)
        }
    }

    /// Sync the active photo's settings to every selected photo.
    func syncSettings(subset: SettingsSubset) {
        guard let catalog, let source = editSession?.settings ?? activePhoto?.settings else {
            return
        }
        let targets = selection.subtracting([activePhotoID].compactMap { $0 })
        Task {
            for id in targets {
                guard let target = try? await catalog.photo(id: id), let target else { continue }
                var stack = (try? await catalog.editStack(photoID: id)).flatMap { $0 }
                    ?? EditStack(initial: target.settings)
                stack.record("Sync Settings", settings: target.settings.applying(source, subset: subset))
                try? await catalog.saveEditStack(photoID: id, stack: stack)
                if let thumbnails {
                    await thumbnails.invalidate(photoUUID: target.uuid)
                }
            }
            await reloadPhotos()
        }
    }
}
