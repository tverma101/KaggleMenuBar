// Draws Resources/AppIcon.icns: the original layout, a tall rounded "k" with
// two overlapping circles at its baseline, where each circle now sits inside a
// clock ring like the menu bar's. The first ring is on top, as in the menu bar.
// Run from the repo root: swift script/make_icon.swift
import AppKit
import CoreText

func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let surface = srgb(0x303733)
let surfaceDeep = srgb(0x1F2421)
let foreground = srgb(0xF4F6F1)
// systemGreen and systemOrange as macOS draws them on dark backgrounds.
let green = srgb(0x30D158)
let orange = srgb(0xFF9F0A)

func roundedFont(_ size: CGFloat) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: .semibold)
    return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
}

/// A pale track (the original circles' outline), the colored arc from 12
/// o'clock, and the original filled circle inside.
func drawRing(_ ctx: CGContext, center: CGPoint, color: NSColor, fraction: CGFloat) {
    let radius: CGFloat = 80
    ctx.setLineWidth(30)
    ctx.setStrokeColor(foreground.withAlphaComponent(0.55).cgColor)
    ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    ctx.strokePath()
    ctx.setStrokeColor(color.cgColor)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: radius, startAngle: .pi / 2,
               endAngle: .pi / 2 - fraction * 2 * .pi, clockwise: true)
    ctx.strokePath()
    let core = radius * 0.6
    ctx.setFillColor(color.cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2))
}

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824 pt body inside a 1024 pt canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    surface.setFill()
    shape.fill()
    ctx.restoreGState()
    NSGradient(starting: surface, ending: surfaceDeep)!.draw(in: shape, angle: -90)

    // The k, 440 pt of ink standing on y = 290.
    let probe = CTLineCreateWithAttributedString(NSAttributedString(string: "k", attributes: [.font: roundedFont(100)]))
    let fontSize = 100 * 440 / CTLineGetBoundsWithOptions(probe, .useGlyphPathBounds).height
    let attributes: [NSAttributedString.Key: Any] = [
        .font: roundedFont(fontSize),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground.cgColor,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "k", attributes: attributes))
    let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: 206 - ink.minX, y: 290 - ink.minY)
    CTLineDraw(line, ctx)

    // Running in front, queued behind; the front ring cuts a gap out of the
    // one behind it, as ClockRing's separation does in the menu bar.
    let front = CGPoint(x: 604, y: 292)
    let back = CGPoint(x: 754, y: 292)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    drawRing(ctx, center: back, color: orange, fraction: 0.35)
    ctx.setBlendMode(.clear)
    let cutout: CGFloat = 95 * 1.16
    ctx.fillEllipse(in: CGRect(x: front.x - cutout, y: front.y - cutout, width: cutout * 2, height: cutout * 2))
    ctx.setBlendMode(.normal)
    drawRing(ctx, center: front, color: green, fraction: 0.75)
    ctx.endTransparencyLayer()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("KaggleMenuBar-icon/AppIcon.iconset")
func trashIconset() throws {
    guard FileManager.default.fileExists(atPath: iconset.path) else { return }
    try FileManager.default.trashItem(at: iconset, resultingItemURL: nil)
}
try trashIconset()
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let data = drawIcon(pixels: points * scale).representation(using: .png, properties: [:])!
        try data.write(to: iconset.appendingPathComponent(name))
    }
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try trashIconset()
print(iconutil.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
exit(iconutil.terminationStatus)
