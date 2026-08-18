import SwiftUI
import PhotonCore

/// History & Snapshots panel: the linear per-photo history stack (click any step to return
/// to it) and named snapshots.
struct HistoryPanel: View {
    let session: EditSession
    @State private var isNamingSnapshot = false
    @State private var snapshotName = ""

    var body: some View {
        DevelopPanel(title: "History", expandedByDefault: false) {
            // Snapshots
            HStack {
                Text("Snapshots").font(.system(size: 11, weight: .medium))
                Spacer()
                Button {
                    snapshotName = "Snapshot \(session.stack.snapshots.count + 1)"
                    isNamingSnapshot = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Save the current state as a named snapshot")
            }

            if session.stack.snapshots.isEmpty {
                Text("No snapshots").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(session.stack.snapshots) { snapshot in
                    HStack {
                        Image(systemName: "camera.on.rectangle").font(.caption2)
                        Text(snapshot.name).font(.caption)
                        Spacer()
                        Text(snapshot.date.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { session.restoreSnapshot(snapshot.id) }
                }
            }

            Divider().padding(.vertical, 2)

            // History steps, newest first, current step highlighted.
            let entries = Array(session.stack.history.enumerated().reversed())
            ForEach(entries, id: \.element.id) { index, entry in
                HStack {
                    Text(entry.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(index == session.stack.cursor
                              ? Color.accentColor.opacity(0.25) : .clear)
                )
                .contentShape(Rectangle())
                .onTapGesture { session.jump(to: entry.id) }
            }
        }
        .alert("New Snapshot", isPresented: $isNamingSnapshot) {
            TextField("Name", text: $snapshotName)
            Button("Save") {
                session.addSnapshot(named: snapshotName)
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
