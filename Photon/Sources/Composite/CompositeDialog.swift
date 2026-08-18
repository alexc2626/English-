import SwiftUI
import PhotonCore

/// Merge dialog for the three composite workflows: pick the mode (preselected from the
/// menu), see the frame list, choose panorama projection, run with progress + cancel.
/// The output file is imported into the catalog as a new source photo and opened in Develop.
struct CompositeDialog: View {
    enum Mode: String, CaseIterable, Identifiable {
        case focusStack = "Focus Stack"
        case hdr = "HDR Merge"
        case panorama = "Panorama"
        var id: String { rawValue }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State var mode: Mode
    @State private var projection: CompositeService.Projection = .cylindrical
    @State private var job: CompositeJob?
    @State private var errorMessage: String?

    private var selectedPhotos: [PhotoRecord] {
        appState.photos.filter { appState.selection.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode.rawValue).font(.title3.weight(.semibold))

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(job != nil)

            GroupBox {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selectedPhotos.count) photos selected")
                        .font(.caption.weight(.medium))
                    ForEach(selectedPhotos.prefix(6)) { photo in
                        Text(photo.fileName).font(.caption2).foregroundStyle(.secondary)
                    }
                    if selectedPhotos.count > 6 {
                        Text("…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            if mode == .panorama {
                Picker("Projection", selection: $projection) {
                    ForEach(CompositeService.Projection.allCases, id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
                .disabled(job != nil)
            }

            switch mode {
            case .focusStack:
                Text("Aligns the frames, measures per-pixel sharpness, and blends an all-in-focus composite (Metal compute).")
                    .font(.caption).foregroundStyle(.secondary)
            case .hdr:
                Text("Merges the bracket into a 32-bit linear radiance image with ghost suppression. Grade it normally in Develop afterwards.")
                    .font(.caption).foregroundStyle(.secondary)
            case .panorama:
                Text("Stitches overlapping frames with feathered seams and suggests an auto-crop for the irregular edges.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let job {
                ProgressView(value: job.progress) {
                    Text(job.stage).font(.caption)
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                if let job {
                    Button("Cancel") {
                        job.cancel()
                    }
                } else {
                    Button("Close") { dismiss() }
                    Button("Merge") { run() }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedPhotos.count < 2)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func run() {
        guard let libraryURL = appState.libraryURL else { return }
        let urls = selectedPhotos.map(\.fileURL)
        let newJob = CompositeJob()
        job = newJob
        errorMessage = nil
        let currentMode = mode
        let currentProjection = projection

        Task {
            do {
                let outputURL: URL
                var suggestedCrop: CropSettings?
                let kind: PhotoRecord.SourceKind
                switch currentMode {
                case .focusStack:
                    outputURL = try await CompositeService.shared.focusStack(
                        urls: urls, job: newJob, libraryURL: libraryURL)
                    kind = .focusStack
                case .hdr:
                    outputURL = try await CompositeService.shared.hdrMerge(
                        urls: urls, job: newJob, libraryURL: libraryURL)
                    kind = .hdrMerge
                case .panorama:
                    let result = try await CompositeService.shared.panorama(
                        urls: urls, projection: currentProjection, job: newJob,
                        libraryURL: libraryURL)
                    outputURL = result.url
                    suggestedCrop = result.suggestedCrop
                    kind = .panorama
                }

                // Import the composite as a first-class catalog photo.
                if let catalog = appState.catalog {
                    var record = ImportService.makeRecord(url: outputURL, folderID: nil,
                                                          isManaged: true)
                    record.sourceKind = kind
                    if let crop = suggestedCrop {
                        record.settings.crop = crop
                    }
                    let id = try await catalog.insertPhoto(record)
                    try await catalog.saveEditStack(
                        photoID: id, stack: EditStack(initial: record.settings))
                    await appState.reloadAll()
                    appState.openInDevelop(photoID: id)
                }
                job = nil
                dismiss()
            } catch {
                job = nil
                errorMessage = String(describing: error)
            }
        }
    }
}
