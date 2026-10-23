import AppKit

/// The original app's muted palette, inspired by Kaggle's neutral rebrand: a
/// graphite capsule with sage, amber and wheat for running, queued and
/// warning. The capsule keeps its colors on light and dark menu bars; panel
/// text uses shades of the same hues that stay readable on either.
enum KaggleStyle {
    static let capsule = srgb(0x303733)
    static let onCapsule = srgb(0xEFF1EA)
    /// The pale ring around each circle, and the hours on its dial.
    static let ring = srgb(0xDAE0D5)
    static let running = srgb(0x789760)
    static let queued = srgb(0xBC9258)
    /// A running session within an hour of Kaggle's 12-hour limit.
    static let late = srgb(0xB8614F)
    static let warning = srgb(0xC4B16B)
    /// Dark glyphs inside the pale and wheat discs.
    static let ink = srgb(0x202124)
    static let accent = adaptive(light: srgb(0x486E35), dark: srgb(0xA5BC91))

    private static let runningText = adaptive(light: srgb(0x3E642A), dark: srgb(0xA5BC91))
    private static let queuedText = adaptive(light: srgb(0x825C2F), dark: srgb(0xC9AB7A))
    static let warningText = adaptive(light: srgb(0x7A6832), dark: srgb(0xCFBD80))

    static func textColor(for status: NotebookRunStatus) -> NSColor {
        switch status {
        case .queued: queuedText
        case .running: runningText
        }
    }

    private static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
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

    /// Path filling `rect` in a y-up space.
    static func path(in rect: CGRect) -> CGPath {
        let scale = rect.height / sourceSize.height
        let path = CGMutablePath()
        for (index, point) in points.enumerated() {
            let corner = CGPoint(x: rect.minX + point.x * scale, y: rect.maxY - point.y * scale)
            if index == 0 {
                path.move(to: corner)
            } else {
                path.addLine(to: corner)
            }
        }
        path.closeSubpath()
        return path
    }
}
