import AppKit
import XCTest
@testable import KaggleMenuBar

/// Renders every menu bar state in light and dark. With `PILL_GALLERY` set to
/// a file path, also writes them to one PNG for review.
@MainActor
final class PillRenderingTests: XCTestCase {
    private static let scenarios: [(name: String, model: PillModel)] = [
        ("Not connected", PillModel()),
        ("First check", PillModel(indicators: [.checking])),
        ("Running 12 min", PillModel(indicators: [.run(ref: "a", status: .running, minutes: 12)], elapsed: "12m")),
        ("Queued 4 min", PillModel(indicators: [.run(ref: "a", status: .queued, minutes: 4)], elapsed: "4m")),
        ("Running 2 h 45", PillModel(indicators: [.run(ref: "a", status: .running, minutes: 165)], elapsed: "2h45")),
        ("Two running, one queued", PillModel(indicators: [
            .run(ref: "a", status: .running, minutes: 165),
            .run(ref: "b", status: .running, minutes: 47),
            .run(ref: "c", status: .queued, minutes: 3),
        ], elapsed: "2h45")),
        ("Eight active", PillModel(indicators: [
            .run(ref: "a", status: .running, minutes: 134),
            .run(ref: "b", status: .running, minutes: 41),
            .run(ref: "c", status: .running, minutes: 6),
        ], overflowCount: 5, elapsed: "2h14")),
        ("Near the 12 h limit", PillModel(indicators: [
            .run(ref: "a", status: .running, minutes: 680),
            .run(ref: "b", status: .queued, minutes: 75),
        ], elapsed: "11h20")),
        ("Check failed, last runs kept", PillModel(indicators: [
            .run(ref: "a", status: .running, minutes: 47),
        ], showsWarning: true, elapsed: "47m")),
        ("Check failed, nothing known", PillModel(indicators: [.checking], showsWarning: true)),
    ]

    func testEveryStateRendersAndWidthGrowsWithContent() throws {
        let images = Self.scenarios.map { scenario in
            (scenario.name, render(scenario.model, appearance: .aqua), render(scenario.model, appearance: .darkAqua))
        }
        if let path = ProcessInfo.processInfo.environment["PILL_GALLERY"] {
            try writeGallery(images, to: URL(fileURLWithPath: path))
        }

        var previousRingCount = 0
        var previousWidth: CGFloat = 0
        for (_, model) in Self.scenarios where model.overflowCount == 0 && !model.showsWarning && model.elapsed == nil {
            let width = StatusPillView.width(for: model)
            if model.indicators.count > previousRingCount { XCTAssertGreaterThan(width, previousWidth) }
            previousRingCount = model.indicators.count
            previousWidth = width
        }
        let one = StatusPillView.width(for: Self.scenarios[4].model)
        let three = StatusPillView.width(for: Self.scenarios[5].model)
        XCTAssertEqual(three - one, 2 * PillMetrics.ringStep, accuracy: 0.5)
        // "+N" takes the fourth ring's slot, so eight runs are no wider than four.
        var four = Self.scenarios[6].model
        four.overflowCount = 0
        four.indicators.append(.run(ref: "d", status: .queued, minutes: 2))
        XCTAssertEqual(StatusPillView.width(for: Self.scenarios[6].model), StatusPillView.width(for: four))
    }

    func testCompactElapsedTimeReadsLikeAClock() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cases: [(TimeInterval, String)] = [
            (20, "now"), (47 * 60, "47m"), (125 * 60, "2h05"), (134 * 60 + 59, "2h14"), (11 * 3600, "11h"),
        ]
        for (seconds, expected) in cases {
            XCTAssertEqual(ElapsedTime.compact(since: now.addingTimeInterval(-seconds), now: now), expected)
        }
    }

    private func render(_ model: PillModel, appearance: NSAppearance.Name) -> NSBitmapImageRep {
        let width = StatusPillView.width(for: model)
        let view = StatusPillView(frame: NSRect(x: 0, y: 0, width: width, height: PillMetrics.height))
        view.appearance = NSAppearance(named: appearance)
        view.apply(model, animated: false)
        let scale: CGFloat = 4
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(PillMetrics.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Each state on a light and a dark menu bar strip, labelled.
    private func writeGallery(_ images: [(String, NSBitmapImageRep, NSBitmapImageRep)], to url: URL) throws {
        let scale: CGFloat = 4
        let rowHeight: CGFloat = 34
        let labelWidth: CGFloat = 190
        let column: CGFloat = 130
        let size = NSSize(width: labelWidth + column * 2, height: rowHeight * CGFloat(images.count))
        let canvas = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        canvas.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        for (index, (name, light, dark)) in images.enumerated() {
            let y = size.height - rowHeight * CGFloat(index + 1)
            (name as NSString).draw(at: NSPoint(x: 10, y: y + 10),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
            for (offset, rep, bar) in [(labelWidth, light, NSColor(white: 0.93, alpha: 1)), (labelWidth + column, dark, NSColor(white: 0.16, alpha: 1))] {
                bar.setFill()
                NSRect(x: offset, y: y + 6, width: column, height: PillMetrics.height).fill()
                rep.draw(in: NSRect(x: offset + column - rep.size.width - 8, y: y + 6, width: rep.size.width, height: rep.size.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(canvas.representation(using: .png, properties: [:])).write(to: url)
    }
}
