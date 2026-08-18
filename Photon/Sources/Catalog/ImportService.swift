import Foundation
import ImageIO
import UniformTypeIdentifiers
import PhotonCore

/// Scans folders, extracts EXIF via ImageIO, and registers photos in the catalog —
/// referencing files in place by default, or copying them into the managed library folder.
/// Runs entirely off the main thread; progress is reported through an AsyncStream.
struct ImportService {

    struct Options: Sendable {
        enum Mode: String, Sendable { case reference, copy }
        var mode: Mode = .reference
        /// Preset applied to every imported photo (import presets).
        var applyPreset: DevelopPreset?
        /// Keywords added to every imported photo.
        var keywords: [String] = []
    }

    struct Progress: Sendable {
        var completed: Int
        var total: Int
        var currentFile: String
    }

    let catalog: CatalogDatabase

    /// File extensions Core Image's RAW pipeline (or ImageIO) can decode. CIRAWFilter covers
    /// most camera RAW formats on Apple Silicon; unsupported files are flagged at decode time
    /// rather than rejected at import.
    static let importableExtensions: Set<String> = [
        // RAW
        "arw", "cr2", "cr3", "nef", "nrw", "orf", "raf", "rw2", "pef", "srw", "dng", "erf",
        "kdc", "mrw", "raw", "sr2", "srf", "x3f", "iiq", "3fr", "fff",
        // Rendered
        "jpg", "jpeg", "png", "tif", "tiff", "heic", "heif", "webp"
    ]

    /// Import a set of file/folder URLs. Returns the inserted photo IDs.
    func importURLs(_ urls: [URL], options: Options,
                    progress: (@Sendable (Progress) -> Void)? = nil) async throws -> [Int64] {
        let files = try expand(urls)
        var inserted: [Int64] = []

        for (index, file) in files.enumerated() {
            progress?(Progress(completed: index, total: files.count,
                               currentFile: file.lastPathComponent))

            let targetURL: URL
            var isManaged = false
            if options.mode == .copy {
                targetURL = try copyIntoLibrary(file)
                isManaged = true
            } else {
                targetURL = file
            }

            let folderURL = targetURL.deletingLastPathComponent()
            let bookmark = try? folderURL.bookmarkData(options: .withSecurityScope)
            let folderID = try await catalog.upsertFolder(
                path: folderURL.path, name: folderURL.lastPathComponent,
                parentID: nil, bookmark: bookmark)

            var record = Self.makeRecord(url: targetURL, folderID: folderID,
                                         isManaged: isManaged)
            if let preset = options.applyPreset {
                record.settings = preset.apply(to: record.settings)
            }
            let id = try await catalog.insertPhoto(record)
            for keyword in options.keywords {
                try await catalog.tag(photoID: id, keyword: keyword)
            }
            // Seed the edit stack so history starts at the imported state.
            try await catalog.saveEditStack(photoID: id, stack: EditStack(initial: record.settings))
            inserted.append(id)
        }
        progress?(Progress(completed: files.count, total: files.count, currentFile: ""))
        return inserted
    }

    /// Recursively expand folders into importable files, stably ordered.
    private func expand(_ urls: [URL]) throws -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let contents = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles])
                while let child = contents?.nextObject() as? URL {
                    if Self.importableExtensions.contains(child.pathExtension.lowercased()) {
                        files.append(child)
                    }
                }
            } else if Self.importableExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func copyIntoLibrary(_ source: URL) throws -> URL {
        let managedRoot = catalogLibraryURL.appendingPathComponent("Managed", isDirectory: true)
        // Organise copies by capture year/month like Lightroom's dated folders.
        let date = Self.captureDate(url: source) ?? Date()
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        let folder = managedRoot
            .appendingPathComponent(String(format: "%04d", comps.year ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.month ?? 0), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var dest = folder.appendingPathComponent(source.lastPathComponent)
        var counter = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            let stem = source.deletingPathExtension().lastPathComponent
            dest = folder.appendingPathComponent(
                "\(stem)-\(counter).\(source.pathExtension)")
            counter += 1
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    private var catalogLibraryURL: URL {
        // The actor exposes its library URL non-isolated via init capture; safe to read here.
        catalogLibraryRoot
    }

    private let catalogLibraryRoot: URL

    init(catalog: CatalogDatabase, libraryURL: URL) {
        self.catalog = catalog
        self.catalogLibraryRoot = libraryURL
    }

    // MARK: EXIF extraction

    static func makeRecord(url: URL, folderID: Int64?, isManaged: Bool) -> PhotoRecord {
        let props = imageProperties(url: url)
        let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exifAux = props?[kCGImagePropertyExifAuxDictionary] as? [CFString: Any]

        let width = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0

        return PhotoRecord(
            id: 0,
            uuid: UUID(),
            folderID: folderID,
            filePath: url.path,
            fileName: url.lastPathComponent,
            masterID: nil,
            isManaged: isManaged,
            rating: 0,
            colorLabel: nil,
            flag: .unflagged,
            captureDate: parseExifDate(exif?[kCGImagePropertyExifDateTimeOriginal] as? String),
            pixelWidth: width,
            pixelHeight: height,
            cameraMake: (tiff?[kCGImagePropertyTIFFMake] as? String) ?? "",
            cameraModel: (tiff?[kCGImagePropertyTIFFModel] as? String) ?? "",
            lensModel: (exif?[kCGImagePropertyExifLensModel] as? String)
                ?? (exifAux?[kCGImagePropertyExifAuxLensModel] as? String) ?? "",
            iso: (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first,
            shutterSpeed: exif?[kCGImagePropertyExifExposureTime] as? Double,
            aperture: exif?[kCGImagePropertyExifFNumber] as? Double,
            focalLength: exif?[kCGImagePropertyExifFocalLength] as? Double,
            importDate: Date(),
            settings: DevelopSettings(),
            sourceKind: .original
        )
    }

    static func imageProperties(url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }

    static func captureDate(url: URL) -> Date? {
        let props = imageProperties(url: url)
        let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        return parseExifDate(exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
    }

    static func parseExifDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
        fmt.timeZone = TimeZone.current
        return fmt.date(from: string)
    }
}
