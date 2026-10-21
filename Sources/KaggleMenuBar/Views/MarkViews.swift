import AppKit
import SwiftUI

/// A run's ring in the panel: the menu bar ring, larger, drawn by the same code.
struct RunRing: View {
    let run: NotebookRun
    let now: Date
    var size: CGFloat = 20

    var body: some View {
        MarkCanvas(content: .ring(ClockRing(
            style: run.status == .running ? .running : .queued,
            minutes: run.lastRunAt.map { max(0, Int(now.timeIntervalSince($0) / 60)) }
        )))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The app's mark for the panel header.
struct BrandBadge: View {
    var size: CGFloat = 26

    var body: some View {
        MarkCanvas(content: .brand)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Hosts the Core Graphics marks, which resolve system colors against the
/// panel's appearance the same way the menu bar item does.
private struct MarkCanvas: NSViewRepresentable {
    let content: MarkView.Content

    func makeNSView(context: Context) -> MarkView { MarkView() }

    func updateNSView(_ view: MarkView, context: Context) {
        view.content = content
    }
}

private final class MarkView: NSView {
    enum Content: Equatable {
        case ring(ClockRing)
        case brand
    }

    var content: Content = .brand {
        didSet { if content != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
        let side = min(bounds.width, bounds.height)
        switch content {
        case let .ring(ring):
            let scale = side / (ClockRing.outerRadius * 2 + 0.5)
            ring.draw(in: context, center: CGPoint(x: bounds.midX, y: bounds.midY), scale: scale)
        case .brand:
            BrandMark.draw(in: context, rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        }
    }
}
