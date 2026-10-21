import AppKit
import CoreText

/// One active run, drawn like a watch face. The arc is the minutes into the
/// current hour, starting at 12 o'clock; the middle shows completed hours, or a
/// dot during the first hour. A filled dot means running and a hollow one
/// queued, so the two read apart without color. A running ring turns red from
/// 11 hours, an hour before Kaggle stops a 12-hour session.
struct ClockRing: Equatable {
    enum Style: Equatable {
        case running, queued
        /// A bare track: connecting, or the first check has not finished.
        case checking
        /// The stack's last slot when more runs are active than fit: a
        /// neutral ring around "+N".
        case more(Int)
    }

    var style: Style
    /// Minutes since the run started or was queued, when Kaggle reported it.
    var minutes: Int?

    /// Menu bar size; the panel draws the same ring scaled up.
    static let radius: CGFloat = 6.6
    static let lineWidth: CGFloat = 1.8
    static var outerRadius: CGFloat { radius + lineWidth / 2 }
    /// Clear space a ring cuts out of the ring it overlaps.
    static let cutoutRadius: CGFloat = 8.7
    static let lateMinutes = 11 * 60

    var tint: NSColor {
        switch style {
        case .running: (minutes ?? 0) >= Self.lateMinutes ? KaggleStyle.late : KaggleStyle.running
        case .queued: KaggleStyle.queued
        case .checking, .more: .secondaryLabelColor
        }
    }

    /// Draws in a y-up context. Colors resolve against the current drawing
    /// appearance, so call it from `draw(_:)` or inside
    /// `performAsCurrentDrawingAppearance`.
    func draw(in context: CGContext, center: CGPoint, scale: CGFloat = 1) {
        let radius = Self.radius * scale
        let tint = tint
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineWidth(Self.lineWidth * scale)

        context.setStrokeColor((style == .checking ? tint : tint.withAlphaComponent(0.3)).cgColor)
        context.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        context.strokePath()
        switch style {
        case .checking:
            return
        case let .more(count):
            // The ring before it covers the chip's left edge, so the label
            // sits a little right of center.
            let label = "+\(count)"
            let size: CGFloat = label.count < 3 ? 7 : 6
            TextLine(label, font: .rounded(size * scale, weight: .bold), color: .labelColor)
                .drawCenteredOnGlyphs(in: context, at: CGPoint(x: center.x + 1 * scale, y: center.y))
            return
        case .running, .queued:
            break
        }

        let minutes = max(0, minutes ?? 0)
        let fraction = CGFloat(minutes % 60) / 60
        if fraction > 0 {
            context.setStrokeColor(tint.cgColor)
            context.setLineCap(.round)
            let top = CGFloat.pi / 2
            context.addArc(center: center, radius: radius, startAngle: top,
                           endAngle: top - fraction * 2 * .pi, clockwise: true)
            context.strokePath()
        }

        let hours = minutes / 60
        if hours >= 1 {
            let size: CGFloat = hours < 10 ? 8.6 : 7.2
            let digits = TextLine("\(hours)", font: .rounded(size * scale, weight: .bold), color: .labelColor)
            digits.drawCenteredOnGlyphs(in: context, at: center)
        } else {
            let dot = 2.6 * scale
            let rect = CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2)
            if style == .running {
                context.setFillColor(tint.cgColor)
                context.fillEllipse(in: rect)
            } else {
                let line = 1.2 * scale
                context.setStrokeColor(tint.cgColor)
                context.setLineWidth(line)
                context.strokeEllipse(in: rect.insetBy(dx: line / 2, dy: line / 2))
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

    var glyphBounds: CGRect { CTLineGetBoundsWithOptions(line, .useGlyphPathBounds) }
}

extension NSFont {
    /// SF Rounded, optionally with digits of equal width so ticking minutes
    /// do not shift the text.
    static func rounded(_ size: CGFloat, weight: NSFont.Weight, monospacedDigits: Bool = false) -> NSFont {
        var descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        descriptor = descriptor.withDesign(.rounded) ?? descriptor
        if monospacedDigits {
            descriptor = descriptor.addingAttributes([.featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]]])
        }
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}
