import SwiftUI
import AppKit
import PhotonCore

/// RGB histogram, custom-drawn AppKit view (log-scaled bins, per-channel additive blend),
/// with shadow/highlight clipping indicators.
struct HistogramView: NSViewRepresentable {
    let session: EditSession

    func makeNSView(context: Context) -> HistogramNSView {
        HistogramNSView()
    }

    func updateNSView(_ view: HistogramNSView, context: Context) {
        view.data = session.histogram
        view.needsDisplay = true
    }
}

final class HistogramNSView: NSView {
    var data: HistogramData?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.13, alpha: 1).setFill()
        bounds.fill()

        guard let data, let ctx = NSGraphicsContext.current?.cgContext else {
            drawPlaceholder()
            return
        }

        let inset = bounds.insetBy(dx: 8, dy: 8)
        let maxCount = max(
            data.red.max() ?? 1, data.green.max() ?? 1, data.blue.max() ?? 1, 1)
        let logMax = log1p(Double(maxCount))

        func path(for bins: [Int]) -> CGPath {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: inset.minX, y: inset.maxY))
            for (i, count) in bins.enumerated() {
                let x = inset.minX + inset.width * CGFloat(i) / 255
                let h = inset.height * CGFloat(log1p(Double(count)) / logMax)
                p.addLine(to: CGPoint(x: x, y: inset.maxY - h))
            }
            p.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY))
            p.closeSubpath()
            return p
        }

        ctx.setBlendMode(.screen)
        for (bins, color) in [
            (data.red, NSColor.systemRed), (data.green, NSColor.systemGreen),
            (data.blue, NSColor.systemBlue)
        ] {
            ctx.setFillColor(color.withAlphaComponent(0.55).cgColor)
            ctx.addPath(path(for: bins))
            ctx.fillPath()
        }
        ctx.setBlendMode(.normal)

        // Clipping indicators: triangles when >0.1% of pixels sit in the extreme bins.
        let total = data.luminance.reduce(0, +)
        if total > 0 {
            let shadowClip = Double(data.luminance[0]) / Double(total) > 0.001
            let highlightClip = Double(data.luminance[255]) / Double(total) > 0.001
            if shadowClip {
                drawClipTriangle(at: CGPoint(x: bounds.minX + 6, y: bounds.minY + 6),
                                 color: .systemBlue, ctx: ctx)
            }
            if highlightClip {
                drawClipTriangle(at: CGPoint(x: bounds.maxX - 14, y: bounds.minY + 6),
                                 color: .systemRed, ctx: ctx)
            }
        }
    }

    private func drawClipTriangle(at origin: CGPoint, color: NSColor, ctx: CGContext) {
        let p = CGMutablePath()
        p.move(to: origin)
        p.addLine(to: CGPoint(x: origin.x + 8, y: origin.y))
        p.addLine(to: CGPoint(x: origin.x + 4, y: origin.y + 7))
        p.closeSubpath()
        ctx.setFillColor(color.cgColor)
        ctx.addPath(p)
        ctx.fillPath()
    }

    private func drawPlaceholder() {
        let text = "Histogram" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: NSFont.systemFont(ofSize: 11)
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2,
                              y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
}
