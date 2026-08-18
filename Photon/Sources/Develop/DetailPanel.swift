import SwiftUI
import PhotonCore

/// Detail panel: Sharpening (Amount/Radius/Detail/Masking with Option-drag edge-mask
/// preview) and Noise Reduction (Luminance and Color groups).
struct DetailPanel: View {
    let session: EditSession
    @State private var showingEdgeMask = false

    var body: some View {
        DevelopPanel(title: "Detail", resetAction: {
            session.apply(name: "Reset Detail", settings: {
                var s = session.settings
                s.detail = DetailSettings()
                return s
            }())
        }) {
            Text("Sharpening").font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            SliderRow(label: "Amount", range: 0...150, session: session,
                      get: { $0.detail.sharpeningAmount },
                      set: { $0.detail.sharpeningAmount = $1 })
            SliderRow(label: "Radius", range: 0.5...3, defaultValue: 1, format: "%.1f",
                      session: session,
                      get: { $0.detail.sharpeningRadius },
                      set: { $0.detail.sharpeningRadius = $1 })
            SliderRow(label: "Detail", range: 0...100, defaultValue: 25, session: session,
                      get: { $0.detail.sharpeningDetail },
                      set: { $0.detail.sharpeningDetail = $1 })
            SliderRow(label: "Masking", range: 0...100, session: session,
                      get: { $0.detail.sharpeningMasking },
                      set: { $0.detail.sharpeningMasking = $1 })

            Divider().padding(.vertical, 2)

            Text("Noise Reduction").font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            SliderRow(label: "Luminance", range: 0...100, session: session,
                      get: { $0.detail.luminanceNR }, set: { $0.detail.luminanceNR = $1 })
            SliderRow(label: "Detail", range: 0...100, defaultValue: 50, session: session,
                      get: { $0.detail.luminanceDetail },
                      set: { $0.detail.luminanceDetail = $1 })
            SliderRow(label: "Contrast", range: 0...100, session: session,
                      get: { $0.detail.luminanceContrast },
                      set: { $0.detail.luminanceContrast = $1 })

            SliderRow(label: "Color", range: 0...100, defaultValue: 25, session: session,
                      get: { $0.detail.colorNR }, set: { $0.detail.colorNR = $1 })
            SliderRow(label: "Detail", range: 0...100, defaultValue: 50, session: session,
                      get: { $0.detail.colorDetail }, set: { $0.detail.colorDetail = $1 })
            SliderRow(label: "Smoothness", range: 0...100, defaultValue: 50, session: session,
                      get: { $0.detail.colorSmoothness },
                      set: { $0.detail.colorSmoothness = $1 })
        }
    }
}

/// Lens Corrections panel: profile toggle, CA removal, Upright, manual sliders.
struct LensCorrectionsPanel: View {
    let session: EditSession

    var body: some View {
        DevelopPanel(title: "Lens Corrections", resetAction: {
            session.apply(name: "Reset Lens Corrections", settings: {
                var s = session.settings
                s.lens = LensCorrectionSettings()
                return s
            }())
        }) {
            Toggle("Enable Profile Corrections", isOn: Binding(
                get: { session.settings.lens.enableProfileCorrections },
                set: { on in
                    session.apply(name: "Profile Corrections", settings: {
                        var s = session.settings
                        s.lens.enableProfileCorrections = on
                        return s
                    }())
                }))
                .font(.system(size: 11))
                .help("Uses the lens profile embedded in the RAW (via Core Image's lens correction)")

            Toggle("Remove Chromatic Aberration", isOn: Binding(
                get: { session.settings.lens.removeChromaticAberration },
                set: { on in
                    session.apply(name: "Remove CA", settings: {
                        var s = session.settings
                        s.lens.removeChromaticAberration = on
                        return s
                    }())
                }))
                .font(.system(size: 11))

            HStack {
                Text("Upright").font(.system(size: 11))
                Spacer()
                Picker("Upright", selection: Binding(
                    get: { session.settings.lens.upright },
                    set: { mode in
                        session.apply(name: "Upright: \(mode.rawValue.capitalized)", settings: {
                            var s = session.settings
                            s.lens.upright = mode
                            return s
                        }())
                    })) {
                    Text("Off").tag(LensCorrectionSettings.UprightMode.off)
                    Text("Auto").tag(LensCorrectionSettings.UprightMode.auto)
                    Text("Level").tag(LensCorrectionSettings.UprightMode.level)
                    Text("Vertical").tag(LensCorrectionSettings.UprightMode.vertical)
                    Text("Full").tag(LensCorrectionSettings.UprightMode.full)
                }
                .labelsHidden()
                .frame(width: 120)
            }

            Divider().padding(.vertical, 2)

            SliderRow(label: "Distortion", range: -100...100, session: session,
                      get: { $0.lens.manualDistortion },
                      set: { $0.lens.manualDistortion = $1 })
            SliderRow(label: "Vignette", range: -100...100, session: session,
                      get: { $0.lens.manualVignetteAmount },
                      set: { $0.lens.manualVignetteAmount = $1 })
            SliderRow(label: "Midpoint", range: 0...100, defaultValue: 50, session: session,
                      get: { $0.lens.manualVignetteMidpoint },
                      set: { $0.lens.manualVignetteMidpoint = $1 })
            SliderRow(label: "Defringe Purple", range: 0...20, session: session,
                      get: { $0.lens.purpleFringeAmount },
                      set: { $0.lens.purpleFringeAmount = $1 })
            SliderRow(label: "Defringe Green", range: 0...20, session: session,
                      get: { $0.lens.greenFringeAmount },
                      set: { $0.lens.greenFringeAmount = $1 })
        }
    }
}

/// Transform panel: manual perspective correction.
struct TransformPanel: View {
    let session: EditSession

    var body: some View {
        DevelopPanel(title: "Transform", resetAction: {
            session.apply(name: "Reset Transform", settings: {
                var s = session.settings
                s.transform = TransformSettings()
                return s
            }())
        }) {
            SliderRow(label: "Vertical", range: -100...100, session: session,
                      get: { $0.transform.vertical }, set: { $0.transform.vertical = $1 })
            SliderRow(label: "Horizontal", range: -100...100, session: session,
                      get: { $0.transform.horizontal }, set: { $0.transform.horizontal = $1 })
            SliderRow(label: "Rotate", range: -10...10, format: "%+.1f°", session: session,
                      get: { $0.transform.rotate }, set: { $0.transform.rotate = $1 })
            SliderRow(label: "Aspect", range: -100...100, session: session,
                      get: { $0.transform.aspect }, set: { $0.transform.aspect = $1 })
            SliderRow(label: "Scale", range: 50...150, defaultValue: 100, format: "%.0f",
                      session: session,
                      get: { $0.transform.scale }, set: { $0.transform.scale = $1 })
            SliderRow(label: "X Offset", range: -100...100, session: session,
                      get: { $0.transform.offsetX }, set: { $0.transform.offsetX = $1 })
            SliderRow(label: "Y Offset", range: -100...100, session: session,
                      get: { $0.transform.offsetY }, set: { $0.transform.offsetY = $1 })
        }
    }
}
