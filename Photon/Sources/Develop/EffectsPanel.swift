import SwiftUI
import PhotonCore

/// Effects panel: post-crop vignette and film grain.
struct EffectsPanel: View {
    let session: EditSession

    var body: some View {
        DevelopPanel(title: "Effects", resetAction: {
            session.apply(name: "Reset Effects", settings: {
                var s = session.settings
                s.effects = EffectsSettings()
                return s
            }())
        }) {
            Text("Post-Crop Vignetting").font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            SliderRow(label: "Amount", range: -100...100, session: session,
                      get: { $0.effects.vignetteAmount },
                      set: { $0.effects.vignetteAmount = $1 })
            SliderRow(label: "Midpoint", range: 0...100, defaultValue: 50, session: session,
                      get: { $0.effects.vignetteMidpoint },
                      set: { $0.effects.vignetteMidpoint = $1 })
            SliderRow(label: "Roundness", range: -100...100, session: session,
                      get: { $0.effects.vignetteRoundness },
                      set: { $0.effects.vignetteRoundness = $1 })
            SliderRow(label: "Feather", range: 0...100, defaultValue: 50, session: session,
                      get: { $0.effects.vignetteFeather },
                      set: { $0.effects.vignetteFeather = $1 })
            SliderRow(label: "Highlights", range: 0...100, session: session,
                      get: { $0.effects.vignetteHighlights },
                      set: { $0.effects.vignetteHighlights = $1 })

            Divider().padding(.vertical, 2)

            Text("Grain").font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            SliderRow(label: "Amount", range: 0...100, session: session,
                      get: { $0.effects.grainAmount }, set: { $0.effects.grainAmount = $1 })
            SliderRow(label: "Size", range: 0...100, defaultValue: 25, session: session,
                      get: { $0.effects.grainSize }, set: { $0.effects.grainSize = $1 })
            SliderRow(label: "Roughness", range: 0...100, defaultValue: 50, session: session,
                      get: { $0.effects.grainRoughness },
                      set: { $0.effects.grainRoughness = $1 })
        }
    }
}

/// Calibration panel: camera profile and RGB primaries hue/saturation shifts.
struct CalibrationPanel: View {
    let session: EditSession

    private let profiles = ["Embedded", "Neutral", "Vivid", "Portrait", "Landscape"]

    var body: some View {
        DevelopPanel(title: "Calibration", resetAction: {
            session.apply(name: "Reset Calibration", settings: {
                var s = session.settings
                s.calibration = CalibrationSettings()
                return s
            }())
        }) {
            HStack {
                Text("Profile").font(.system(size: 11))
                Spacer()
                Picker("Profile", selection: Binding(
                    get: { session.settings.calibration.profile },
                    set: { profile in
                        session.apply(name: "Profile: \(profile)", settings: {
                            var s = session.settings
                            s.calibration.profile = profile
                            return s
                        }())
                    })) {
                    ForEach(profiles, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
            }

            SliderRow(label: "Shadow Tint", range: -100...100, session: session,
                      get: { $0.calibration.shadowTint },
                      set: { $0.calibration.shadowTint = $1 })

            Text("Red Primary").font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            SliderRow(label: "Hue", range: -100...100, session: session,
                      get: { $0.calibration.redHue }, set: { $0.calibration.redHue = $1 })
            SliderRow(label: "Saturation", range: -100...100, session: session,
                      get: { $0.calibration.redSaturation },
                      set: { $0.calibration.redSaturation = $1 })

            Text("Green Primary").font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            SliderRow(label: "Hue", range: -100...100, session: session,
                      get: { $0.calibration.greenHue }, set: { $0.calibration.greenHue = $1 })
            SliderRow(label: "Saturation", range: -100...100, session: session,
                      get: { $0.calibration.greenSaturation },
                      set: { $0.calibration.greenSaturation = $1 })

            Text("Blue Primary").font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            SliderRow(label: "Hue", range: -100...100, session: session,
                      get: { $0.calibration.blueHue }, set: { $0.calibration.blueHue = $1 })
            SliderRow(label: "Saturation", range: -100...100, session: session,
                      get: { $0.calibration.blueSaturation },
                      set: { $0.calibration.blueSaturation = $1 })
        }
    }
}
