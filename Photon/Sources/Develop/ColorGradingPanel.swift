import SwiftUI
import PhotonCore

/// Color Grading panel: Shadows / Midtones / Highlights / Global colour wheels with
/// per-wheel luminance and the Blending / Balance sliders.
struct ColorGradingPanel: View {
    let session: EditSession
    @State private var focus: WheelFocus = .threeUp

    enum WheelFocus: String, CaseIterable {
        case threeUp = "3-Way"
        case shadows = "Shadows"
        case midtones = "Midtones"
        case highlights = "Highlights"
        case global = "Global"
    }

    var body: some View {
        DevelopPanel(title: "Color Grading", resetAction: {
            session.apply(name: "Reset Color Grading", settings: {
                var s = session.settings
                s.colorGrading = ColorGradingSettings()
                return s
            }())
        }) {
            Picker("Focus", selection: $focus) {
                ForEach(WheelFocus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch focus {
            case .threeUp:
                HStack(spacing: 8) {
                    wheelColumn("Shadows", \.shadows, compact: true)
                    wheelColumn("Midtones", \.midtones, compact: true)
                    wheelColumn("Highlights", \.highlights, compact: true)
                }
            case .shadows: wheelColumn("Shadows", \.shadows, compact: false)
            case .midtones: wheelColumn("Midtones", \.midtones, compact: false)
            case .highlights: wheelColumn("Highlights", \.highlights, compact: false)
            case .global: wheelColumn("Global", \.global, compact: false)
            }

            Divider().padding(.vertical, 2)

            SliderRow(label: "Blending", range: 0...100, defaultValue: 50, session: session,
                      get: { $0.colorGrading.blending }, set: { $0.colorGrading.blending = $1 })
            SliderRow(label: "Balance", range: -100...100, session: session,
                      get: { $0.colorGrading.balance }, set: { $0.colorGrading.balance = $1 })
        }
    }

    @ViewBuilder
    private func wheelColumn(_ title: String,
                             _ keyPath: WritableKeyPath<ColorGradingSettings, ColorGradingSettings.Wheel>,
                             compact: Bool) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: compact ? 9 : 11)).foregroundStyle(.secondary)
            ColorWheel(
                wheel: session.settings.colorGrading[keyPath: keyPath],
                diameter: compact ? 72 : 160,
                onChange: { hue, sat in
                    session.update("\(title) Color") { s in
                        s.colorGrading[keyPath: keyPath].hue = hue
                        s.colorGrading[keyPath: keyPath].saturation = sat
                    }
                },
                onEnd: { session.endGesture() }
            )
            SliderRow(label: "Luminance", range: -100...100, session: session,
                      get: { $0.colorGrading[keyPath: keyPath].luminance },
                      set: { $0.colorGrading[keyPath: keyPath].luminance = $1 })
        }
        .frame(maxWidth: .infinity)
    }
}

/// A hue/saturation colour wheel: angle = hue, radius = saturation.
struct ColorWheel: View {
    let wheel: ColorGradingSettings.Wheel
    let diameter: CGFloat
    let onChange: (Double, Double) -> Void
    let onEnd: () -> Void

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    AngularGradient(colors: [
                        .red, .yellow, .green, .cyan, .blue, .purple, .red
                    ], center: .center)
                )
                .overlay(
                    Circle().fill(
                        RadialGradient(colors: [Color(white: 0.5), .clear],
                                       center: .center,
                                       startRadius: 0, endRadius: diameter / 2)
                    )
                )
                .frame(width: diameter, height: diameter)

            // Thumb
            let rad = wheel.hue * .pi / 180
            let r = CGFloat(wheel.saturation / 100) * diameter / 2
            Circle()
                .strokeBorder(Color.white, lineWidth: 2)
                .background(Circle().fill(.black.opacity(0.3)))
                .frame(width: 12, height: 12)
                .offset(x: cos(rad) * r, y: -sin(rad) * r)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let dx = value.location.x - diameter / 2
                    let dy = -(value.location.y - diameter / 2)
                    var hue = atan2(dy, dx) * 180 / .pi
                    if hue < 0 { hue += 360 }
                    let sat = min(sqrt(dx * dx + dy * dy) / (diameter / 2), 1) * 100
                    onChange(Double(hue), Double(sat))
                }
                .onEnded { _ in onEnd() }
        )
        .frame(width: diameter, height: diameter)
    }
}
