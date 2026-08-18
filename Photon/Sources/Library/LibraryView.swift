import SwiftUI
import PhotonCore

/// The Library module: sidebar (folders, collections), filter bar, thumbnail grid,
/// metadata panel.
struct LibraryView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            LibrarySidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                FilterSortBar()
                Divider()
                HSplitView {
                    PhotoGridView()
                        .frame(minWidth: 400)
                    MetadataPanel()
                        .frame(width: 280)
                }
            }
        }
    }
}

struct LibrarySidebar: View {
    @Environment(AppState.self) private var appState
    @State private var newCollectionName = ""
    @State private var isAddingCollection = false

    var body: some View {
        @Bindable var state = appState
        List {
            Section("Catalog") {
                Label("All Photos", systemImage: "photo.stack")
                    .tag(nil as Int64?)
                    .onTapGesture {
                        state.selectedFolderID = nil
                        state.selectedCollectionID = nil
                    }
            }
            Section("Folders") {
                ForEach(appState.folders) { folder in
                    Label(folder.name, systemImage: "folder")
                        .fontWeight(appState.selectedFolderID == folder.id ? .semibold : .regular)
                        .onTapGesture {
                            state.selectedCollectionID = nil
                            state.selectedFolderID = folder.id
                        }
                }
            }
            Section {
                ForEach(appState.collections) { collection in
                    Label(collection.name,
                          systemImage: collection.isSmart ? "gearshape" : "rectangle.stack")
                        .fontWeight(appState.selectedCollectionID == collection.id
                                    ? .semibold : .regular)
                        .onTapGesture {
                            state.selectedFolderID = nil
                            state.selectedCollectionID = collection.id
                        }
                        .contextMenu {
                            Button("Delete Collection", role: .destructive) {
                                Task {
                                    try? await appState.catalog?.deleteCollection(id: collection.id)
                                    await appState.reloadSidebar()
                                }
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Collections")
                    Spacer()
                    Button {
                        isAddingCollection = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
        .alert("New Collection", isPresented: $isAddingCollection) {
            TextField("Name", text: $newCollectionName)
            Button("Create") {
                let name = newCollectionName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task {
                    _ = try? await appState.catalog?.createCollection(name: name)
                    await appState.reloadSidebar()
                }
                newCollectionName = ""
            }
            Button("Cancel", role: .cancel) { newCollectionName = "" }
        }
    }
}
