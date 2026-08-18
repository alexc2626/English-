import Foundation
import PhotonCore

/// The Photon catalog — the Lightroom-catalog analogue. A single SQLite database under the
/// user-chosen library folder, owned by this actor so all access is serialised off the main
/// thread. Stores structured edit instructions only; never pixels.
actor CatalogDatabase {

    static let schemaVersion = 1

    private let db: SQLiteDatabase
    let libraryURL: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    init(libraryURL: URL) throws {
        self.libraryURL = libraryURL
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        db = try SQLiteDatabase(path: libraryURL.appendingPathComponent("Photon.catalog").path)
        try migrate()
    }

    private func migrate() throws {
        let version = try db.queryOne("PRAGMA user_version") { Int($0.int(0)) } ?? 0
        guard version < Self.schemaVersion else { return }

        try db.transaction {
            try db.execute("""
                CREATE TABLE IF NOT EXISTS folders (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    path TEXT NOT NULL UNIQUE,
                    name TEXT NOT NULL,
                    parent_id INTEGER REFERENCES folders(id) ON DELETE CASCADE,
                    bookmark BLOB
                )
                """)
            try db.execute("""
                CREATE TABLE IF NOT EXISTS photos (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    uuid TEXT NOT NULL UNIQUE,
                    folder_id INTEGER REFERENCES folders(id) ON DELETE CASCADE,
                    file_path TEXT NOT NULL,
                    file_name TEXT NOT NULL,
                    master_id INTEGER REFERENCES photos(id) ON DELETE CASCADE,
                    is_managed INTEGER NOT NULL DEFAULT 0,
                    rating INTEGER NOT NULL DEFAULT 0,
                    color_label TEXT,
                    flag INTEGER NOT NULL DEFAULT 0,
                    capture_date REAL,
                    pixel_width INTEGER NOT NULL DEFAULT 0,
                    pixel_height INTEGER NOT NULL DEFAULT 0,
                    camera_make TEXT NOT NULL DEFAULT '',
                    camera_model TEXT NOT NULL DEFAULT '',
                    lens_model TEXT NOT NULL DEFAULT '',
                    iso INTEGER,
                    shutter_speed REAL,
                    aperture REAL,
                    focal_length REAL,
                    import_date REAL NOT NULL,
                    settings_json TEXT NOT NULL,
                    source_kind TEXT NOT NULL DEFAULT 'original'
                )
                """)
            try db.execute("CREATE INDEX IF NOT EXISTS idx_photos_folder ON photos(folder_id)")
            try db.execute("CREATE INDEX IF NOT EXISTS idx_photos_capture ON photos(capture_date)")
            try db.execute("CREATE INDEX IF NOT EXISTS idx_photos_rating ON photos(rating)")

            try db.execute("""
                CREATE TABLE IF NOT EXISTS keywords (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL UNIQUE COLLATE NOCASE
                )
                """)
            try db.execute("""
                CREATE TABLE IF NOT EXISTS photo_keywords (
                    photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
                    keyword_id INTEGER NOT NULL REFERENCES keywords(id) ON DELETE CASCADE,
                    PRIMARY KEY (photo_id, keyword_id)
                )
                """)
            try db.execute("""
                CREATE TABLE IF NOT EXISTS collections (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    parent_id INTEGER REFERENCES collections(id) ON DELETE CASCADE,
                    is_smart INTEGER NOT NULL DEFAULT 0,
                    smart_rules_json TEXT
                )
                """)
            try db.execute("""
                CREATE TABLE IF NOT EXISTS collection_photos (
                    collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
                    photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (collection_id, photo_id)
                )
                """)
            try db.execute("""
                CREATE TABLE IF NOT EXISTS edit_stacks (
                    photo_id INTEGER PRIMARY KEY REFERENCES photos(id) ON DELETE CASCADE,
                    stack_json TEXT NOT NULL
                )
                """)
            try db.execute("""
                CREATE TABLE IF NOT EXISTS presets (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    grp TEXT NOT NULL DEFAULT 'User Presets',
                    preset_json TEXT NOT NULL,
                    created REAL NOT NULL
                )
                """)
            try db.execute("PRAGMA user_version=\(Self.schemaVersion)")
        }
    }

    // MARK: Row mapping

    private func photo(from row: SQLiteDatabase.Row) throws -> PhotoRecord {
        let settingsJSON = row.string(23) ?? "{}"
        let settings = (try? decoder.decode(
            DevelopSettings.self, from: Data(settingsJSON.utf8))) ?? DevelopSettings()
        return PhotoRecord(
            id: row.int(0),
            uuid: row.uuid(1) ?? UUID(),
            folderID: row.optionalInt(2),
            filePath: row.string(3) ?? "",
            fileName: row.string(4) ?? "",
            masterID: row.optionalInt(5),
            isManaged: row.bool(6),
            rating: Int(row.int(7)),
            colorLabel: row.string(8).flatMap(PhotoRecord.ColorLabel.init(rawValue:)),
            flag: PhotoRecord.Flag(rawValue: Int(row.int(9))) ?? .unflagged,
            captureDate: row.date(10),
            pixelWidth: Int(row.int(11)),
            pixelHeight: Int(row.int(12)),
            cameraMake: row.string(13) ?? "",
            cameraModel: row.string(14) ?? "",
            lensModel: row.string(15) ?? "",
            iso: row.optionalInt(16).map(Int.init),
            shutterSpeed: row.optionalDouble(17),
            aperture: row.optionalDouble(18),
            focalLength: row.optionalDouble(19),
            importDate: row.date(20) ?? Date(),
            settings: settings,
            sourceKind: PhotoRecord.SourceKind(rawValue: row.string(24) ?? "") ?? .original
        )
    }

    private static let photoColumns = """
        id, uuid, folder_id, file_path, file_name, master_id, is_managed, rating, color_label,
        flag, capture_date, pixel_width, pixel_height, camera_make, camera_model, lens_model,
        iso, shutter_speed, aperture, focal_length, import_date, 0, 0, settings_json, source_kind
        """
    // Columns 21/22 are placeholders so settings_json/source_kind keep stable indices (23/24)
    // if intermediate columns are added by future migrations.

    // MARK: Photos

    @discardableResult
    func insertPhoto(_ p: PhotoRecord) throws -> Int64 {
        let settingsJSON = String(data: try encoder.encode(p.settings), encoding: .utf8) ?? "{}"
        try db.execute("""
            INSERT INTO photos (uuid, folder_id, file_path, file_name, master_id, is_managed,
                rating, color_label, flag, capture_date, pixel_width, pixel_height,
                camera_make, camera_model, lens_model, iso, shutter_speed, aperture,
                focal_length, import_date, settings_json, source_kind)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [
                p.uuid, p.folderID, p.filePath, p.fileName, p.masterID, p.isManaged,
                p.rating, p.colorLabel?.rawValue, p.flag.rawValue, p.captureDate,
                p.pixelWidth, p.pixelHeight, p.cameraMake, p.cameraModel, p.lensModel,
                p.iso, p.shutterSpeed, p.aperture, p.focalLength, p.importDate,
                settingsJSON, p.sourceKind.rawValue
            ])
        return db.lastInsertRowID
    }

    func photos(filter: LibraryFilter = LibraryFilter(), sort: LibrarySort = .captureDate,
                folderID: Int64? = nil, collectionID: Int64? = nil) throws -> [PhotoRecord] {
        var sql = "SELECT \(Self.photoColumns) FROM photos"
        var clauses: [String] = []
        var binds: [Any?] = []

        if let collectionID {
            sql += " JOIN collection_photos cp ON cp.photo_id = photos.id"
            clauses.append("cp.collection_id = ?")
            binds.append(collectionID)
        }
        if let folderID {
            clauses.append("folder_id = ?")
            binds.append(folderID)
        }
        if filter.minRating > 0 {
            clauses.append("rating >= ?")
            binds.append(filter.minRating)
        }
        if !filter.flags.isEmpty {
            clauses.append("flag IN (\(filter.flags.map { String($0) }.joined(separator: ",")))")
        }
        if !filter.colorLabels.isEmpty {
            let ph = filter.colorLabels.map { _ in "?" }.joined(separator: ",")
            clauses.append("color_label IN (\(ph))")
            binds.append(contentsOf: filter.colorLabels.map { $0 })
        }
        if !filter.searchText.isEmpty {
            clauses.append("(file_name LIKE ? OR camera_model LIKE ? OR lens_model LIKE ?)")
            let like = "%\(filter.searchText)%"
            binds.append(contentsOf: [like, like, like])
        }
        if let camera = filter.camera {
            clauses.append("camera_model = ?")
            binds.append(camera)
        }
        if let lens = filter.lens {
            clauses.append("lens_model = ?")
            binds.append(lens)
        }
        if let range = filter.dateRange {
            clauses.append("capture_date BETWEEN ? AND ?")
            binds.append(contentsOf: [range.lowerBound, range.upperBound])
        }
        if !filter.keywordIDs.isEmpty {
            let ids = filter.keywordIDs.map(String.init).joined(separator: ",")
            clauses.append("""
                id IN (SELECT photo_id FROM photo_keywords WHERE keyword_id IN (\(ids)))
                """)
        }

        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY \(sort.sqlOrder)"
        return try db.query(sql, binds, photo(from:))
    }

    func photo(id: Int64) throws -> PhotoRecord? {
        try db.queryOne("SELECT \(Self.photoColumns) FROM photos WHERE id = ?", [id],
                        photo(from:))
    }

    func updateSettings(photoID: Int64, settings: DevelopSettings) throws {
        let json = String(data: try encoder.encode(settings), encoding: .utf8) ?? "{}"
        try db.execute("UPDATE photos SET settings_json = ? WHERE id = ?", [json, photoID])
    }

    func updateRating(photoID: Int64, rating: Int) throws {
        try db.execute("UPDATE photos SET rating = ? WHERE id = ?", [rating, photoID])
    }

    func updateColorLabel(photoID: Int64, label: PhotoRecord.ColorLabel?) throws {
        try db.execute("UPDATE photos SET color_label = ? WHERE id = ?",
                       [label?.rawValue, photoID])
    }

    func updateFlag(photoID: Int64, flag: PhotoRecord.Flag) throws {
        try db.execute("UPDATE photos SET flag = ? WHERE id = ?", [flag.rawValue, photoID])
    }

    func removePhoto(id: Int64) throws {
        try db.execute("DELETE FROM photos WHERE id = ?", [id])
    }

    /// Create a virtual copy: same source file, independent edit stack seeded from the master's
    /// current settings.
    @discardableResult
    func createVirtualCopy(of master: PhotoRecord) throws -> Int64 {
        var copy = master
        copy.uuid = UUID()
        copy.masterID = master.masterID ?? master.id
        return try insertPhoto(copy)
    }

    // MARK: Edit stacks (history + snapshots)

    func editStack(photoID: Int64) throws -> EditStack? {
        try db.queryOne("SELECT stack_json FROM edit_stacks WHERE photo_id = ?", [photoID]) {
            row in
            guard let json = row.string(0) else { return EditStack() }
            return (try? decoder.decode(EditStack.self, from: Data(json.utf8))) ?? EditStack()
        }
    }

    func saveEditStack(photoID: Int64, stack: EditStack) throws {
        let json = String(data: try encoder.encode(stack), encoding: .utf8) ?? "{}"
        try db.execute("""
            INSERT INTO edit_stacks (photo_id, stack_json) VALUES (?, ?)
            ON CONFLICT(photo_id) DO UPDATE SET stack_json = excluded.stack_json
            """, [photoID, json])
        try updateSettings(photoID: photoID, settings: stack.current)
    }

    // MARK: Folders

    @discardableResult
    func upsertFolder(path: String, name: String, parentID: Int64?, bookmark: Data?) throws -> Int64 {
        if let existing = try db.queryOne("SELECT id FROM folders WHERE path = ?", [path],
                                          { $0.int(0) }) {
            if let bookmark {
                try db.execute("UPDATE folders SET bookmark = ? WHERE id = ?", [bookmark, existing])
            }
            return existing
        }
        try db.execute("INSERT INTO folders (path, name, parent_id, bookmark) VALUES (?,?,?,?)",
                       [path, name, parentID, bookmark])
        return db.lastInsertRowID
    }

    func folders() throws -> [FolderRecord] {
        try db.query("SELECT id, path, name, parent_id, bookmark FROM folders ORDER BY path") {
            FolderRecord(id: $0.int(0), path: $0.string(1) ?? "", name: $0.string(2) ?? "",
                         parentID: $0.optionalInt(3), bookmark: $0.data(4))
        }
    }

    // MARK: Keywords

    @discardableResult
    func keywordID(named name: String) throws -> Int64 {
        if let id = try db.queryOne("SELECT id FROM keywords WHERE name = ?", [name],
                                    { $0.int(0) }) {
            return id
        }
        try db.execute("INSERT INTO keywords (name) VALUES (?)", [name])
        return db.lastInsertRowID
    }

    func keywords() throws -> [KeywordRecord] {
        try db.query("SELECT id, name FROM keywords ORDER BY name") {
            KeywordRecord(id: $0.int(0), name: $0.string(1) ?? "")
        }
    }

    func keywords(photoID: Int64) throws -> [KeywordRecord] {
        try db.query("""
            SELECT k.id, k.name FROM keywords k
            JOIN photo_keywords pk ON pk.keyword_id = k.id
            WHERE pk.photo_id = ? ORDER BY k.name
            """, [photoID]) {
            KeywordRecord(id: $0.int(0), name: $0.string(1) ?? "")
        }
    }

    func tag(photoID: Int64, keyword: String) throws {
        let kid = try keywordID(named: keyword)
        try db.execute("""
            INSERT OR IGNORE INTO photo_keywords (photo_id, keyword_id) VALUES (?, ?)
            """, [photoID, kid])
    }

    func untag(photoID: Int64, keywordID: Int64) throws {
        try db.execute("DELETE FROM photo_keywords WHERE photo_id = ? AND keyword_id = ?",
                       [photoID, keywordID])
    }

    // MARK: Collections

    @discardableResult
    func createCollection(name: String, parentID: Int64? = nil, isSmart: Bool = false,
                          smartRulesJSON: String? = nil) throws -> Int64 {
        try db.execute("""
            INSERT INTO collections (name, parent_id, is_smart, smart_rules_json)
            VALUES (?,?,?,?)
            """, [name, parentID, isSmart, smartRulesJSON])
        return db.lastInsertRowID
    }

    func collections() throws -> [CollectionRecord] {
        try db.query("""
            SELECT id, name, parent_id, is_smart, smart_rules_json FROM collections
            ORDER BY name
            """) {
            CollectionRecord(id: $0.int(0), name: $0.string(1) ?? "",
                             parentID: $0.optionalInt(2), isSmart: $0.bool(3),
                             smartRulesJSON: $0.string(4))
        }
    }

    func addToCollection(collectionID: Int64, photoID: Int64) throws {
        try db.execute("""
            INSERT OR IGNORE INTO collection_photos (collection_id, photo_id) VALUES (?, ?)
            """, [collectionID, photoID])
    }

    func removeFromCollection(collectionID: Int64, photoID: Int64) throws {
        try db.execute("DELETE FROM collection_photos WHERE collection_id = ? AND photo_id = ?",
                       [collectionID, photoID])
    }

    func deleteCollection(id: Int64) throws {
        try db.execute("DELETE FROM collections WHERE id = ?", [id])
    }

    // MARK: Presets

    func savePreset(_ preset: DevelopPreset) throws {
        let json = String(data: try encoder.encode(preset), encoding: .utf8) ?? "{}"
        try db.execute("""
            INSERT INTO presets (id, name, grp, preset_json, created) VALUES (?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name, grp = excluded.grp, preset_json = excluded.preset_json
            """, [preset.id, preset.name, preset.group, json, preset.created])
    }

    func presets() throws -> [DevelopPreset] {
        try db.query("SELECT preset_json FROM presets ORDER BY grp, name") { row in
            guard let json = row.string(0),
                  let preset = try? decoder.decode(DevelopPreset.self, from: Data(json.utf8))
            else { return nil }
            return preset
        }.compactMap { $0 }
    }

    func deletePreset(id: UUID) throws {
        try db.execute("DELETE FROM presets WHERE id = ?", [id])
    }

    // MARK: Distinct metadata values (filter bar dropdowns)

    func distinctCameras() throws -> [String] {
        try db.query("""
            SELECT DISTINCT camera_model FROM photos
            WHERE camera_model != '' ORDER BY camera_model
            """) { $0.string(0) ?? "" }
    }

    func distinctLenses() throws -> [String] {
        try db.query("""
            SELECT DISTINCT lens_model FROM photos
            WHERE lens_model != '' ORDER BY lens_model
            """) { $0.string(0) ?? "" }
    }
}
