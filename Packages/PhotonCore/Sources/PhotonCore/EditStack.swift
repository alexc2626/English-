import Foundation

/// The per-photo linear edit history plus named snapshots — pure data, persisted in the
/// catalog. Because every entry is a complete `DevelopSettings` value, stepping through
/// history or restoring a snapshot is just "re-render with these settings"; nothing is ever
/// destructive.
public struct EditStack: Codable, Equatable, Sendable {

    public struct HistoryEntry: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        /// Human-readable step name, e.g. "Exposure +0.35", "Add Mask: Subject".
        public var name: String
        public var settings: DevelopSettings
        public var date: Date

        public init(id: UUID = UUID(), name: String, settings: DevelopSettings,
                    date: Date = Date()) {
            self.id = id
            self.name = name
            self.settings = settings
            self.date = date
        }
    }

    public struct Snapshot: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var settings: DevelopSettings
        public var date: Date

        public init(id: UUID = UUID(), name: String, settings: DevelopSettings,
                    date: Date = Date()) {
            self.id = id
            self.name = name
            self.settings = settings
            self.date = date
        }
    }

    /// Oldest → newest. Index 0 is always the import state.
    public private(set) var history: [HistoryEntry]
    /// Position in `history` currently displayed (undo/redo cursor).
    public private(set) var cursor: Int
    public var snapshots: [Snapshot]

    /// Current settings = history at the cursor.
    public var current: DevelopSettings {
        guard history.indices.contains(cursor) else { return DevelopSettings() }
        return history[cursor].settings
    }

    public init(initial: DevelopSettings = DevelopSettings()) {
        history = [HistoryEntry(name: "Import", settings: initial)]
        cursor = 0
        snapshots = []
    }

    /// Record a new edit. Anything past the cursor (redo tail) is discarded, exactly like
    /// Lightroom's linear history.
    public mutating func record(_ name: String, settings: DevelopSettings) {
        guard settings != current else { return }
        if cursor < history.count - 1 {
            history.removeSubrange((cursor + 1)...)
        }
        history.append(HistoryEntry(name: name, settings: settings))
        cursor = history.count - 1
    }

    /// Replace the newest entry instead of appending — used to coalesce continuous slider
    /// drags into a single history step (call `record` on gesture start, `amend` during drag).
    public mutating func amend(_ name: String, settings: DevelopSettings) {
        guard cursor == history.count - 1, cursor > 0 else {
            record(name, settings: settings)
            return
        }
        history[cursor] = HistoryEntry(id: history[cursor].id, name: name, settings: settings,
                                       date: history[cursor].date)
    }

    public var canUndo: Bool { cursor > 0 }
    public var canRedo: Bool { cursor < history.count - 1 }

    @discardableResult
    public mutating func undo() -> DevelopSettings {
        if canUndo { cursor -= 1 }
        return current
    }

    @discardableResult
    public mutating func redo() -> DevelopSettings {
        if canRedo { cursor += 1 }
        return current
    }

    /// Jump to an arbitrary history entry (clicking a History panel row). Does not truncate;
    /// truncation only happens when a new edit is recorded from that point.
    public mutating func jump(to id: UUID) {
        if let idx = history.firstIndex(where: { $0.id == id }) {
            cursor = idx
        }
    }

    public mutating func addSnapshot(named name: String) {
        snapshots.append(Snapshot(name: name, settings: current))
    }

    /// Restoring a snapshot is itself a recorded history step (like Lightroom).
    public mutating func restoreSnapshot(_ id: UUID) {
        guard let snap = snapshots.first(where: { $0.id == id }) else { return }
        record("Restore Snapshot: \(snap.name)", settings: snap.settings)
    }

    /// Reset to import state, recorded as a step.
    public mutating func reset() {
        record("Reset", settings: history[0].settings)
    }
}

// MARK: - Copy / paste / sync subsets

/// Which panels to include when copying settings between photos ("Copy Settings" dialog).
public struct SettingsSubset: OptionSet, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let basic         = SettingsSubset(rawValue: 1 << 0)
    public static let toneCurve     = SettingsSubset(rawValue: 1 << 1)
    public static let hsl           = SettingsSubset(rawValue: 1 << 2)
    public static let colorGrading  = SettingsSubset(rawValue: 1 << 3)
    public static let detail        = SettingsSubset(rawValue: 1 << 4)
    public static let lens          = SettingsSubset(rawValue: 1 << 5)
    public static let transform     = SettingsSubset(rawValue: 1 << 6)
    public static let effects       = SettingsSubset(rawValue: 1 << 7)
    public static let calibration   = SettingsSubset(rawValue: 1 << 8)
    public static let crop          = SettingsSubset(rawValue: 1 << 9)
    public static let spots         = SettingsSubset(rawValue: 1 << 10)
    public static let masks         = SettingsSubset(rawValue: 1 << 11)

    public static let all: SettingsSubset = [
        .basic, .toneCurve, .hsl, .colorGrading, .detail, .lens, .transform,
        .effects, .calibration, .crop, .spots, .masks
    ]
    /// Lightroom's default copy set excludes geometry-specific edits.
    public static let defaultCopy: SettingsSubset = all.subtracting([.crop, .spots, .transform])
}

extension DevelopSettings {
    /// Merge the chosen panels of `source` into this settings value — the core of
    /// Copy/Paste Settings and Sync Settings across a multi-selection.
    public func applying(_ source: DevelopSettings, subset: SettingsSubset) -> DevelopSettings {
        var out = self
        if subset.contains(.basic) { out.basic = source.basic }
        if subset.contains(.toneCurve) { out.toneCurve = source.toneCurve }
        if subset.contains(.hsl) {
            out.hsl = source.hsl
            out.blackAndWhite = source.blackAndWhite
        }
        if subset.contains(.colorGrading) { out.colorGrading = source.colorGrading }
        if subset.contains(.detail) { out.detail = source.detail }
        if subset.contains(.lens) { out.lens = source.lens }
        if subset.contains(.transform) { out.transform = source.transform }
        if subset.contains(.effects) { out.effects = source.effects }
        if subset.contains(.calibration) { out.calibration = source.calibration }
        if subset.contains(.crop) { out.crop = source.crop }
        if subset.contains(.spots) { out.spots = source.spots }
        if subset.contains(.masks) { out.masks = source.masks }
        return out
    }
}
