// Draws Resources/AppIcon.icns using the menu bar's graphite, sage and amber.
// Run from the repo root: swift script/make_icon.swift
import AppKit

let surface = NSColor(srgbRed: 0x30 / 255, green: 0x37 / 255, blue: 0x33 / 255, alpha: 1)
let surfaceDeep = NSColor(srgbRed: 0x23 / 255, green: 0x2A / 255, blue: 0x26 / 255, alpha: 1)
let foreground = NSColor(srgbRed: 0xEF / 255, green: 0xF1 / 255, blue: 0xEA / 255, alpha: 1)
let ringColor = NSColor(srgbRed: 0xDA / 255, green: 0xE0 / 255, blue: 0xD5 / 255, alpha: 1)
let green = NSColor(srgbRed: 0x78 / 255, green: 0x97 / 255, blue: 0x60 / 255, alpha: 1)
let orange = NSColor(srgbRed: 0xBC / 255, green: 0x92 / 255, blue: 0x58 / 255, alpha: 1)

// Same outline as KaggleMark in Sources/KernelWatch/Design/KaggleStyle.swift (SVG units, y down).
let markSize = CGSize(width: 26.92, height: 47.27)
let markPoints: [CGPoint] = [
    CGPoint(x: 26.92, y: 47.00), CGPoint(x: 26.36, y: 47.27), CGPoint(x: 20.19, y: 47.27),
    CGPoint(x: 19.19, y: 46.79), CGPoint(x: 9.00, y: 33.78), CGPoint(x: 6.17, y: 36.49),
    CGPoint(x: 6.17, y: 46.55), CGPoint(x: 5.48, y: 47.24), CGPoint(x: 0.69, y: 47.24),
    CGPoint(x: 0.00, y: 46.55), CGPoint(x: 0.00, y: 0.69), CGPoint(x: 0.69, y: 0.00),
    CGPoint(x: 5.48, y: 0.00), CGPoint(x: 6.17, y: 0.69), CGPoint(x: 6.17, y: 28.93),
    CGPoint(x: 18.38, y: 16.58), CGPoint(x: 19.38, y: 16.09), CGPoint(x: 25.77, y: 16.09),
    CGPoint(x: 26.32, y: 16.44), CGPoint(x: 26.25, y: 17.07), CGPoint(x: 13.32, y: 29.55),
    CGPoint(x: 26.78, y: 46.27),
]

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

    // White k, optically centred a little left to leave room for the circles.
    let markHeight: CGFloat = 450
    let scale = markHeight / markSize.height
    let markRect = CGRect(x: 248, y: 287, width: markSize.width * scale, height: markHeight)
    let mark = CGMutablePath()
    for (index, point) in markPoints.enumerated() {
        let p = CGPoint(x: markRect.minX + point.x * scale, y: markRect.maxY - point.y * scale)
        index == 0 ? mark.move(to: p) : mark.addLine(to: p)
    }
    mark.closeSubpath()
    ctx.addPath(mark)
    ctx.setFillColor(foreground.cgColor)
    ctx.fillPath()

    // Two overlapping status circles with pale rings, as in the menu bar.
    let diameter: CGFloat = 176
    let ring: CGFloat = 20
    for (index, color) in [orange, green].enumerated() {
        let x = 548 + CGFloat(index) * 112
        let disc = CGRect(x: x, y: 190, width: diameter, height: diameter)
        ctx.setFillColor(ringColor.cgColor)
        ctx.fillEllipse(in: disc)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: disc.insetBy(dx: ring, dy: ring))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".codex/tmp/kaggle-icon/AppIcon.iconset")
func trashIconset() throws {
    guard FileManager.default.fileExists(atPath: iconset.path) else { return }
    let trash = Process()
    trash.executableURL = URL(fileURLWithPath: "/usr/bin/trash")
    trash.arguments = [iconset.path]
    try trash.run()
    trash.waitUntilExit()
    guard trash.terminationStatus == 0 else { exit(trash.terminationStatus) }
    print("Moved temporary iconset to Trash: \(iconset.path)")
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
