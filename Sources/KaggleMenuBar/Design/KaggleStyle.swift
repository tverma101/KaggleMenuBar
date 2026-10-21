import AppKit
import SwiftUI

/// Status colors. The fills are the system's own, so they follow light and
/// dark menu bars and Increase Contrast; panel text uses darker shades of the
/// same hues so small labels stay readable.
enum KaggleStyle {
    static let running = NSColor.systemGreen
    static let queued = NSColor.systemOrange
    /// A running session within an hour of Kaggle's 12-hour limit.
    static let late = NSColor.systemRed
    static let warning = NSColor.systemYellow
    static let accent = adaptive(
        light: NSColor(srgbRed: 0x2E / 255, green: 0x7D / 255, blue: 0x32 / 255, alpha: 1),
        dark: NSColor(srgbRed: 0x6B / 255, green: 0xC4 / 255, blue: 0x6F / 255, alpha: 1)
    )

    private static let runningText = adaptive(
        light: NSColor(srgbRed: 0x1F / 255, green: 0x6E / 255, blue: 0x2E / 255, alpha: 1),
        dark: NSColor(srgbRed: 0x7E / 255, green: 0xD3 / 255, blue: 0x8A / 255, alpha: 1)
    )
    private static let queuedText = adaptive(
        light: NSColor(srgbRed: 0x9A / 255, green: 0x52 / 255, blue: 0x00 / 255, alpha: 1),
        dark: NSColor(srgbRed: 0xFF / 255, green: 0xB3 / 255, blue: 0x5C / 255, alpha: 1)
    )

    static func textColor(for status: NotebookRunStatus) -> NSColor {
        switch status {
        case .queued: queuedText
        case .running: runningText
        }
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

/// The app's mark: the menu bar's rounded "k" inside a clock-face ring three
/// quarters of the way round. Its own drawing, not Kaggle's logo.
enum BrandMark {
    /// Draws in a y-up context, filling the square inside `rect`.
    static func draw(in context: CGContext, rect: CGRect, ink: NSColor = .labelColor, arc: NSColor = KaggleStyle.running) {
        let size = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let lineWidth = size * 0.1
        let radius = (size - lineWidth) / 2
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineWidth(lineWidth)

        context.setStrokeColor(ink.withAlphaComponent(0.18).cgColor)
        context.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        context.strokePath()

        context.setStrokeColor(arc.cgColor)
        context.setLineCap(.round)
        let top = CGFloat.pi / 2
        context.addArc(center: center, radius: radius, startAngle: top, endAngle: top - 1.5 * .pi, clockwise: true)
        context.strokePath()

        TextLine("k", font: .rounded(size * 0.58, weight: .bold), color: ink)
            .drawCenteredOnGlyphs(in: context, at: CGPoint(x: center.x + size * 0.01, y: center.y))
    }
}
