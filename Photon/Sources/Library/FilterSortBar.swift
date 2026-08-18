import SwiftUI
import PhotonCore

/// Lightroom-style filter bar: rating threshold, flags, colour labels, keyword, camera/lens,
/// text search, and the sort picker.
struct FilterSortBar: View {
    @Environment(AppState.self) private var appState
    @State private var cameras: [String] = []
    @State private var lenses: [String] = []

    var body: some View {
        @Bindable var state = appState
        HStack(spacing: 14) {
            // Rating filter
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { star in
                    Image(systemName: star <= state.filter.minRating ? "star.fill" : "star")
                        .foregroundStyle(star <= state.filter.minRating ? .yellow : .secondary)
                        .onTapGesture {
                            state.filter.minRating = state.filter.minRating == star ? 0 : star
                        }
                }
            }
            .help("Show photos rated at least this many stars")

            // Flags
            HStack(spacing: 4) {
                FilterToggle(symbol: "flag.fill",
                             isOn: state.filter.flags.contains(PhotoRecord.Flag.pick.rawValue)) {
                    toggleFlag(.pick)
                }
                FilterToggle(symbol: "flag.slash.fill",
                             isOn: state.filter.flags.contains(PhotoRecord.Flag.reject.rawValue)) {
                    toggleFlag(.reject)
                }
            }

            // Colour labels
            HStack(spacing: 4) {
                ForEach(PhotoRecord.ColorLabel.allCases, id: \.self) { label in
                    Circle()
                        .fill(label.swatch.opacity(
                            state.filter.colorLabels.contains(label.rawValue) ? 1 : 0.3))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(.secondary.opacity(0.4)))
                        .onTapGesture {
                            if state.filter.colorLabels.contains(label.rawValue) {
                                state.filter.colorLabels.remove(label.rawValue)
                            } else {
                                state.filter.colorLabels.insert(label.rawValue)
                            }
                        }
                }
            }

            Divider().frame(height: 16)

            Picker("Camera", selection: $state.filter.camera) {
                Text("Any Camera").tag(nil as String?)
                ForEach(cameras, id: \.self) { Text($0).tag($0 as String?) }
            }
            .frame(maxWidth: 180)

            Picker("Lens", selection: $state.filter.lens) {
                Text("Any Lens").tag(nil as String?)
                ForEach(lenses, id: \.self) { Text($0).tag($0 as String?) }
            }
            .frame(maxWidth: 180)

            Spacer()

            TextField("Search", text: $state.filter.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)

            Picker("Sort", selection: $state.sort) {
                ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .frame(maxWidth: 170)

            if !state.filter.isEmpty {
                Button("Clear") { state.filter = LibraryFilter() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .task {
            cameras = (try? await appState.catalog?.distinctCameras()) ?? []
            lenses = (try? await appState.catalog?.distinctLenses()) ?? []
        }
    }

    private func toggleFlag(_ flag: PhotoRecord.Flag) {
        if appState.filter.flags.contains(flag.rawValue) {
            appState.filter.flags.remove(flag.rawValue)
        } else {
            appState.filter.flags.insert(flag.rawValue)
        }
    }
}

private struct FilterToggle: View {
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}
