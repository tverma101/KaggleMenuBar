import AppKit
import SwiftUI

/// A run's ring in the panel: the menu bar ring, larger, drawn by the same code.
struct RunRing: View {
    let run: NotebookRun
    let now: Date
    var size: CGFloat = 20

    var body: some View {
        MarkCanvas(ring: ClockRing(
            style: run.status == .running ? .running : .queued,
            minutes: run.lastRunAt.map { max(0, Int(now.timeIntervalSince($0) / 60)) }
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

/// Hosts the Core Graphics ring, which resolves system colors against the
/// panel's appearance the same way the menu bar item does.
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = min(bounds.width, bounds.height) / (ClockRing.outerRadius * 2 + 0.5)
        ring.draw(in: context, center: CGPoint(x: bounds.midX, y: bounds.midY), scale: scale)
    }
}
