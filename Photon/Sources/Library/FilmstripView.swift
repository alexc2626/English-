import SwiftUI
import PhotonCore

/// Bottom filmstrip, shared by Library and Develop: horizontal thumbnails of the current
/// photo list with the active photo highlighted; clicking switches the develop session.
struct FilmstripView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(appState.photos) { photo in
                        FilmstripCell(photo: photo,
                                      isActive: appState.activePhotoID == photo.id)
                            .id(photo.id)
                            .onTapGesture {
                                let modifiers = NSEvent.modifierFlags
                                if modifiers.contains(.command) {
                                    if appState.selection.contains(photo.id) {
                                        appState.selection.remove(photo.id)
                                    } else {
                                        appState.selection.insert(photo.id)
                                    }
                                    appState.activePhotoID = photo.id
                                } else {
                                    appState.selection = [photo.id]
                                    appState.activePhotoID = photo.id
                                    if appState.module == .develop {
                                        Task {
                                            await appState.startEditSession(photoID: photo.id)
                                        }
                                    }
                                }
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: appState.activePhotoID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id) } }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct FilmstripCell: View {
    @Environment(AppState.self) private var appState
    let photo: PhotoRecord
    let isActive: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: .controlBackgroundColor))
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }
        }
        .frame(width: 110, height: 78)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(isActive ? Color.accentColor : .clear, lineWidth: 2)
        )
        .task(id: photo.id) {
            thumbnail = await appState.thumbnails?.thumbnail(
                for: photo.uuid, sourceURL: photo.fileURL)
        }
    }
}
