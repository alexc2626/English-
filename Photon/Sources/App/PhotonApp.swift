import SwiftUI

@main
struct PhotonApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 1100, minHeight: 700)
                .task { await appState.bootstrap() }
        }
        .windowStyle(.titleBar)
        .commands {
            PhotonCommands(appState: appState)
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

/// App menu commands with Lightroom-familiar shortcuts.
struct PhotonCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import Photos…") { appState.isImportDialogPresented = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Export…") { appState.isExportDialogPresented = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandMenu("Photo") {
            Button("Toggle Flag (Pick)") { appState.setFlagOnSelection(.pick) }
                .keyboardShortcut("p", modifiers: [])
            Button("Reject") { appState.setFlagOnSelection(.reject) }
                .keyboardShortcut("x", modifiers: [])
            Divider()
            ForEach(0...5, id: \.self) { stars in
                Button(stars == 0 ? "No Rating" : String(repeating: "★", count: stars)) {
                    appState.setRatingOnSelection(stars)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(stars)")), modifiers: [])
            }
            Divider()
            Button("Create Virtual Copy") { appState.createVirtualCopy() }
                .keyboardShortcut("'", modifiers: [.command])
            Divider()
            Button("Merge to HDR…") { appState.compositeMode = .hdr }
                .keyboardShortcut("h", modifiers: [.command, .control])
            Button("Merge to Panorama…") { appState.compositeMode = .panorama }
                .keyboardShortcut("m", modifiers: [.command, .control])
            Button("Focus Stack…") { appState.compositeMode = .focusStack }
        }
        CommandMenu("Develop") {
            Button("Copy Settings") { appState.copySettings() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Paste Settings") { appState.pasteSettings() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Sync Settings…") { appState.isSyncDialogPresented = true }
            Divider()
            Button("Undo Edit") { appState.editSession?.undo() }
                .keyboardShortcut("z", modifiers: [.command])
            Button("Redo Edit") { appState.editSession?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Divider()
            Button("Reset All Settings") { appState.editSession?.reset() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Before / After") { appState.editSession?.showBefore.toggle() }
                .keyboardShortcut("\\", modifiers: [])
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent("Location", value: appState.libraryURL?.path ?? "Not selected")
                Button("Choose Library Folder…") { appState.chooseLibraryFolder() }
            }
            Section {
                Text("Photon never makes network requests. Catalog, previews, presets and edit history are all local files under your library folder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
