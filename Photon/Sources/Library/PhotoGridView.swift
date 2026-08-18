import SwiftUI
import PhotonCore

/// Thumbnail grid with async thumbnail loading, multi-selection, ratings/flags/labels
/// badges, and double-click into Develop.
struct PhotoGridView: View {
    @Environment(AppState.self) private var appState
    @State private var thumbSize: CGFloat = 180

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: thumbSize, maximum: thumbSize * 1.4), spacing: 8)]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(appState.photos) { photo in
                        PhotoCell(photo: photo,
                                  isSelected: appState.selection.contains(photo.id),
                                  isActive: appState.activePhotoID == photo.id)
                            .onTapGesture(count: 2) {
                                appState.openInDevelop(photoID: photo.id)
                            }
                            .onTapGesture {
                                select(photo: photo)
                            }
                            .contextMenu { PhotoContextMenu(photo: photo) }
                    }
                }
                .padding(8)
            }
            Divider()
            HStack {
                Text("\(appState.photos.count) photos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if appState.selection.count > 1 {
                    Text("· \(appState.selection.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Slider(value: $thumbSize, in: 90...320) {
                    Text("Thumbnail Size")
                }
                .frame(width: 160)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func select(photo: PhotoRecord) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            if appState.selection.contains(photo.id) {
                appState.selection.remove(photo.id)
            } else {
                appState.selection.insert(photo.id)
            }
        } else if modifiers.contains(.shift), let anchor = appState.activePhotoID,
                  let a = appState.photos.firstIndex(where: { $0.id == anchor }),
                  let b = appState.photos.firstIndex(where: { $0.id == photo.id }) {
            let range = min(a, b)...max(a, b)
            appState.selection = Set(appState.photos[range].map(\.id))
        } else {
            appState.selection = [photo.id]
        }
        appState.activePhotoID = photo.id
    }
}

struct PhotoCell: View {
    @Environment(AppState.self) private var appState
    let photo: PhotoRecord
    let isSelected: Bool
    let isActive: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .controlBackgroundColor))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    ProgressView().controlSize(.small)
                }
                badges
            }
            .aspectRatio(1.25, contentMode: .fit)

            HStack(spacing: 4) {
                if photo.rating > 0 {
                    Text(String(repeating: "★", count: photo.rating))
                        .font(.system(size: 9))
                        .foregroundStyle(.yellow)
                }
                Text(photo.fileName)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                if let label = photo.colorLabel {
                    Circle()
                        .fill(label.swatch)
                        .frame(width: 8, height: 8)
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(isActive ? 0.35 : 0.2) : .clear)
        )
        .task(id: photo.id) {
            thumbnail = await appState.thumbnails?.thumbnail(
                for: photo.uuid, sourceURL: photo.fileURL)
        }
    }

    @ViewBuilder private var badges: some View {
        VStack {
            HStack {
                if photo.flag == .pick {
                    Image(systemName: "flag.fill").foregroundStyle(.white).shadow(radius: 2)
                } else if photo.flag == .reject {
                    Image(systemName: "flag.slash.fill").foregroundStyle(.black).shadow(radius: 2)
                }
                Spacer()
                if photo.isVirtualCopy {
                    Image(systemName: "doc.on.doc").foregroundStyle(.white).shadow(radius: 2)
                }
                if photo.sourceKind != .original {
                    Image(systemName: photo.sourceKind.badgeSymbol)
                        .foregroundStyle(.white).shadow(radius: 2)
                }
            }
            .font(.system(size: 10))
            .padding(4)
            Spacer()
        }
    }
}

struct PhotoContextMenu: View {
    @Environment(AppState.self) private var appState
    let photo: PhotoRecord

    var body: some View {
        Button("Edit in Develop") { appState.openInDevelop(photoID: photo.id) }
        Divider()
        Menu("Set Rating") {
            ForEach(0...5, id: \.self) { stars in
                Button(stars == 0 ? "None" : String(repeating: "★", count: stars)) {
                    appState.setRatingOnSelection(stars)
                }
            }
        }
        Menu("Set Color Label") {
            Button("None") { appState.setColorLabelOnSelection(nil) }
            ForEach(PhotoRecord.ColorLabel.allCases, id: \.self) { label in
                Button(label.rawValue.capitalized) { appState.setColorLabelOnSelection(label) }
            }
        }
        Menu("Add to Collection") {
            ForEach(appState.collections.filter { !$0.isSmart }) { collection in
                Button(collection.name) {
                    Task {
                        let ids = appState.selection.isEmpty ? [photo.id]
                            : Array(appState.selection)
                        for id in ids {
                            try? await appState.catalog?.addToCollection(
                                collectionID: collection.id, photoID: id)
                        }
                    }
                }
            }
        }
        Divider()
        Button("Create Virtual Copy") { appState.createVirtualCopy() }
        Button("Remove from Catalog", role: .destructive) {
            Task {
                try? await appState.catalog?.removePhoto(id: photo.id)
                await appState.reloadPhotos()
            }
        }
    }
}

extension PhotoRecord.ColorLabel {
    var swatch: Color {
        switch self {
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        }
    }
}

extension PhotoRecord.SourceKind {
    var badgeSymbol: String {
        switch self {
        case .original: return "photo"
        case .focusStack: return "square.3.layers.3d"
        case .hdrMerge: return "plusminus.circle"
        case .panorama: return "pano"
        }
    }
}
