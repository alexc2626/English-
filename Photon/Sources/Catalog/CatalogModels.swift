import Foundation
import PhotonCore

/// A photo in the catalog. `settings` is the current develop state; the full history and
/// snapshots live in their own tables and are loaded on demand when the photo is edited.
struct PhotoRecord: Identifiable, Hashable, Sendable {
    var id: Int64
    var uuid: UUID
    var folderID: Int64?
    /// Absolute path (managed copies live under the library; referenced files anywhere).
    var filePath: String
    var fileName: String
    /// Non-nil for virtual copies: the id of the master photo sharing the same source file.
    var masterID: Int64?
    var isManaged: Bool

    // Ratings & organisation
    var rating: Int          // 0–5
    var colorLabel: ColorLabel?
    var flag: Flag

    // Source metadata (EXIF snapshot taken at import)
    var captureDate: Date?
    var pixelWidth: Int
    var pixelHeight: Int
    var cameraMake: String
    var cameraModel: String
    var lensModel: String
    var iso: Int?
    var shutterSpeed: Double?    // seconds
    var aperture: Double?        // f-number
    var focalLength: Double?     // mm
    var importDate: Date

    /// Current develop settings (head of the edit stack).
    var settings: DevelopSettings

    /// Composite outputs (focus stacks, HDR merges, panoramas) get a source kind so the UI
    /// can badge them; they are otherwise ordinary photos with their own edit stacks.
    var sourceKind: SourceKind

    enum SourceKind: String, Sendable {
        case original, focusStack, hdrMerge, panorama
    }

    enum ColorLabel: String, CaseIterable, Sendable {
        case red, yellow, green, blue, purple
    }

    enum Flag: Int, Sendable {
        case unflagged = 0
        case pick = 1
        case reject = -1
    }

    var fileURL: URL { URL(fileURLWithPath: filePath) }
    var isVirtualCopy: Bool { masterID != nil }
}

struct FolderRecord: Identifiable, Hashable, Sendable {
    var id: Int64
    var path: String
    var name: String
    var parentID: Int64?
    /// Security-scoped bookmark for sandboxed access to referenced folders.
    var bookmark: Data?
}

struct CollectionRecord: Identifiable, Hashable, Sendable {
    var id: Int64
    var name: String
    var parentID: Int64?
    var isSmart: Bool
    /// Serialised `LibraryFilter` for smart collections.
    var smartRulesJSON: String?
}

struct KeywordRecord: Identifiable, Hashable, Sendable {
    var id: Int64
    var name: String
}

// MARK: - Filtering & sorting (the filter bar)

struct LibraryFilter: Codable, Equatable, Sendable {
    var minRating: Int = 0
    var flags: Set<Int> = []              // raw Flag values; empty = any
    var colorLabels: Set<String> = []     // raw ColorLabel values; empty = any
    var keywordIDs: Set<Int64> = []
    var searchText: String = ""
    var camera: String?
    var lens: String?
    var dateRange: ClosedRange<Date>?

    var isEmpty: Bool { self == LibraryFilter() }
}

enum LibrarySort: String, CaseIterable, Codable, Sendable {
    case captureDate = "Capture Date"
    case importDate = "Import Date"
    case fileName = "File Name"
    case rating = "Rating"

    var sqlOrder: String {
        switch self {
        case .captureDate: return "capture_date DESC, file_name ASC"
        case .importDate: return "import_date DESC, file_name ASC"
        case .fileName: return "file_name ASC"
        case .rating: return "rating DESC, capture_date DESC"
        }
    }
}
