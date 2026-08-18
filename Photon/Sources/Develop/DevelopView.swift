import SwiftUI
import PhotonCore

/// The Develop module: canvas centre, histogram + panel stack right, filmstrip bottom.
struct DevelopView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    if let session = appState.editSession {
                        CanvasView(session: session)
                        CanvasToolbar(session: session)
                    } else {
                        ContentUnavailableView("Select a photo to edit",
                                               systemImage: "slider.horizontal.3")
                    }
                }
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.12))

                DevelopPanelStack()
                    .frame(width: 300)
            }
            Divider()
            FilmstripView()
                .frame(height: 96)
        }
    }
}

/// Under-canvas controls: before/after, split compare, zoom, unsupported-format notice.
struct CanvasToolbar: View {
    @Bindable var session: EditSession

    var body: some View {
        HStack(spacing: 16) {
            Toggle(isOn: $session.showBefore) {
                Label("Before", systemImage: "arrow.counterclockwise")
            }
            .toggleStyle(.button)
            .help("Show the unedited photo (\\)")

            Toggle(isOn: $session.splitCompare) {
                Label("Split", systemImage: "rectangle.split.2x1")
            }
            .toggleStyle(.button)
            .help("Side-by-side before/after")

            if session.previewIsDraft {
                Label("Drafting…", systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let reason = session.unsupportedReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            Text(session.photo.fileName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.25))
    }
}

/// The right-hand stack of develop panels, Lightroom order.
struct DevelopPanelStack: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            if let session = appState.editSession {
                VStack(spacing: 1) {
                    HistogramView(session: session)
                        .frame(height: 120)
                        .padding(.bottom, 4)
                    BasicPanel(session: session)
                    ToneCurvePanel(session: session)
                    HSLPanel(session: session)
                    ColorGradingPanel(session: session)
                    DetailPanel(session: session)
                    LensCorrectionsPanel(session: session)
                    TransformPanel(session: session)
                    EffectsPanel(session: session)
                    CalibrationPanel(session: session)
                    CropPanel(session: session)
                    SpotRemovalPanel(session: session)
                    HistoryPanel(session: session)
                }
                .padding(.bottom, 20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Collapsible panel chrome shared by every develop panel.
struct DevelopPanel<Content: View>: View {
    let title: String
    var resetAction: (() -> Void)?
    @ViewBuilder let content: Content
    @State private var expanded: Bool

    init(title: String, expandedByDefault: Bool = false, resetAction: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.resetAction = resetAction
        self.content = content()
        _expanded = State(initialValue: expandedByDefault)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let resetAction {
                    Button("Reset") { resetAction() }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
            .background(Color(nsColor: .controlBackgroundColor))

            if expanded {
                VStack(spacing: 6) {
                    content
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
}
