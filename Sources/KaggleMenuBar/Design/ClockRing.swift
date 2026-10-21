import AppKit
import CoreText

/// One active run, drawn as the original app drew it: a muted status disc
/// inside a pale ring, on the graphite capsule. The ring is also a 12-hour
/// dial. It fills clockwise from 12 o'clock with the time the run has been
/// going, so a full ring is Kaggle's 12-hour session limit, and a running disc
/// turns brick red in the last hour. When the hub reports the run's hardware,
/// the disc carries it: a chip for CPU, a card for GPU, four tiles for TPU.
struct ClockRing: Equatable {
    enum Style: Equatable {
        case running, queued
        /// A hollow pale ring: connecting, or the first check has not finished.
        case checking
        /// The stack's last slot when more runs are active than fit: a pale
        /// disc around "+N".
        case more(Int)
        /// A wheat disc with "!": the last check failed.
        case warning
    }

    var style: Style
    /// Minutes since the run started or was queued, when Kaggle reported it.
    var minutes: Int?
    var accelerator: Accelerator?

    /// Menu bar size; the panel draws the same circle scaled up.
    static let outerRadius: CGFloat = 8.5
    static let lineWidth: CGFloat = 1.6
    static var discRadius: CGFloat { outerRadius - lineWidth }
    /// Capsule-colored space each circle keeps around itself, which parts it
    /// from the circle it overlaps.
    static let separation: CGFloat = 1.2
    static let glyphSize: CGFloat = 9.6
    static let dialMinutes = 12 * 60
    static let lateMinutes = 11 * 60

    var tint: NSColor {
        switch style {
        case .running: (minutes ?? 0) >= Self.lateMinutes ? KaggleStyle.late : KaggleStyle.running
        case .queued: KaggleStyle.queued
        case .warning: KaggleStyle.warning
        case .checking, .more: KaggleStyle.ring
        }
    }

    /// Draws in a y-up context over the graphite capsule.
    func draw(in context: CGContext, center: CGPoint, scale: CGFloat = 1) {
        func circle(_ radius: CGFloat) -> CGRect {
            CGRect(x: center.x - radius * scale, y: center.y - radius * scale, width: radius * 2 * scale, height: radius * 2 * scale)
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(KaggleStyle.capsule.cgColor)
        context.fillEllipse(in: circle(Self.outerRadius + Self.separation))

        let trackRadius = (Self.outerRadius - Self.lineWidth / 2) * scale
        context.setLineWidth(Self.lineWidth * scale)
        switch style {
        case .checking:
            context.setStrokeColor(KaggleStyle.ring.cgColor)
            context.strokeEllipse(in: circle(Self.outerRadius - Self.lineWidth / 2))
        case let .more(count):
            context.setFillColor(KaggleStyle.ring.cgColor)
            context.fillEllipse(in: circle(Self.outerRadius))
            // The circle before it covers the chip's left edge, so the count
            // sits in the part that shows.
            let font = NSFont.monospacedDigitSystemFont(ofSize: (count < 10 ? 8 : 6.5) * scale, weight: .heavy)
            TextLine("+\(count)", font: font, color: KaggleStyle.ink)
                .drawCenteredOnGlyphs(in: context, at: CGPoint(x: center.x + 2.5 * scale, y: center.y))
        case .warning:
            context.setFillColor(KaggleStyle.ring.cgColor)
            context.fillEllipse(in: circle(Self.outerRadius))
            context.setFillColor(tint.cgColor)
            context.fillEllipse(in: circle(Self.discRadius))
            TextLine("!", font: .systemFont(ofSize: 10 * scale, weight: .black), color: KaggleStyle.ink)
                .drawCenteredOnGlyphs(in: context, at: center)
        case .running, .queued:
            context.setStrokeColor(KaggleStyle.ring.withAlphaComponent(0.3).cgColor)
            context.addArc(center: center, radius: trackRadius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            context.strokePath()
            if let minutes {
                // A run that has just started still shows a dot at 12 o'clock.
                let fraction = min(1, CGFloat(max(0, minutes)) / CGFloat(Self.dialMinutes))
                context.setStrokeColor(KaggleStyle.ring.cgColor)
                context.setLineCap(.round)
                let top = CGFloat.pi / 2
                context.addArc(center: center, radius: trackRadius, startAngle: top,
                               endAngle: top - fraction * 2 * .pi, clockwise: true)
                context.strokePath()
            }
            context.setFillColor(tint.cgColor)
            context.fillEllipse(in: circle(Self.discRadius))
            if let accelerator {
                context.addPath(AcceleratorGlyph.path(for: accelerator, center: center, size: Self.glyphSize * scale))
                context.setFillColor(KaggleStyle.capsule.cgColor)
                context.fillPath(using: .evenOdd)
            }
        }
    }
}

/// A single line of text measured and drawn with Core Text.
struct TextLine {
    let line: CTLine
    let font: NSFont

    init(_ string: String, font: NSFont, color: NSColor) {
        self.font = font
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }

    var width: CGFloat { ceil(CTLineGetTypographicBounds(line, nil, nil, nil)) }

    /// Puts the baseline so capital letters and digits are centered on `midY`,
    /// which keeps the baseline still as the text changes.
    func draw(in context: CGContext, x: CGFloat, midY: CGFloat) {
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: (midY - font.capHeight / 2).rounded(.toNearestOrEven))
        CTLineDraw(line, context)
    }

    /// Centers the ink itself, for a lone glyph inside a shape.
    func drawCenteredOnGlyphs(in context: CGContext, at center: CGPoint) {
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
        CTLineDraw(line, context)
    }
}
