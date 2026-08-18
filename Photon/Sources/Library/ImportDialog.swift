import SwiftUI
import PhotonCore

/// Import dialog: choose files/folders, copy-vs-reference, import preset, keywords.
struct ImportDialog: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedURLs: [URL] = []
    @State private var mode: ImportService.Options.Mode = .reference
    @State private var keywordText = ""
    @State private var presets: [DevelopPreset] = []
    @State private var selectedPresetID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Photos")
                .font(.title2.weight(.semibold))

            GroupBox {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        if selectedURLs.isEmpty {
                            Text("No files or folders selected")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(selectedURLs.prefix(5), id: \.self) { url in
                                Text(url.lastPathComponent).font(.caption)
                            }
                            if selectedURLs.count > 5 {
                                Text("…and \(selectedURLs.count - 5) more")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    Button("Choose…") { chooseFiles() }
                }
                .padding(4)
            }

            Picker("File Handling", selection: $mode) {
                Text("Reference in place (Add)").tag(ImportService.Options.Mode.reference)
                Text("Copy into managed library folder").tag(ImportService.Options.Mode.copy)
            }
            .pickerStyle(.radioGroup)

            Picker("Apply Develop Preset", selection: $selectedPresetID) {
                Text("None").tag(nil as UUID?)
                ForEach(presets) { preset in
                    Text("\(preset.group) / \(preset.name)").tag(preset.id as UUID?)
                }
            }

            TextField("Keywords (comma-separated)", text: $keywordText)
                .textFieldStyle(.roundedBorder)

            if let progress = appState.importProgress {
                ProgressView(value: Double(progress.completed),
                             total: Double(max(progress.total, 1))) {
                    Text("Importing \(progress.currentFile)")
                        .font(.caption)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") {
                    let keywords = keywordText
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    let preset = presets.first { $0.id == selectedPresetID }
                    appState.runImport(urls: selectedURLs, options: .init(
                        mode: mode, applyPreset: preset, keywords: keywords))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedURLs.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .task {
            presets = (try? await appState.catalog?.presets()) ?? []
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Select"
        if panel.runModal() == .OK {
            selectedURLs = panel.urls
        }
    }
}

/// The Sync Settings dialog: choose which panels to push from the active photo to the rest
/// of the selection.
struct SyncSettingsDialog: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var subset: SettingsSubset = .defaultCopy

    private let groups: [(String, SettingsSubset)] = [
        ("Basic", .basic), ("Tone Curve", .toneCurve), ("HSL / B&W", .hsl),
        ("Color Grading", .colorGrading), ("Detail", .detail), ("Lens Corrections", .lens),
        ("Transform", .transform), ("Effects", .effects), ("Calibration", .calibration),
        ("Crop", .crop), ("Spot Removal", .spots), ("Masks", .masks)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Synchronize Settings")
                .font(.title3.weight(.semibold))
            Text("Applies the current photo's settings to \(max(appState.selection.count - 1, 0)) other selected photo(s).")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      alignment: .leading, spacing: 6) {
                ForEach(groups, id: \.0) { name, flag in
                    Toggle(name, isOn: Binding(
                        get: { subset.contains(flag) },
                        set: { on in
                            if on { subset.insert(flag) } else { subset.remove(flag) }
                        }))
                }
            }

            HStack {
                Button("Check All") { subset = .all }
                Button("Check None") { subset = [] }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Synchronize") {
                    appState.syncSettings(subset: subset)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
