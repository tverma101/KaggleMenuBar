import AppKit
import QuartzCore

/// What the menu bar item shows. Built from the store by `StatusItemController`.
struct PillModel: Equatable {
    enum Indicator: Equatable {
        /// `minutes` since the run started or was queued, when known. Whole
        /// minutes, so the model changes, and the item redraws, once a minute.
        case run(ref: String, status: NotebookRunStatus, minutes: Int?)
        /// A bare ring while connecting or before the first status check.
        case checking
    }

    var indicators: [Indicator] = []
    var overflowCount = 0
    var showsWarning = false
    /// Exact time of the longest active run, e.g. "2h45".
    var elapsed: String?
}

/// Geometry of the item: [k] [rings, the last maybe "+N"] [time] [!], in a
/// 22 pt lane.
enum PillMetrics {
    static let height: CGFloat = 22
    static let inset: CGFloat = 3
    /// Width of a status item with only the k in it.
    static let minimumWidth: CGFloat = 20
    static let markGap: CGFloat = 3
    /// Ring centers are this far apart, so neighbours overlap by 3 pt.
    static let ringStep: CGFloat = 12
    static let maxVisibleRings = 4
    static let gap: CGFloat = 4
    static let transitionDuration: CFTimeInterval = 0.22

    static let markFont = NSFont.rounded(15, weight: .bold)
    static let timeFont = NSFont.rounded(12, weight: .semibold, monospacedDigits: true)
}

/// The status item's drawing. It sits on top of the `NSStatusBarButton`,
/// passes every click through to it, and right-aligns its content so the
/// content stays still while the status item's length changes around it.
/// Colors follow the menu bar's appearance.
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

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
        let layout = Layout(model)
        let midY = bounds.midY
        context.translateBy(x: floor(bounds.width - layout.width), y: 0)

        let mark = TextLine("k", font: PillMetrics.markFont, color: .labelColor)
        let markBounds = mark.glyphBounds
        mark.drawCenteredOnGlyphs(in: context, at: CGPoint(x: layout.markX + markBounds.width / 2, y: midY))

        drawRings(layout.rings, in: context, midY: midY)

        if let x = layout.timeX, let elapsed = model.elapsed {
            TextLine(elapsed, font: PillMetrics.timeFont, color: .labelColor)
                .draw(in: context, x: x, midY: midY)
        }
        if let x = layout.warningCenterX {
            drawWarning(in: context, center: CGPoint(x: x, y: midY))
        }
    }

    /// The first ring sits on top. Each ring clears a slightly larger circle
    /// out of the ring beneath it, inside a transparency layer so the clearing
    /// never reaches the menu bar behind the item.
    private func drawRings(_ rings: [(ring: ClockRing, centerX: CGFloat)], in context: CGContext, midY: CGFloat) {
        guard !rings.isEmpty else { return }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for (ring, x) in rings.reversed() {
            let center = CGPoint(x: x, y: midY)
            context.saveGState()
            context.setBlendMode(.clear)
            let cutout = ClockRing.cutoutRadius
            context.fillEllipse(in: CGRect(x: center.x - cutout, y: center.y - cutout, width: cutout * 2, height: cutout * 2))
            context.restoreGState()
            ring.draw(in: context, center: center)
        }
        context.endTransparencyLayer()
    }

    private func drawWarning(in context: CGContext, center: CGPoint) {
        let radius = ClockRing.outerRadius
        context.setFillColor(KaggleStyle.warning.cgColor)
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        TextLine("!", font: .rounded(11, weight: .heavy), color: .black.withAlphaComponent(0.85))
            .drawCenteredOnGlyphs(in: context, at: center)
    }

    /// One pass that both sizes the item and places its contents, so the
    /// status item length and the drawing can never disagree.
    private struct Layout {
        var markX: CGFloat = PillMetrics.inset
        var rings: [(ring: ClockRing, centerX: CGFloat)] = []
        var timeX: CGFloat?
        var warningCenterX: CGFloat?
        var width: CGFloat = PillMetrics.minimumWidth

        init(_ model: PillModel) {
            let markWidth = TextLine("k", font: PillMetrics.markFont, color: .labelColor).glyphBounds.width
            var x = PillMetrics.inset + markWidth

            var stack: [ClockRing] = model.indicators.map { indicator in
                switch indicator {
                case let .run(_, status, minutes):
                    ClockRing(style: status == .running ? .running : .queued, minutes: minutes)
                case .checking:
                    ClockRing(style: .checking, minutes: nil)
                }
            }
            if model.overflowCount > 0 {
                stack.append(ClockRing(style: .more(model.overflowCount), minutes: nil))
            }
            if !stack.isEmpty {
                x += PillMetrics.markGap
                var centerX = x + ClockRing.outerRadius
                for ring in stack {
                    rings.append((ring, centerX))
                    centerX += PillMetrics.ringStep
                }
                x = centerX - PillMetrics.ringStep + ClockRing.outerRadius
            }
            if let elapsed = model.elapsed, !model.indicators.isEmpty {
                x += PillMetrics.gap
                timeX = x
                x += TextLine(elapsed, font: PillMetrics.timeFont, color: .labelColor).width
            }
            if model.showsWarning {
                x += PillMetrics.gap
                warningCenterX = x + ClockRing.outerRadius
                x += ClockRing.outerRadius * 2
            }
            x += PillMetrics.inset

            // A lone k is centered in a small square-ish item.
            let lead = max(0, (PillMetrics.minimumWidth - x) / 2)
            markX += lead
            rings = rings.map { ($0.ring, $0.centerX + lead) }
            timeX = timeX.map { $0 + lead }
            warningCenterX = warningCenterX.map { $0 + lead }
            width = ceil(max(PillMetrics.minimumWidth, x))
        }
    }
}
