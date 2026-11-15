import AppKit
import QuartzCore

/// What the menu bar item shows. Built from the store by `StatusItemController`.
struct PillModel: Equatable {
    enum Indicator: Equatable {
        /// `minutes` since the run started or was queued, when known. Whole
        /// minutes, so the model changes, and the item redraws, once a minute.
        case run(ref: String, status: NotebookRunStatus, minutes: Int?, accelerator: Accelerator? = nil)
        /// A hollow ring while connecting or before the first status check.
        case checking
    }

    var indicators: [Indicator] = []
    var overflowCount = 0
    var showsWarning = false
    /// Exact time of the longest active run, e.g. "2h45".
    var elapsed: String?
}

/// Geometry of the graphite capsule: [k] [circles, the last maybe "+N"] [!]
/// [time]. It fills the 22 pt menu bar lane, as the original app's did.
enum PillMetrics {
    static let height: CGFloat = 22
    static let leadingInset: CGFloat = 7.5
    static let markHeight: CGFloat = 11
    static let markGap: CGFloat = 5
    /// Circle centers are this far apart, so neighbours overlap by 4 pt.
    static let ringStep: CGFloat = 13
    static let maxVisibleRings = 4
    /// Space between the stack and the warning circle, which never overlaps.
    static let warningGap: CGFloat = 2
    static let timeGap: CGFloat = 5
    static let timeTrailingInset: CGFloat = 8
    static let transitionDuration: CFTimeInterval = 0.22

    static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    static var markWidth: CGFloat { KaggleMark.width(forHeight: markHeight) }
}

/// The status item's drawing. The status item shows it as its button's image
/// (`image(for:width:)`); the view draws the same pill for the rendering
/// tests and gallery. The capsule keeps its colors on light and dark menu bars.
@MainActor
final class StatusPillView: NSView {
    private var model = PillModel()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    static func width(for model: PillModel) -> CGFloat {
        Layout(model).width
    }

    func apply(_ model: PillModel, animated: Bool) {
        guard model != self.model else { return }
        self.model = model
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = PillMetrics.transitionDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: "contents")
        }
        needsDisplay = true
        displayIfNeeded()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        Self.draw(model, in: context, bounds: bounds)
    }

    /// The pill as a status button image, right-aligned in `width` so the
    /// capsule stays still while the item's length changes around it. The
    /// button draws it, so macOS dims it with the rest of the menu bar on an
    /// inactive display; a subview drawing the same pill stays bright there.
    /// The handler redraws at each display's scale.
    static func image(for model: PillModel, width: CGFloat) -> NSImage {
        let size = NSSize(width: max(width, Self.width(for: model)), height: PillMetrics.height)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(model, in: context, bounds: rect)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Kaggle"
        return image
    }

    private static func draw(_ model: PillModel, in context: CGContext, bounds: CGRect) {
        let layout = Layout(model)
        let midY = bounds.midY
        context.translateBy(x: floor(bounds.width - layout.width), y: floor(midY - PillMetrics.height / 2))
        let center = PillMetrics.height / 2

        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: layout.width, height: PillMetrics.height),
                               cornerWidth: center, cornerHeight: center, transform: nil))
        context.setFillColor(KaggleStyle.capsule.cgColor)
        context.fillPath()
        context.addPath(KaggleMark.path(in: CGRect(
            x: PillMetrics.leadingInset, y: (PillMetrics.height - PillMetrics.markHeight) / 2,
            width: PillMetrics.markWidth, height: PillMetrics.markHeight)))
        context.setFillColor(KaggleStyle.onCapsule.cgColor)
        context.fillPath()

        // The first circle sits on top, so each one hides the left of the
        // next and every dial shows from 12 o'clock round.
        for (ring, x) in layout.rings.reversed() {
            ring.draw(in: context, center: CGPoint(x: x, y: center))
        }
        if let x = layout.timeX, let elapsed = model.elapsed {
            TextLine(elapsed, font: PillMetrics.timeFont, color: KaggleStyle.onCapsule)
                .draw(in: context, x: x, midY: center)
        }
    }

    /// One pass that both sizes the item and places its contents, so the
    /// status item length and the drawing can never disagree.
    private struct Layout {
        var rings: [(ring: ClockRing, centerX: CGFloat)] = []
        var timeX: CGFloat?
        var width: CGFloat

        init(_ model: PillModel) {
            var stack: [ClockRing] = model.indicators.map { indicator in
                switch indicator {
                case let .run(_, status, minutes, accelerator):
                    ClockRing(style: status == .running ? .running : .queued, minutes: minutes, accelerator: accelerator)
                case .checking:
                    ClockRing(style: .checking)
                }
            }
            if model.overflowCount > 0 {
                stack.append(ClockRing(style: .more(model.overflowCount)))
            }

            // Whole-point start for the first circle keeps 1x displays crisp.
            var centerX = ceil(PillMetrics.leadingInset + PillMetrics.markWidth + PillMetrics.markGap) + ClockRing.outerRadius
            for ring in stack {
                rings.append((ring, centerX))
                centerX += PillMetrics.ringStep
            }
            if model.showsWarning {
                if !stack.isEmpty {
                    centerX += 2 * ClockRing.outerRadius + PillMetrics.warningGap - PillMetrics.ringStep
                }
                rings.append((ClockRing(style: .warning), centerX))
            }

            guard let last = rings.last?.centerX else {
                // A lone k becomes a 22 pt circle.
                width = max(PillMetrics.height, ceil(2 * PillMetrics.leadingInset + PillMetrics.markWidth))
                return
            }
            if let elapsed = model.elapsed, !model.indicators.isEmpty {
                let x = last + ClockRing.outerRadius + PillMetrics.timeGap
                timeX = x
                width = ceil(x + TextLine(elapsed, font: PillMetrics.timeFont, color: KaggleStyle.onCapsule).width
                    + PillMetrics.timeTrailingInset)
            } else {
                // The last circle is concentric with the capsule's end cap.
                width = ceil(last + PillMetrics.height / 2)
            }
        }
    }
}
