import SwiftUI
import UniformTypeIdentifiers
import PhotonCore

/// Presets panel: grouped one-click browser with live hover preview, save-current-as-preset
/// with a panel subset picker, and XMP import/export.
struct PresetsPanel: View {
    @Environment(AppState.self) private var appState
    let session: EditSession

    @State private var store: PresetStore?
    @State private var isSaving = false
    @State private var hoveredPresetID: UUID?

    var body: some View {
        DevelopPanel(title: "Presets") {
            HStack {
                Button {
                    isSaving = true
                } label: {
                    Label("Save Preset…", systemImage: "plus.square.on.square")
                }
                .font(.caption)
                Spacer()
                Button("Import…") { importPresets() }
                    .font(.caption)
            }

            if let store {
                // Hover preview thumbnail
                if let hoveredPresetID,
                   let preset = store.presets.first(where: { $0.id == hoveredPresetID }),
                   let cg = store.preview(for: preset, photo: session.photo) {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(alignment: .bottomLeading) {
                            Text(preset.name)
                                .font(.caption2)
                                .padding(3)
                                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.white)
                                .padding(3)
                        }
                }

                ForEach(store.groups, id: \.self) { group in
                    presetGroup(store: store, group: group)
                }

                if store.presets.isEmpty {
                    Text("No presets yet. Save the current look or import an XMP pack.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task {
            if store == nil, let catalog = appState.catalog {
                store = PresetStore(catalog: catalog)
            }
        }
        .sheet(isPresented: $isSaving) {
            if let store {
                SavePresetSheet(session: session, store: store)
            }
        }
    }

    @ViewBuilder
    private func presetGroup(store: PresetStore, group: String) -> some View {
        DisclosureGroup {
            ForEach(store.presets(in: group)) { preset in
                HStack {
                    Text(preset.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        exportPreset(preset, store: store)
                    } label: {
                        Image(systemName: "square.and.arrow.up").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Export as XMP")
                    Button {
                        Task { await store.delete(preset) }
                    } label: {
                        Image(systemName: "trash").font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(hoveredPresetID == preset.id
                              ? Color.accentColor.opacity(0.12) : .clear)
                )
                .onHover { hovering in
                    hoveredPresetID = hovering ? preset.id : nil
                }
                .onTapGesture {
                    session.apply(name: "Preset: \(preset.name)",
                                  settings: preset.apply(to: session.settings))
                }
            }
        } label: {
            Text(group).font(.system(size: 11, weight: .medium))
        }
    }

    private func importPresets() {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xmp") ?? .xml]
        panel.allowsMultipleSelection = true
        panel.message = "Choose XMP preset files (Photon or Lightroom-style)"
        guard panel.runModal() == .OK else { return }
        Task {
            let result = await store.importXMPFiles(panel.urls)
            if result.failed > 0 {
                let alert = NSAlert()
                alert.messageText = "Imported \(result.imported) preset(s); \(result.failed) file(s) could not be read."
                alert.runModal()
            }
        }
    }

    private func exportPreset(_ preset: DevelopPreset, store: PresetStore) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        try? store.exportXMP(preset, to: dir)
    }
}

/// Save-preset sheet: name, group, and which panels to capture.
struct SavePresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: EditSession
    let store: PresetStore

    @State private var name = "New Preset"
    @State private var group = "User Presets"

    @State private var subset: SettingsSubset = .defaultCopy

    private let groups: [(String, SettingsSubset)] = [
        ("Basic", .basic), ("Tone Curve", .toneCurve), ("HSL / B&W", .hsl),
        ("Color Grading", .colorGrading), ("Detail", .detail), ("Lens", .lens),
        ("Transform", .transform), ("Effects", .effects), ("Calibration", .calibration),
        ("Masks", .masks)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Develop Preset").font(.title3.weight(.semibold))
            TextField("Preset Name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Group", text: $group)
                .textFieldStyle(.roundedBorder)

            Text("Include").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      alignment: .leading, spacing: 6) {
                ForEach(groups, id: \.0) { label, flag in
                    Toggle(label, isOn: Binding(
                        get: { subset.contains(flag) },
                        set: { on in
                            if on { subset.insert(flag) } else { subset.remove(flag) }
                        }))
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    Task {
                        await store.saveCurrent(name: name, group: group,
                                                subset: subset, settings: session.settings)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
