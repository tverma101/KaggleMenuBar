import AppKit
import SwiftUI

/// Muted colors inspired by Kaggle's neutral rebrand and updated green palette.
/// Graphite replaces the legacy bright cyan; sage, amber and wheat retain the
/// running, queued and warning meanings on the 22 pt menu bar surface.
enum KaggleStyle {
    static let capsule = NSColor(srgbRed: 0x30 / 255, green: 0x37 / 255, blue: 0x33 / 255, alpha: 1)
    static let onCapsule = NSColor(srgbRed: 0xEF / 255, green: 0xF1 / 255, blue: 0xEA / 255, alpha: 1)
    static let ring = NSColor(srgbRed: 0xDA / 255, green: 0xE0 / 255, blue: 0xD5 / 255, alpha: 1)
    static let green = NSColor(srgbRed: 0x78 / 255, green: 0x97 / 255, blue: 0x60 / 255, alpha: 1)
    static let orange = NSColor(srgbRed: 0xBC / 255, green: 0x92 / 255, blue: 0x58 / 255, alpha: 1)
    static let yellow = NSColor(srgbRed: 0xC4 / 255, green: 0xB1 / 255, blue: 0x6B / 255, alpha: 1)
    static let accent = adaptive(
        light: NSColor(srgbRed: 0x48 / 255, green: 0x6E / 255, blue: 0x35 / 255, alpha: 1),
        dark: NSColor(srgbRed: 0xA5 / 255, green: 0xBC / 255, blue: 0x91 / 255, alpha: 1)
    )

    static let greenText = adaptive(
        light: NSColor(srgbRed: 0x3E / 255, green: 0x64 / 255, blue: 0x2A / 255, alpha: 1),
        dark: NSColor(srgbRed: 0xA5 / 255, green: 0xBC / 255, blue: 0x91 / 255, alpha: 1)
    )
    static let orangeText = adaptive(
        light: NSColor(srgbRed: 0x82 / 255, green: 0x5C / 255, blue: 0x2F / 255, alpha: 1),
        dark: NSColor(srgbRed: 0xC9 / 255, green: 0xAB / 255, blue: 0x7A / 255, alpha: 1)
    )
    static let yellowText = adaptive(
        light: NSColor(srgbRed: 0x7A / 255, green: 0x68 / 255, blue: 0x32 / 255, alpha: 1),
        dark: NSColor(srgbRed: 0xCF / 255, green: 0xBD / 255, blue: 0x80 / 255, alpha: 1)
    )

    /// Dark glyphs remain readable inside the pale overflow and warning discs.
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
