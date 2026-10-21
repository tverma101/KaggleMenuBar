// Draws Resources/AppIcon.icns: the app's mark (a rounded "k" inside a clock
// ring three quarters of the way round, as BrandMark in
// Sources/KaggleMenuBar/Design/KaggleStyle.swift draws it) on a graphite body.
// Run from the repo root: swift script/make_icon.swift
import AppKit
import CoreText

let surface = NSColor(srgbRed: 0x30 / 255, green: 0x37 / 255, blue: 0x33 / 255, alpha: 1)
let surfaceDeep = NSColor(srgbRed: 0x1F / 255, green: 0x24 / 255, blue: 0x21 / 255, alpha: 1)
let foreground = NSColor(srgbRed: 0xF4 / 255, green: 0xF6 / 255, blue: 0xF1 / 255, alpha: 1)
// systemGreen as macOS draws it on dark backgrounds.
let green = NSColor(srgbRed: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255, alpha: 1)

func roundedBold(_ size: CGFloat) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: .bold)
    return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
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

    // The ring: a faint full track, then the green arc from 12 o'clock.
    let center = CGPoint(x: 512, y: 512)
    let lineWidth: CGFloat = 64
    let radius: CGFloat = 268
    ctx.setLineWidth(lineWidth)
    ctx.setStrokeColor(foreground.withAlphaComponent(0.16).cgColor)
    ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    ctx.strokePath()
    ctx.setStrokeColor(green.cgColor)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - 1.5 * .pi, clockwise: true)
    ctx.strokePath()

    // The k, centered on its own ink.
    let attributes: [NSAttributedString.Key: Any] = [
        .font: roundedBold(370),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground.cgColor,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "k", attributes: attributes))
    let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: center.x + 6 - ink.midX, y: center.y - ink.midY)
    CTLineDraw(line, ctx)

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
