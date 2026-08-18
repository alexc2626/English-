import SwiftUI
import PhotonCore

/// Tone Curve panel: parametric region sliders plus an interactive point-curve editor with
/// per-channel (composite/R/G/B) tabs. Click to add a point, drag to move, double-click a
/// point to remove it.
struct ToneCurvePanel: View {
    let session: EditSession
    @State private var channel: CurveChannel = .composite

    enum CurveChannel: String, CaseIterable {
        case composite = "Point"
        case red = "R"
        case green = "G"
        case blue = "B"
    }

    var body: some View {
        DevelopPanel(title: "Tone Curve", resetAction: {
            session.apply(name: "Reset Tone Curve", settings: {
                var s = session.settings
                s.toneCurve = ToneCurveSettings()
                return s
            }())
        }) {
            Picker("Channel", selection: $channel) {
                ForEach(CurveChannel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            CurveEditor(session: session, channel: channel)
                .frame(height: 180)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.16)))

            Divider().padding(.vertical, 2)

            SliderRow(label: "Highlights", range: -100...100, session: session,
                      get: { $0.toneCurve.highlights }, set: { $0.toneCurve.highlights = $1 })
            SliderRow(label: "Lights", range: -100...100, session: session,
                      get: { $0.toneCurve.lights }, set: { $0.toneCurve.lights = $1 })
            SliderRow(label: "Darks", range: -100...100, session: session,
                      get: { $0.toneCurve.darks }, set: { $0.toneCurve.darks = $1 })
            SliderRow(label: "Shadows", range: -100...100, session: session,
                      get: { $0.toneCurve.shadowsRegion },
                      set: { $0.toneCurve.shadowsRegion = $1 })
        }
    }
}

/// The interactive point-curve canvas.
struct CurveEditor: View {
    let session: EditSession
    let channel: ToneCurvePanel.CurveChannel

    @State private var draggingIndex: Int?

    private var curve: CurvePoints {
        switch channel {
        case .composite: return session.settings.toneCurve.pointCurve
        case .red: return session.settings.toneCurve.redCurve
        case .green: return session.settings.toneCurve.greenCurve
        case .blue: return session.settings.toneCurve.blueCurve
        }
    }

    private func writeCurve(_ newCurve: CurvePoints, gestureName: String) {
        session.update(gestureName) { s in
            switch channel {
            case .composite: s.toneCurve.pointCurve = newCurve
            case .red: s.toneCurve.redCurve = newCurve
            case .green: s.toneCurve.greenCurve = newCurve
            case .blue: s.toneCurve.blueCurve = newCurve
            }
        }
    }

    private var strokeColor: Color {
        switch channel {
        case .composite: return .white
        case .red: return .red
        case .green: return .green
        case .blue: return .blue
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                // Grid
                Path { p in
                    for i in 1...3 {
                        let x = size.width * CGFloat(i) / 4
                        let y = size.height * CGFloat(i) / 4
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: size.height))
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: size.width, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.08), lineWidth: 1)

                // Diagonal reference
                Path { p in
                    p.move(to: CGPoint(x: 0, y: size.height))
                    p.addLine(to: CGPoint(x: size.width, y: 0))
                }
                .stroke(Color.white.opacity(0.15), style: .init(lineWidth: 1, dash: [3, 3]))

                // The interpolated curve (evaluated by the same code the renderer uses)
                Path { p in
                    let steps = 100
                    for i in 0...steps {
                        let x = Double(i) / Double(steps)
                        let y = ToneCurveEvaluator.evaluatePointCurve(curve, at: x)
                        let pt = CGPoint(x: size.width * CGFloat(x),
                                         y: size.height * CGFloat(1 - y))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                .stroke(strokeColor, lineWidth: 1.5)

                // Control points
                ForEach(Array(curve.points.enumerated()), id: \.offset) { index, point in
                    Circle()
                        .fill(strokeColor)
                        .frame(width: 8, height: 8)
                        .position(x: size.width * CGFloat(point.x),
                                  y: size.height * CGFloat(1 - point.y))
                        .onTapGesture(count: 2) {
                            // Remove (endpoints stay).
                            guard curve.points.count > 2,
                                  index > 0, index < curve.points.count - 1 else { return }
                            var c = curve
                            c.points.remove(at: index)
                            writeCurve(c, gestureName: "Remove Curve Point")
                            session.endGesture()
                        }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = min(max(Double(value.location.x / size.width), 0), 1)
                        let y = min(max(Double(1 - value.location.y / size.height), 0), 1)
                        var c = curve
                        if draggingIndex == nil {
                            // Grab the nearest point within reach, else insert a new one.
                            if let (idx, pt) = c.points.enumerated().min(by: {
                                abs($0.element.x - x) < abs($1.element.x - x)
                            }), abs(pt.x - x) < 0.05 {
                                draggingIndex = idx
                            } else {
                                c.upsert(.init(x: x, y: y))
                                writeCurve(c, gestureName: "Add Curve Point")
                                draggingIndex = c.points.firstIndex { abs($0.x - x) < 0.011 }
                                return
                            }
                        }
                        guard let idx = draggingIndex, c.points.indices.contains(idx) else {
                            return
                        }
                        // Endpoints move vertically only; interior points are clamped between
                        // neighbours so the curve stays a function of x.
                        var newX = x
                        if idx == 0 { newX = c.points[0].x }
                        else if idx == c.points.count - 1 { newX = c.points[idx].x }
                        else {
                            let lo = c.points[idx - 1].x + 0.01
                            let hi = c.points[idx + 1].x - 0.01
                            newX = min(max(x, lo), hi)
                        }
                        c.points[idx] = .init(x: newX, y: y)
                        writeCurve(c, gestureName: "Tone Curve")
                    }
                    .onEnded { _ in
                        draggingIndex = nil
                        session.endGesture()
                    }
            )
        }
        .padding(6)
    }
}
