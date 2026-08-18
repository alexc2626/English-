import SwiftUI
import PhotonCore

/// A develop slider: label, value readout, drag-coalesced history, double-click reset.
/// Mirrors Lightroom slider behaviour — dragging renders drafts, releasing commits one
/// history step and triggers a full-quality render.
struct SliderRow: View {
    let label: String
    let range: ClosedRange<Double>
    var defaultValue: Double = 0
    var format: String = "%+.0f"
    let session: EditSession
    /// Reads the current value from settings.
    let get: (DevelopSettings) -> Double
    /// Writes a new value into settings.
    let set: (inout DevelopSettings, Double) -> Void

    var body: some View {
        let value = get(session.settings)
        VStack(spacing: 1) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                Spacer()
                Text(displayValue(value))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(value == defaultValue ? .secondary : .primary)
            }
            Slider(
                value: Binding(
                    get: { get(session.settings) },
                    set: { newValue in
                        session.update(label) { set(&$0, snap(newValue)) }
                    }
                ),
                in: range,
                onEditingChanged: { editing in
                    if !editing { session.endGesture() }
                }
            )
            .controlSize(.small)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            session.update(label) { set(&$0, defaultValue) }
            session.endGesture()
        }
    }

    /// Snap near-zero drags to exactly the default so "untouched" state is reachable.
    private func snap(_ v: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        return abs(v - defaultValue) < span * 0.004 ? defaultValue : v
    }

    private func displayValue(_ v: Double) -> String {
        String(format: format, v)
    }
}
