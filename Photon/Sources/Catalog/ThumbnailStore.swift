import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Asynchronous thumbnail generation with a two-tier cache: NSCache in memory, JPEGs on disk
/// under the library's Previews folder. Grid scrolling never blocks — requests are served
/// from cache instantly or generated on a background executor and delivered via async/await.
actor ThumbnailStore {

    static let thumbnailPixelSize: CGFloat = 512

    private let diskRoot: URL
    private let memoryCache = NSCache<NSString, NSImage>()
    /// De-duplicates concurrent requests for the same photo.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init(libraryURL: URL) {
        diskRoot = libraryURL.appendingPathComponent("Previews/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskRoot, withIntermediateDirectories: true)
        memoryCache.countLimit = 2000
    }

    /// Fetch (or build) the thumbnail for a photo. `editHash` should change when the photo's
    /// develop settings change so stale thumbnails regenerate; pass 0 for source-only thumbs.
    func thumbnail(for photoUUID: UUID, sourceURL: URL, editHash: Int = 0) async -> NSImage? {
        let key = "\(photoUUID.uuidString)-\(editHash)" as NSString
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }
        let keyString = key as String
        if let existing = inFlight[keyString] {
            return await existing.value
        }
        let diskURL = diskRoot.appendingPathComponent("\(keyString).jpg")
        let task = Task<NSImage?, Never>.detached(priority: .utility) {
            // Disk tier
            if let image = NSImage(contentsOf: diskURL) {
                return image
            }
            // Generate from source via ImageIO (uses embedded RAW previews when present,
            // which keeps import fast even for large RAW files).
            guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.thumbnailPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                               options as CFDictionary) else {
                return nil
            }
            // Persist to disk tier.
            if let dest = CGImageDestinationCreateWithURL(diskURL as CFURL,
                                                          UTType.jpeg.identifier as CFString,
                                                          1, nil) {
                CGImageDestinationAddImage(dest, cg, [
                    kCGImageDestinationLossyCompressionQuality: 0.85
                ] as CFDictionary)
                CGImageDestinationFinalize(dest)
            }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        inFlight[keyString] = task
        let image = await task.value
        inFlight[keyString] = nil
        if let image {
            memoryCache.setObject(image, forKey: key)
        }
        return image
    }

    /// Replace the cached thumbnail with a freshly rendered edited preview (called by the
    /// render engine after develop changes settle).
    func store(image: NSImage, for photoUUID: UUID, editHash: Int) {
        let key = "\(photoUUID.uuidString)-\(editHash)" as NSString
        memoryCache.setObject(image, forKey: key)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return }
        let diskURL = diskRoot.appendingPathComponent("\(key as String).jpg")
        try? jpeg.write(to: diskURL)
    }

    /// Drop every cached rendition of a photo (e.g. after its settings change).
    func invalidate(photoUUID: UUID) {
        // NSCache has no enumeration; disk cleanup handles staleness lazily. Remove disk
        // files for this UUID so new hashes regenerate cleanly.
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: diskRoot, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix(photoUUID.uuidString) {
                try? fm.removeItem(at: file)
            }
        }
    }
}
