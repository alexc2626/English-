import SwiftUI
import PhotonCore

/// Crop & Straighten panel: aspect-ratio lock presets, angle slider, inset controls, and
/// grid overlay choice. The crop is stored in normalised source coordinates so it is
/// resolution-independent.
struct CropPanel: View {
    let session: EditSession

    private let aspects: [(String, Double?)] = [
        ("Free", nil), ("Original", -1), ("1 : 1", 1),
        ("4 : 5", 4.0 / 5.0), ("5 : 7", 5.0 / 7.0), ("2 : 3", 2.0 / 3.0),
        ("3 : 2", 3.0 / 2.0), ("16 : 9", 16.0 / 9.0)
    ]

    private var crop: CropSettings {
        session.settings.crop ?? CropSettings()
    }

    var body: some View {
        DevelopPanel(title: "Crop & Straighten", resetAction: {
            session.apply(name: "Reset Crop", settings: {
                var s = session.settings
                s.crop = nil
                return s
            }())
        }) {
            HStack {
                Text("Aspect").font(.system(size: 11))
                Spacer()
                Picker("Aspect", selection: Binding(
                    get: { crop.lockedAspect ?? 0 },
                    set: { newValue in
                        var c = crop
                        if newValue == 0 {
                            c.lockedAspect = nil
                        } else if newValue == -1 {
                            let photo = session.photo
                            let original = photo.pixelHeight > 0
                                ? Double(photo.pixelWidth) / Double(photo.pixelHeight) : 1
                            c.lockedAspect = original
                            c = Self.constrain(c, aspect: original)
                        } else {
                            c.lockedAspect = newValue
                            c = Self.constrain(c, aspect: newValue)
                        }
                        writeCrop(c, name: "Crop Aspect")
                    })) {
                    ForEach(aspects, id: \.0) { name, ratio in
                        Text(name).tag(ratio ?? 0)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }

            SliderRow(label: "Angle", range: -45...45, format: "%+.2f°", session: session,
                      get: { $0.crop?.angle ?? 0 },
                      set: { s, v in
                          var c = s.crop ?? CropSettings()
                          c.angle = v
                          // Shrink the crop to stay inside the rotated frame.
                          s.crop = Self.shrinkForAngle(c)
                      })

            // Numeric inset editing (the canvas overlay offers direct manipulation; these
            // stay authoritative and scriptable).
            SliderRow(label: "Left", range: 0...0.45, format: "%.2f", session: session,
                      get: { $0.crop?.x ?? 0 },
                      set: { s, v in
                          var c = s.crop ?? CropSettings()
                          let right = c.x + c.width
                          c.x = min(v, right - 0.1)
                          c.width = right - c.x
                          s.crop = c
                      })
            SliderRow(label: "Right", range: 0...0.45, format: "%.2f", session: session,
                      get: { 1 - (($0.crop?.x ?? 0) + ($0.crop?.width ?? 1)) },
                      set: { s, v in
                          var c = s.crop ?? CropSettings()
                          c.width = max(1 - v - c.x, 0.1)
                          s.crop = c
                      })
            SliderRow(label: "Top", range: 0...0.45, format: "%.2f", session: session,
                      get: { $0.crop?.y ?? 0 },
                      set: { s, v in
                          var c = s.crop ?? CropSettings()
                          let bottom = c.y + c.height
                          c.y = min(v, bottom - 0.1)
                          c.height = bottom - c.y
                          s.crop = c
                      })
            SliderRow(label: "Bottom", range: 0...0.45, format: "%.2f", session: session,
                      get: { 1 - (($0.crop?.y ?? 0) + ($0.crop?.height ?? 1)) },
                      set: { s, v in
                          var c = s.crop ?? CropSettings()
                          c.height = max(1 - v - c.y, 0.1)
                          s.crop = c
                      })
        }
    }

    private func writeCrop(_ c: CropSettings, name: String) {
        session.apply(name: name, settings: {
            var s = session.settings
            s.crop = c
            return s
        }())
    }

    /// Fit the crop rect to a locked aspect around its centre.
    static func constrain(_ crop: CropSettings, aspect: Double) -> CropSettings {
        var c = crop
        let cx = c.x + c.width / 2
        let cy = c.y + c.height / 2
        // Keep area-ish: adjust the longer dimension down.
        if c.width / c.height > aspect {
            c.width = c.height * aspect
        } else {
            c.height = c.width / aspect
        }
        c.x = min(max(cx - c.width / 2, 0), 1 - c.width)
        c.y = min(max(cy - c.height / 2, 0), 1 - c.height)
        return c
    }

    /// Shrink the crop so a straighten rotation never samples outside the source.
    static func shrinkForAngle(_ crop: CropSettings) -> CropSettings {
        var c = crop
        let rad = abs(c.angle) * .pi / 180
        guard rad > 0 else { return c }
        // Largest axis-aligned rect inside a rotated unit rect (aspect-preserving bound).
        let shrink = 1 / (cos(rad) + sin(rad))
        let cx = c.x + c.width / 2
        let cy = c.y + c.height / 2
        c.width = min(c.width, shrink)
        c.height = min(c.height, shrink)
        c.x = min(max(cx - c.width / 2, 0), 1 - c.width)
        c.y = min(max(cy - c.height / 2, 0), 1 - c.height)
        return c
    }
}

/// Spot Removal panel: heal/clone spots with auto-suggested source patches. Spots are
/// listed here; the canvas places new ones at the view centre for drag-adjustment (numeric
/// nudge controls included for precision).
struct SpotRemovalPanel: View {
    let session: EditSession
    @State private var mode: SpotEdit.Mode = .heal
    @State private var selectedSpotID: UUID?

    var body: some View {
        DevelopPanel(title: "Spot Removal", resetAction: {
            session.apply(name: "Clear Spots", settings: {
                var s = session.settings
                s.spots = []
                return s
            }())
        }) {
            Picker("Mode", selection: $mode) {
                Text("Heal").tag(SpotEdit.Mode.heal)
                Text("Clone").tag(SpotEdit.Mode.clone)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button {
                addSpot()
            } label: {
                Label("Add Spot at Center", systemImage: "circle.dashed")
                    .frame(maxWidth: .infinity)
            }
            .help("Adds a spot in the middle of the frame; drag its handles on the canvas")

            if session.settings.spots.isEmpty {
                Text("No spots").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(session.settings.spots) { spot in
                    spotRow(spot)
                }
            }

            if let id = selectedSpotID,
               let spot = session.settings.spots.first(where: { $0.id == id }) {
                Divider().padding(.vertical, 2)
                spotEditors(spot)
            }
        }
    }

    private func addSpot() {
        var s = session.settings
        let radius = 0.03
        // Auto-suggest a source patch: offset diagonally by 2.5 radii — the canvas lets the
        // user drag it anywhere; a smarter texture-matched suggestion can refine this.
        let spot = SpotEdit(mode: mode, x: 0.5, y: 0.5, radius: radius,
                            sourceX: 0.5 + radius * 2.5, sourceY: 0.5 - radius * 2.5)
        s.spots.append(spot)
        session.apply(name: "Add Spot", settings: s)
        selectedSpotID = spot.id
    }

    @ViewBuilder private func spotRow(_ spot: SpotEdit) -> some View {
        HStack {
            Image(systemName: spot.mode == .heal ? "bandage" : "doc.on.doc")
                .font(.caption)
            Text(String(format: "%@ @ %.0f%%, %.0f%%",
                        spot.mode == .heal ? "Heal" : "Clone", spot.x * 100, spot.y * 100))
                .font(.caption)
            Spacer()
            Button {
                var s = session.settings
                s.spots.removeAll { $0.id == spot.id }
                session.apply(name: "Delete Spot", settings: s)
                if selectedSpotID == spot.id { selectedSpotID = nil }
            } label: {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .background(selectedSpotID == spot.id ? Color.accentColor.opacity(0.15) : .clear)
        .onTapGesture { selectedSpotID = spot.id }
    }

    @ViewBuilder private func spotEditors(_ spot: SpotEdit) -> some View {
        Group {
            spotSlider("X", spot.id, \.x, 0...1)
            spotSlider("Y", spot.id, \.y, 0...1)
            spotSlider("Source X", spot.id, \.sourceX, 0...1)
            spotSlider("Source Y", spot.id, \.sourceY, 0...1)
            spotSlider("Size", spot.id, \.radius, 0.005...0.2)
            spotSlider("Feather", spot.id, \.feather, 0...100)
            spotSlider("Opacity", spot.id, \.opacity, 0...100)
        }
    }

    private func spotSlider(_ label: String, _ id: UUID,
                            _ keyPath: WritableKeyPath<SpotEdit, Double>,
                            _ range: ClosedRange<Double>) -> SliderRow {
        SliderRow(label: label, range: range,
                  defaultValue: range.lowerBound, format: "%.3f", session: session,
                  get: { $0.spots.first(where: { $0.id == id })?[keyPath: keyPath] ?? 0 },
                  set: { s, v in
                      guard let idx = s.spots.firstIndex(where: { $0.id == id }) else { return }
                      s.spots[idx][keyPath: keyPath] = v
                  })
    }
}
