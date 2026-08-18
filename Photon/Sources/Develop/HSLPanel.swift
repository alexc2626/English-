import SwiftUI
import PhotonCore

/// HSL / Color panel: Hue / Saturation / Luminance per the 8 standard bands, plus the
/// B&W conversion mix mode (mirrors Lightroom's HSL <-> B&W panel switch).
struct HSLPanel: View {
    let session: EditSession
    @State private var tab: Tab = .hue

    enum Tab: String, CaseIterable {
        case hue = "Hue"
        case saturation = "Saturation"
        case luminance = "Luminance"
    }

    private var isBW: Bool { session.settings.blackAndWhite != nil }

    var body: some View {
        DevelopPanel(title: isBW ? "B&W" : "HSL / Color", resetAction: {
            session.apply(name: "Reset HSL", settings: {
                var s = session.settings
                s.hsl = HSLAdjustments()
                if s.blackAndWhite != nil { s.blackAndWhite = BlackAndWhiteMix() }
                return s
            }())
        }) {
            Picker("Mode", selection: Binding(
                get: { isBW ? 1 : 0 },
                set: { mode in
                    session.apply(name: mode == 1 ? "Convert to B&W" : "Convert to Color",
                                  settings: {
                        var s = session.settings
                        s.blackAndWhite = mode == 1 ? BlackAndWhiteMix() : nil
                        return s
                    }())
                })) {
                Text("Color").tag(0)
                Text("B&W").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if isBW {
                bwMixSliders
            } else {
                Picker("Component", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                hslSliders
            }
        }
    }

    @ViewBuilder private var hslSliders: some View {
        ForEach(HSLRemap.orderedBandsPublic, id: \.self) { band in
            SliderRow(
                label: band.rawValue.capitalized,
                range: -100...100,
                session: session,
                get: { settings in
                    switch tab {
                    case .hue: return settings.hsl.hue[band] ?? 0
                    case .saturation: return settings.hsl.saturation[band] ?? 0
                    case .luminance: return settings.hsl.luminance[band] ?? 0
                    }
                },
                set: { settings, value in
                    switch tab {
                    case .hue: settings.hsl.hue[band] = value
                    case .saturation: settings.hsl.saturation[band] = value
                    case .luminance: settings.hsl.luminance[band] = value
                    }
                }
            )
        }
    }

    @ViewBuilder private var bwMixSliders: some View {
        ForEach(HSLRemap.orderedBandsPublic, id: \.self) { band in
            SliderRow(
                label: band.rawValue.capitalized,
                range: -100...100,
                session: session,
                get: { $0.blackAndWhite?.mix[band] ?? 0 },
                set: { settings, value in
                    var mix = settings.blackAndWhite ?? BlackAndWhiteMix()
                    mix.mix[band] = value
                    settings.blackAndWhite = mix
                }
            )
        }
    }
}

extension HSLRemap {
    /// UI-facing band order (the internal one is not public API).
    public static var orderedBandsPublic: [ColorBand] {
        [.red, .orange, .yellow, .green, .aqua, .blue, .purple, .magenta]
    }
}
