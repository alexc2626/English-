import SwiftUI
import PhotonCore

/// Right-hand metadata panel: EXIF summary, IPTC-style fields, keywords editor.
struct MetadataPanel: View {
    @Environment(AppState.self) private var appState
    @State private var photoKeywords: [KeywordRecord] = []
    @State private var newKeyword = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let photo = appState.activePhoto {
                    metadataSection(photo)
                    keywordSection(photo)
                } else {
                    Text("No photo selected")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: appState.activePhotoID) {
            guard let id = appState.activePhotoID else {
                photoKeywords = []
                return
            }
            photoKeywords = (try? await appState.catalog?.keywords(photoID: id)) ?? []
        }
    }

    @ViewBuilder
    private func metadataSection(_ photo: PhotoRecord) -> some View {
        GroupBox("Metadata") {
            VStack(alignment: .leading, spacing: 6) {
                metaRow("File", photo.fileName)
                metaRow("Folder", URL(fileURLWithPath: photo.filePath)
                    .deletingLastPathComponent().lastPathComponent)
                if let date = photo.captureDate {
                    metaRow("Captured", date.formatted(date: .abbreviated, time: .shortened))
                }
                metaRow("Dimensions", "\(photo.pixelWidth) × \(photo.pixelHeight)")
                if !photo.cameraModel.isEmpty {
                    metaRow("Camera", photo.cameraModel)
                }
                if !photo.lensModel.isEmpty {
                    metaRow("Lens", photo.lensModel)
                }
                HStack(spacing: 12) {
                    if let iso = photo.iso { metaValue("ISO \(iso)") }
                    if let f = photo.aperture { metaValue(String(format: "f/%.1f", f)) }
                    if let s = photo.shutterSpeed { metaValue(shutterLabel(s)) }
                    if let mm = photo.focalLength { metaValue(String(format: "%.0fmm", mm)) }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func keywordSection(_ photo: PhotoRecord) -> some View {
        GroupBox("Keywords") {
            VStack(alignment: .leading, spacing: 8) {
                FlowLayout(spacing: 4) {
                    ForEach(photoKeywords) { keyword in
                        HStack(spacing: 2) {
                            Text(keyword.name).font(.caption)
                            Button {
                                Task {
                                    try? await appState.catalog?.untag(
                                        photoID: photo.id, keywordID: keyword.id)
                                    photoKeywords.removeAll { $0.id == keyword.id }
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
                TextField("Add keyword…", text: $newKeyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let word = newKeyword.trimmingCharacters(in: .whitespaces)
                        guard !word.isEmpty else { return }
                        Task {
                            try? await appState.catalog?.tag(photoID: photo.id, keyword: word)
                            photoKeywords = (try? await appState.catalog?.keywords(
                                photoID: photo.id)) ?? photoKeywords
                            await appState.reloadSidebar()
                        }
                        newKeyword = ""
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    private func metaValue(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func shutterLabel(_ seconds: Double) -> String {
        seconds >= 1 ? String(format: "%.1fs", seconds)
            : "1/\(Int((1 / seconds).rounded()))s"
    }
}

/// Simple wrapping layout for keyword chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
