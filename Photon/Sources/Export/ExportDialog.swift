import SwiftUI
import PhotonCore

/// The batch export dialog: format, quality, colour space, resize, output sharpening,
/// watermark, naming template, destination, progress.
struct ExportDialog: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportService.Format = .jpeg
    @State private var quality: Double = 0.9
    @State private var colorSpace: ExportService.ColorSpaceChoice = .sRGB
    @State private var resize = false
    @State private var maxLongEdge = 2048
    @State private var outputSharpening: Double = 0
    @State private var watermarkText = ""
    @State private var watermarkOpacity: Double = 0.5
    @State private var namingTemplate = "{name}"
    @State private var destination: URL?

    @State private var progress: ExportService.Progress?
    @State private var exportTask: Task<Void, Never>?
    @State private var resultMessage: String?

    private var selectedPhotos: [PhotoRecord] {
        let ids = appState.selection.isEmpty
            ? Set([appState.activePhotoID].compactMap { $0 })
            : appState.selection
        return appState.photos.filter { ids.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export \(selectedPhotos.count) Photo\(selectedPhotos.count == 1 ? "" : "s")")
                .font(.title3.weight(.semibold))

            Form {
                Picker("Format", selection: $format) {
                    ForEach(ExportService.Format.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                if format == .jpeg || format == .heif {
                    LabeledContent("Quality") {
                        Slider(value: $quality, in: 0.3...1)
                        Text(String(format: "%.0f%%", quality * 100))
                            .font(.caption.monospacedDigit())
                            .frame(width: 40)
                    }
                }
                Picker("Color Space", selection: $colorSpace) {
                    ForEach(ExportService.ColorSpaceChoice.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                Toggle("Resize long edge to", isOn: $resize)
                if resize {
                    TextField("Pixels", value: $maxLongEdge, format: .number)
                        .frame(width: 100)
                }
                LabeledContent("Output Sharpening") {
                    Slider(value: $outputSharpening, in: 0...100)
                    Text(String(format: "%.0f", outputSharpening))
                        .font(.caption.monospacedDigit())
                        .frame(width: 30)
                }
                TextField("Watermark Text (optional)", text: $watermarkText)
                if !watermarkText.isEmpty {
                    LabeledContent("Watermark Opacity") {
                        Slider(value: $watermarkOpacity, in: 0.1...1)
                    }
                }
                TextField("File Naming", text: $namingTemplate)
                    .help("Tokens: {name} {seq:3} {date:yyyyMMdd} {rating} {camera} {iso}")
                LabeledContent("Destination") {
                    HStack {
                        Text(destination?.lastPathComponent ?? "Choose…")
                            .foregroundStyle(destination == nil ? .secondary : .primary)
                        Button("Browse…") { chooseDestination() }
                    }
                }
            }
            .formStyle(.columns)

            if let progress {
                ProgressView(value: Double(progress.completed),
                             total: Double(max(progress.total, 1))) {
                    Text(progress.currentFile.isEmpty
                         ? "Finishing…" : "Exporting \(progress.currentFile)")
                        .font(.caption)
                }
            }
            if let resultMessage {
                Text(resultMessage).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                if exportTask != nil {
                    Button("Cancel") {
                        exportTask?.cancel()
                        exportTask = nil
                        progress = nil
                    }
                } else {
                    Button("Close") { dismiss() }
                    Button("Export") { runExport() }
                        .buttonStyle(.borderedProminent)
                        .disabled(destination == nil || selectedPhotos.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        if panel.runModal() == .OK {
            destination = panel.url
        }
    }

    private func runExport() {
        guard let destination else { return }
        let options = ExportService.Options(
            format: format,
            jpegQuality: quality,
            colorSpace: colorSpace,
            maxLongEdge: resize ? maxLongEdge : nil,
            outputSharpening: outputSharpening,
            watermarkText: watermarkText,
            watermarkOpacity: watermarkOpacity,
            naming: NamingTemplate(template: namingTemplate),
            destination: destination
        )
        let photos = selectedPhotos
        resultMessage = nil
        exportTask = Task {
            do {
                let written = try await ExportService.shared.export(
                    photos: photos, options: options) { p in
                    Task { @MainActor in progress = p }
                }
                resultMessage = "Exported \(written.count) file(s) to \(destination.lastPathComponent)."
            } catch is CancellationError {
                resultMessage = "Export cancelled."
            } catch {
                resultMessage = "Export failed: \(error)"
            }
            progress = nil
            exportTask = nil
        }
    }
}
