import SwiftUI
import PhotonCore

/// The Masking panel — Lightroom's masking model: named masks, each built from components
/// combined with Add / Subtract / Intersect, each mask carrying its own Basic-style slider
/// set, visibility toggle, invert, and red-overlay preview ("O").
struct MaskingPanel: View {
    let session: EditSession
    @State private var selectedMaskID: UUID?

    var body: some View {
        DevelopPanel(title: "Masking", resetAction: {
            session.apply(name: "Remove All Masks", settings: {
                var s = session.settings
                s.masks = []
                return s
            }())
        }) {
            newMaskMenu

            if session.settings.masks.isEmpty {
                Text("No masks. Create one above — AI masks run on the Neural Engine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(session.settings.masks) { mask in
                maskRow(mask)
                if selectedMaskID == mask.id {
                    MaskDetailView(session: session, maskID: mask.id)
                        .padding(.leading, 8)
                }
            }
        }
    }

    // MARK: New mask creation

    private var newMaskMenu: some View {
        Menu {
            Button("Select Subject") { addMask(kind: .subject, name: "Subject") }
            Button("Select Sky") { addMask(kind: .sky, name: "Sky") }
            Button("Select People") {
                addMask(kind: .person(PersonMaskOptions()), name: "Person 1")
            }
            Button("Select Object (Center Box)") {
                addMask(kind: .object(ObjectSeed(seed: .box(x: 0.3, y: 0.3,
                                                            width: 0.4, height: 0.4))),
                        name: "Object")
            }
            Divider()
            Button("Brush") {
                addMask(kind: .brush(BrushMask()), name: "Brush")
            }
            Button("Linear Gradient") {
                addMask(kind: .linearGradient(LinearGradientMask(
                    startX: 0.5, startY: 0.35, endX: 0.5, endY: 0.65)), name: "Linear Gradient")
            }
            Button("Radial Gradient") {
                addMask(kind: .radialGradient(RadialGradientMask(
                    centerX: 0.5, centerY: 0.5, radiusX: 0.3, radiusY: 0.22)),
                        name: "Radial Gradient")
            }
            Divider()
            Button("Color Range (sample center)") {
                addMask(kind: .colorRange(ColorRangeMask(
                    samples: [.init(r: 0.5, g: 0.5, b: 0.5)])), name: "Color Range")
            }
            Button("Luminance Range") {
                addMask(kind: .luminanceRange(LuminanceRangeMask(low: 0.5, high: 1.0)),
                        name: "Luminance Range")
            }
            Button("Depth Range") {
                addMask(kind: .depthRange(DepthRangeMask(near: 0, far: 0.4)),
                        name: "Depth Range")
            }
        } label: {
            Label("Create New Mask", systemImage: "plus.circle")
                .frame(maxWidth: .infinity)
        }
    }

    private func addMask(kind: MaskKind, name: String) {
        var s = session.settings
        let existingCount = s.masks.filter { $0.name.hasPrefix(name) }.count
        let maskName = existingCount == 0 ? name : "\(name) \(existingCount + 1)"
        let mask = PhotonMask(name: maskName,
                              components: [MaskComponent(mode: .add, kind: kind)])
        s.masks.append(mask)
        session.apply(name: "Add Mask: \(mask.components[0].kind.displayName)", settings: s)
        selectedMaskID = mask.id
        session.overlayMaskID = mask.id
    }

    // MARK: Mask row

    @ViewBuilder private func maskRow(_ mask: PhotonMask) -> some View {
        HStack(spacing: 6) {
            Image(systemName: iconName(mask))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(mask.name)
                .font(.system(size: 11, weight: selectedMaskID == mask.id ? .semibold : .regular))
                .lineLimit(1)
            Spacer()
            // Overlay preview toggle (the "O" key equivalent)
            Button {
                session.overlayMaskID = session.overlayMaskID == mask.id ? nil : mask.id
            } label: {
                Image(systemName: session.overlayMaskID == mask.id
                      ? "circle.inset.filled" : "circle")
                    .font(.caption)
                    .foregroundStyle(session.overlayMaskID == mask.id ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .help("Show mask overlay (O)")

            // Visibility toggle
            Button {
                mutateMask(mask.id, name: "Toggle Mask") { $0.enabled.toggle() }
            } label: {
                Image(systemName: mask.enabled ? "eye" : "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Button {
                var s = session.settings
                s.masks.removeAll { $0.id == mask.id }
                session.apply(name: "Delete Mask", settings: s)
                if selectedMaskID == mask.id { selectedMaskID = nil }
                if session.overlayMaskID == mask.id { session.overlayMaskID = nil }
            } label: {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(selectedMaskID == mask.id ? Color.accentColor.opacity(0.15) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedMaskID = selectedMaskID == mask.id ? nil : mask.id
        }
    }

    private func iconName(_ mask: PhotonMask) -> String {
        switch mask.components.first?.kind {
        case .subject: return "person.crop.square.badge.camera"
        case .sky: return "cloud.sun"
        case .person: return "person"
        case .object: return "square.dashed"
        case .brush: return "paintbrush.pointed"
        case .linearGradient: return "square.bottomhalf.filled"
        case .radialGradient: return "circle.dotted.circle"
        case .colorRange: return "eyedropper.halffull"
        case .luminanceRange: return "circle.lefthalf.filled"
        case .depthRange: return "square.3.layers.3d.down.right"
        case nil: return "questionmark"
        }
    }

    private func mutateMask(_ id: UUID, name: String, _ mutate: (inout PhotonMask) -> Void) {
        var s = session.settings
        guard let idx = s.masks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&s.masks[idx])
        session.apply(name: name, settings: s)
    }
}

/// Detail editor for one mask: component list with Add/Subtract/Intersect, invert toggle,
/// per-kind parameter editors, and the scoped adjustment sliders.
struct MaskDetailView: View {
    let session: EditSession
    let maskID: UUID

    private var mask: PhotonMask? {
        session.settings.masks.first { $0.id == maskID }
    }

    var body: some View {
        if let mask {
            VStack(spacing: 6) {
                // Components
                ForEach(mask.components) { component in
                    componentRow(component)
                }

                HStack {
                    componentMenu("Add", mode: .add)
                    componentMenu("Subtract", mode: .subtract)
                    componentMenu("Intersect", mode: .intersect)
                }
                .font(.caption)

                Toggle("Invert Mask", isOn: Binding(
                    get: { mask.inverted },
                    set: { on in mutate("Invert Mask") { $0.inverted = on } }))
                    .font(.system(size: 11))

                Divider().padding(.vertical, 2)

                // Per-kind parameters for the first (primary) component
                if let first = mask.components.first {
                    kindEditors(first)
                }

                Divider().padding(.vertical, 2)

                // The scoped Basic-style sliders
                localSlider("Amount", -100...100, 100, \.amount)
                localSlider("Exposure", -4...4, 0, \.exposure, format: "%+.2f")
                localSlider("Contrast", -100...100, 0, \.contrast)
                localSlider("Highlights", -100...100, 0, \.highlights)
                localSlider("Shadows", -100...100, 0, \.shadows)
                localSlider("Whites", -100...100, 0, \.whites)
                localSlider("Blacks", -100...100, 0, \.blacks)
                localSlider("Texture", -100...100, 0, \.texture)
                localSlider("Clarity", -100...100, 0, \.clarity)
                localSlider("Dehaze", -100...100, 0, \.dehaze)
                localSlider("Temp", -100...100, 0, \.temperature)
                localSlider("Tint", -100...100, 0, \.tint)
                localSlider("Hue", -100...100, 0, \.hueShift)
                localSlider("Saturation", -100...100, 0, \.saturation)
                localSlider("Sharpness", -100...100, 0, \.sharpness)
                localSlider("Noise", 0...100, 0, \.noise)
                localSlider("Defringe", 0...100, 0, \.defringe)
            }
        }
    }

    // MARK: Components

    @ViewBuilder private func componentRow(_ component: MaskComponent) -> some View {
        HStack {
            Text(modeSymbol(component.mode))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(component.mode == .subtract ? .red : .secondary)
                .frame(width: 14)
            Text(component.kind.displayName)
                .font(.caption)
            Spacer()
            Button {
                mutate("Invert Component") { m in
                    if let i = m.components.firstIndex(where: { $0.id == component.id }) {
                        m.components[i].inverted.toggle()
                    }
                }
            } label: {
                Image(systemName: component.inverted
                      ? "circle.righthalf.filled" : "circle.lefthalf.filled")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .help("Invert this component")
            Button {
                mutate("Remove Component") { m in
                    m.components.removeAll { $0.id == component.id }
                }
            } label: {
                Image(systemName: "minus.circle").font(.caption2)
            }
            .buttonStyle(.plain)
        }
    }

    private func modeSymbol(_ mode: MaskComponent.Mode) -> String {
        switch mode {
        case .add: return "+"
        case .subtract: return "−"
        case .intersect: return "∩"
        }
    }

    private func componentMenu(_ label: String, mode: MaskComponent.Mode) -> some View {
        Menu(label) {
            Button("Subject") { addComponent(.subject, mode) }
            Button("Sky") { addComponent(.sky, mode) }
            Button("Person") { addComponent(.person(PersonMaskOptions()), mode) }
            Button("Object") {
                addComponent(.object(ObjectSeed(seed: .box(x: 0.3, y: 0.3,
                                                           width: 0.4, height: 0.4))), mode)
            }
            Button("Brush") { addComponent(.brush(BrushMask()), mode) }
            Button("Linear Gradient") {
                addComponent(.linearGradient(LinearGradientMask(
                    startX: 0.5, startY: 0.35, endX: 0.5, endY: 0.65)), mode)
            }
            Button("Radial Gradient") {
                addComponent(.radialGradient(RadialGradientMask(
                    centerX: 0.5, centerY: 0.5, radiusX: 0.3, radiusY: 0.22)), mode)
            }
            Button("Color Range") {
                addComponent(.colorRange(ColorRangeMask(
                    samples: [.init(r: 0.5, g: 0.5, b: 0.5)])), mode)
            }
            Button("Luminance Range") {
                addComponent(.luminanceRange(LuminanceRangeMask(low: 0.5, high: 1.0)), mode)
            }
            Button("Depth Range") {
                addComponent(.depthRange(DepthRangeMask(near: 0, far: 0.4)), mode)
            }
        }
        .menuStyle(.borderlessButton)
    }

    private func addComponent(_ kind: MaskKind, _ mode: MaskComponent.Mode) {
        mutate("\(mode == .add ? "Add" : mode == .subtract ? "Subtract" : "Intersect"): \(kind.displayName)") { m in
            m.components.append(MaskComponent(mode: mode, kind: kind))
        }
    }

    // MARK: Kind-specific editors

    @ViewBuilder private func kindEditors(_ component: MaskComponent) -> some View {
        switch component.kind {
        case .person(let options):
            personPartToggles(component.id, options)
        case .luminanceRange(let range):
            rangeSlider("Lum Low", component.id, range.low) { kind, v in
                if case .luminanceRange(var r) = kind { r.low = min(v, r.high); return .luminanceRange(r) }
                return kind
            }
            rangeSlider("Lum High", component.id, range.high) { kind, v in
                if case .luminanceRange(var r) = kind { r.high = max(v, r.low); return .luminanceRange(r) }
                return kind
            }
            rangeSlider("Smoothness", component.id, range.smoothness) { kind, v in
                if case .luminanceRange(var r) = kind { r.smoothness = v; return .luminanceRange(r) }
                return kind
            }
        case .depthRange(let range):
            rangeSlider("Depth Near", component.id, range.near) { kind, v in
                if case .depthRange(var r) = kind { r.near = min(v, r.far); return .depthRange(r) }
                return kind
            }
            rangeSlider("Depth Far", component.id, range.far) { kind, v in
                if case .depthRange(var r) = kind { r.far = max(v, r.near); return .depthRange(r) }
                return kind
            }
        case .colorRange(let colorRange):
            rangeSlider("Refine", component.id, colorRange.refine / 100) { kind, v in
                if case .colorRange(var c) = kind { c.refine = v * 100; return .colorRange(c) }
                return kind
            }
        case .radialGradient(let g):
            rangeSlider("Feather", component.id, g.feather / 100) { kind, v in
                if case .radialGradient(var r) = kind { r.feather = v * 100; return .radialGradient(r) }
                return kind
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func personPartToggles(_ componentID: UUID,
                                                _ options: PersonMaskOptions) -> some View {
        Text("Person Parts").font(.caption2).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        ForEach(PersonMaskOptions.Part.allCases, id: \.self) { part in
            Toggle(partLabel(part), isOn: Binding(
                get: { options.parts.contains(part) },
                set: { on in
                    mutate("Person Parts") { m in
                        guard let i = m.components.firstIndex(where: { $0.id == componentID }),
                              case .person(var opts) = m.components[i].kind else { return }
                        if on {
                            if part == .entirePerson { opts.parts = [.entirePerson] }
                            else {
                                opts.parts.remove(.entirePerson)
                                opts.parts.insert(part)
                            }
                        } else {
                            opts.parts.remove(part)
                            if opts.parts.isEmpty { opts.parts = [.entirePerson] }
                        }
                        m.components[i].kind = .person(opts)
                    }
                }))
                .font(.system(size: 11))
        }
    }

    private func partLabel(_ part: PersonMaskOptions.Part) -> String {
        switch part {
        case .entirePerson: return "Entire Person"
        case .skin: return "Skin"
        case .hair: return "Hair"
        case .clothing: return "Clothing"
        case .eyes: return "Eyes"
        case .lips: return "Lips"
        case .teeth: return "Teeth"
        }
    }

    private func rangeSlider(_ label: String, _ componentID: UUID, _ value: Double,
                             _ transform: @escaping (MaskKind, Double) -> MaskKind) -> SliderRow {
        SliderRow(label: label, range: 0...1, defaultValue: value, format: "%.2f",
                  session: session,
                  get: { _ in value },
                  set: { s, v in
                      guard let mi = s.masks.firstIndex(where: { $0.id == maskID }),
                            let ci = s.masks[mi].components.firstIndex(where: {
                                $0.id == componentID
                            }) else { return }
                      s.masks[mi].components[ci].kind =
                          transform(s.masks[mi].components[ci].kind, v)
                  })
    }

    // MARK: Local adjustment sliders

    private func localSlider(_ label: String, _ range: ClosedRange<Double>,
                             _ defaultValue: Double,
                             _ keyPath: WritableKeyPath<LocalAdjustments, Double>,
                             format: String = "%+.0f") -> SliderRow {
        SliderRow(label: label, range: range, defaultValue: defaultValue, format: format,
                  session: session,
                  get: { settings in
                      settings.masks.first { $0.id == maskID }?
                          .adjustments[keyPath: keyPath] ?? defaultValue
                  },
                  set: { settings, value in
                      guard let idx = settings.masks.firstIndex(where: { $0.id == maskID })
                      else { return }
                      settings.masks[idx].adjustments[keyPath: keyPath] = value
                  })
    }

    private func mutate(_ name: String, _ mutateMask: (inout PhotonMask) -> Void) {
        var s = session.settings
        guard let idx = s.masks.firstIndex(where: { $0.id == maskID }) else { return }
        mutateMask(&s.masks[idx])
        session.apply(name: name, settings: s)
    }
}
