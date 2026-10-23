import AppKit
import SwiftUI

/// A run's circle in the panel: the menu bar circle on a graphite disc,
/// larger, drawn by the same code.
struct RunRing: View {
    let run: NotebookRun
    let now: Date
    var size: CGFloat = 24

    var body: some View {
        MarkCanvas(ring: ClockRing(
            style: run.status == .running ? .running : .queued,
            minutes: run.lastRunAt.map { max(0, Int(now.timeIntervalSince($0) / 60)) },
            accelerator: run.accelerator
        ))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The app icon, for the panel header.
struct BrandBadge: View {
    var size: CGFloat = 30

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Hosts the Core Graphics circle the menu bar item draws.
private struct MarkCanvas: NSViewRepresentable {
    let ring: ClockRing

    func makeNSView(context: Context) -> MarkView { MarkView(ring: ring) }

    func updateNSView(_ view: MarkView, context: Context) {
        view.ring = ring
    }
}

private final class MarkView: NSView {
    var ring: ClockRing {
        didSet { if ring != oldValue { needsDisplay = true } }
    }

    init(ring: ClockRing) {
        self.ring = ring
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Clicks belong to the row button around the mark.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // As much capsule around the circle as the menu bar's end cap has.
        let side = min(bounds.width, bounds.height)
        let backing = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        context.setFillColor(KaggleStyle.capsule.cgColor)
        context.fillEllipse(in: backing)
        ring.draw(in: context, center: CGPoint(x: bounds.midX, y: bounds.midY), scale: side / PillMetrics.height)
    }
}
