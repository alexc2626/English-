import SwiftUI
import PhotonCore

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        Group {
            if appState.catalog == nil {
                LibraryPickerPlaceholder()
            } else {
                switch appState.module {
                case .library:
                    LibraryView()
                case .develop:
                    DevelopView()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Module", selection: $state.module) {
                    ForEach(AppState.Module.allCases, id: \.self) { module in
                        Text(module.rawValue).tag(module)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appState.module) { _, newModule in
                    if newModule == .develop, appState.editSession == nil,
                       let id = appState.activePhotoID ?? appState.photos.first?.id {
                        appState.openInDevelop(photoID: id)
                    }
                }
            }
        }
        .sheet(isPresented: $state.isImportDialogPresented) {
            ImportDialog()
        }
        .sheet(isPresented: $state.isSyncDialogPresented) {
            SyncSettingsDialog()
        }
        .sheet(item: $state.compositeMode) { mode in
            CompositeDialog(mode: mode)
        }
        .sheet(isPresented: $state.isExportDialogPresented) {
            ExportDialog()
        }
    }
}

struct LibraryPickerPlaceholder: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ContentUnavailableView {
            Label("No Library Open", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Choose a folder for your Photon library. Everything stays on this Mac.")
        } actions: {
            Button("Choose Library Folder…") { appState.chooseLibraryFolder() }
                .buttonStyle(.borderedProminent)
        }
    }
}
