import SwiftUI
import PhotonCore

/// The Basic panel: White Balance (with eyedropper), tone, and presence — every slider
/// live-rendering and non-destructive.
struct BasicPanel: View {
    let session: EditSession
    @State private var wbPickerActive = false

    var body: some View {
        DevelopPanel(title: "Basic", expandedByDefault: true, resetAction: {
            session.apply(name: "Reset Basic", settings: {
                var s = session.settings
                s.basic = BasicAdjustments()
                return s
            }())
        }) {
            // MARK: White balance
            HStack {
                Text("White Balance").font(.system(size: 11, weight: .medium))
                Spacer()
                Button {
                    wbPickerActive.toggle()
                } label: {
                    Image(systemName: "eyedropper")
                        .foregroundStyle(wbPickerActive ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("White balance eyedropper: click a neutral grey in the photo")
                Menu(session.settings.basic.whiteBalanceIsAsShot ? "As Shot" : "Custom") {
                    Button("As Shot") {
                        session.update("White Balance: As Shot") {
                            $0.basic.whiteBalanceIsAsShot = true
                            $0.basic.temperature = 6500
                            $0.basic.tint = 0
                        }
                        session.endGesture()
                    }
                    Button("Daylight") { setWB(5500, 10) }
                    Button("Cloudy") { setWB(6500, 10) }
                    Button("Shade") { setWB(7500, 10) }
                    Button("Tungsten") { setWB(2850, 0) }
                    Button("Fluorescent") { setWB(3800, 21) }
                    Button("Flash") { setWB(5500, 0) }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 90)
            }

            SliderRow(label: "Temp", range: 2000...50000, defaultValue: 6500,
                      format: "%.0fK", session: session,
                      get: { $0.basic.temperature },
                      set: { s, v in
                          s.basic.temperature = v
                          s.basic.whiteBalanceIsAsShot = false
                      })
            SliderRow(label: "Tint", range: -150...150, session: session,
                      get: { $0.basic.tint },
                      set: { s, v in
                          s.basic.tint = v
                          s.basic.whiteBalanceIsAsShot = false
                      })

            Divider().padding(.vertical, 2)

            // MARK: Tone
            SliderRow(label: "Exposure", range: -5...5, format: "%+.2f", session: session,
                      get: { $0.basic.exposure }, set: { $0.basic.exposure = $1 })
            SliderRow(label: "Contrast", range: -100...100, session: session,
                      get: { $0.basic.contrast }, set: { $0.basic.contrast = $1 })
            SliderRow(label: "Highlights", range: -100...100, session: session,
                      get: { $0.basic.highlights }, set: { $0.basic.highlights = $1 })
            SliderRow(label: "Shadows", range: -100...100, session: session,
                      get: { $0.basic.shadows }, set: { $0.basic.shadows = $1 })
            SliderRow(label: "Whites", range: -100...100, session: session,
                      get: { $0.basic.whites }, set: { $0.basic.whites = $1 })
            SliderRow(label: "Blacks", range: -100...100, session: session,
                      get: { $0.basic.blacks }, set: { $0.basic.blacks = $1 })

            Divider().padding(.vertical, 2)

            // MARK: Presence
            SliderRow(label: "Texture", range: -100...100, session: session,
                      get: { $0.basic.texture }, set: { $0.basic.texture = $1 })
            SliderRow(label: "Clarity", range: -100...100, session: session,
                      get: { $0.basic.clarity }, set: { $0.basic.clarity = $1 })
            SliderRow(label: "Dehaze", range: -100...100, session: session,
                      get: { $0.basic.dehaze }, set: { $0.basic.dehaze = $1 })

            Divider().padding(.vertical, 2)

            SliderRow(label: "Vibrance", range: -100...100, session: session,
                      get: { $0.basic.vibrance }, set: { $0.basic.vibrance = $1 })
            SliderRow(label: "Saturation", range: -100...100, session: session,
                      get: { $0.basic.saturation }, set: { $0.basic.saturation = $1 })
        }
    }

    private func setWB(_ temp: Double, _ tint: Double) {
        session.update("White Balance") {
            $0.basic.temperature = temp
            $0.basic.tint = tint
            $0.basic.whiteBalanceIsAsShot = false
        }
        session.endGesture()
    }
}
