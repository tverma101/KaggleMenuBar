import AppKit
import SwiftUI

/// Kaggle brand colors, taken from the `km.color.kaggle` theme in kaggle.com's
/// app bundle (blue #20BEFF, green #1CCD76, orange #FF5C19, yellow #E5CF4A).
/// The darker text shades come from the same bundle's status palette and keep
/// labels readable on light backgrounds.
enum KaggleStyle {
    static let blue = NSColor(srgbRed: 0x20 / 255, green: 0xBE / 255, blue: 0xFF / 255, alpha: 1)
    static let green = NSColor(srgbRed: 0x1C / 255, green: 0xCD / 255, blue: 0x76 / 255, alpha: 1)
    static let orange = NSColor(srgbRed: 0xFF / 255, green: 0x5C / 255, blue: 0x19 / 255, alpha: 1)
    static let yellow = NSColor(srgbRed: 0xE5 / 255, green: 0xCF / 255, blue: 0x4A / 255, alpha: 1)

    static let greenText = adaptive(
        light: NSColor(srgbRed: 0x19 / 255, green: 0x76 / 255, blue: 0x31 / 255, alpha: 1),
        dark: green
    )
    static let orangeText = adaptive(
        light: NSColor(srgbRed: 0xCC / 255, green: 0x45 / 255, blue: 0x0D / 255, alpha: 1),
        dark: NSColor(srgbRed: 0xFF / 255, green: 0x71 / 255, blue: 0x36 / 255, alpha: 1)
    )
    static let yellowText = adaptive(
        light: NSColor(srgbRed: 0xB5 / 255, green: 0x88 / 255, blue: 0x12 / 255, alpha: 1),
        dark: yellow
    )

    /// Kaggle's text color (#202124). White on #20BEFF is too faint for small
    /// text, so text on the blue pill uses this instead.
    static let ink = NSColor(srgbRed: 0x20 / 255, green: 0x21 / 255, blue: 0x24 / 255, alpha: 1)

    static func statusColor(for status: NotebookRunStatus) -> NSColor {
        switch status {
        case .queued: orange
        case .running: green
        }
    }

    static func textColor(for status: NotebookRunStatus) -> NSColor {
        switch status {
        case .queued: orangeText
        case .running: greenText
        }
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

/// The lowercase "k" from Kaggle's site logo (`/static/images/site-logo.svg`),
/// reduced to straight segments. The source's corner radii are under 0.3 pt at
/// menu bar size, so dropping them is invisible.
enum KaggleMark {
    /// Source glyph box in SVG units (y grows downward).
    static let sourceSize = CGSize(width: 26.92, height: 47.27)

    private static let points: [CGPoint] = [
        CGPoint(x: 26.92, y: 47.00), CGPoint(x: 26.36, y: 47.27), CGPoint(x: 20.19, y: 47.27),
        CGPoint(x: 19.19, y: 46.79), CGPoint(x: 9.00, y: 33.78), CGPoint(x: 6.17, y: 36.49),
        CGPoint(x: 6.17, y: 46.55), CGPoint(x: 5.48, y: 47.24), CGPoint(x: 0.69, y: 47.24),
        CGPoint(x: 0.00, y: 46.55), CGPoint(x: 0.00, y: 0.69), CGPoint(x: 0.69, y: 0.00),
        CGPoint(x: 5.48, y: 0.00), CGPoint(x: 6.17, y: 0.69), CGPoint(x: 6.17, y: 28.93),
        CGPoint(x: 18.38, y: 16.58), CGPoint(x: 19.38, y: 16.09), CGPoint(x: 25.77, y: 16.09),
        CGPoint(x: 26.32, y: 16.44), CGPoint(x: 26.25, y: 17.07), CGPoint(x: 13.32, y: 29.55),
        CGPoint(x: 26.78, y: 46.27),
    ]

    static func width(forHeight height: CGFloat) -> CGFloat {
        height * sourceSize.width / sourceSize.height
    }

    /// Path filling `rect`. `flipped` is true for y-down spaces (SwiftUI).
    static func path(in rect: CGRect, flipped: Bool) -> CGPath {
        let scale = rect.height / sourceSize.height
        let path = CGMutablePath()
        for (index, point) in points.enumerated() {
            let x = rect.minX + point.x * scale
            let y = flipped ? rect.minY + point.y * scale : rect.maxY - point.y * scale
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()
        return path
    }
}

struct KaggleMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(KaggleMark.path(in: rect, flipped: true))
    }
}
