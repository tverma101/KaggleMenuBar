import AppKit
import QuartzCore

/// What the menu bar pill shows. Built from the store by `StatusItemController`.
struct PillModel: Equatable {
    enum Indicator: Equatable {
        case run(ref: String, status: NotebookRunStatus)
        /// Hollow circle while connecting or before the first status check.
        case checking
    }

    var indicators: [Indicator] = []
    var overflowCount = 0
    var showsWarning = false
    /// How long the longest active run has been going, e.g. "47m".
    var elapsed: String?
}

/// Geometry for the Kaggle-blue capsule. It fills the 22 pt status bar lane, and
/// the circles overlap by about a third of their width, the usual proportion
/// for avatar stacks.
enum PillMetrics {
    static let height: CGFloat = 22
    static let leadingInset: CGFloat = 7.5
    static let markHeight: CGFloat = 11
    static let markGap: CGFloat = 5
    static let dotDiameter: CGFloat = 13
    /// White ring that keeps each circle apart from the one it overlaps.
    static let dotRing: CGFloat = 1.5
    static let dotOverlap: CGFloat = 4.5
    static let timeGap: CGFloat = 5
    static let timeTrailingInset: CGFloat = 8
    static let maxVisibleDots = 4
    static let transitionDuration: CFTimeInterval = 0.28

    static var markWidth: CGFloat { KaggleMark.width(forHeight: markHeight) }
    /// Whole-point start for the first circle so 1x displays stay crisp.
    static var contentOriginX: CGFloat { ceil(leadingInset + markWidth + markGap) }
    static var dotStep: CGFloat { dotDiameter - dotOverlap }
    /// Puts the last circle concentric with the capsule's end cap.
    static var dotTrailingInset: CGFloat { (height - dotDiameter) / 2 }
}

/// Text in the pill: digits that keep their width as minutes tick.
enum PillText {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    static func makeLayer(font: NSFont = font, color: NSColor) -> CATextLayer {
        let label = CATextLayer()
        label.font = font
        label.fontSize = font.pointSize
        label.foregroundColor = color.cgColor
        label.alignmentMode = .center
        return label
    }

    static func width(of text: String, font: NSFont = font) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Frame for a one-line label whose cap height is centered in `height`.
    static func frame(font: NSFont = font, x: CGFloat, width: CGFloat, height: CGFloat = PillMetrics.height) -> CGRect {
        let baseline = ((height - font.capHeight) / 2).rounded()
        return CGRect(x: x, y: baseline + font.descender, width: width, height: ceil(font.ascender - font.descender))
    }
}

/// The status item's drawing. It sits on top of the `NSStatusBarButton`, passes
/// every click through to it, and right-aligns the capsule so the capsule stays
/// still while the status item's length changes around it.
@MainActor
final class StatusPillView: NSView {
    private let capsule = CALayer()
    private let mark = CAShapeLayer()
    private var elements: [String: CALayer] = [:]
    private(set) var pillWidth: CGFloat = PillMetrics.height

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        capsule.backgroundColor = KaggleStyle.blue.cgColor
        capsule.cornerRadius = PillMetrics.height / 2
        capsule.cornerCurve = .circular
        capsule.masksToBounds = false
        layer?.addSublayer(capsule)

        mark.fillColor = NSColor.white.cgColor
        mark.path = KaggleMark.path(
            in: CGRect(x: 0, y: 0, width: PillMetrics.markWidth, height: PillMetrics.markHeight),
            flipped: false
        )
        capsule.addSublayer(mark)
        layoutCapsule(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for element in elements.values {
            element.contentsScale = scale
            element.sublayers?.forEach { $0.contentsScale = scale }
        }
    }

    override func layout() {
        super.layout()
        layoutCapsule(animated: false)
    }

    static func width(for model: PillModel) -> CGFloat {
        slots(for: model).width
    }

    func apply(_ model: PillModel, animated: Bool) {
        let (slots, width) = Self.slots(for: model)
        pillWidth = width
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        CATransaction.begin()
        CATransaction.setDisableActions(!animate)
        CATransaction.setAnimationDuration(PillMetrics.transitionDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.28, 1))

        layoutCapsule(animated: animate)

        for slot in slots {
            switch slot.content {
            case let .dot(style):
                let dot = element(slot.key) { DotLayer() } as! DotLayer
                dot.configure(style)
                place(dot, animated: animate, frame: slot.frame, depth: slot.depth)
            case let .time(text):
                let label = element(slot.key) { PillText.makeLayer(color: KaggleStyle.ink) } as! CATextLayer
                label.string = text
                place(label, animated: animate, frame: slot.frame, depth: slot.depth)
            }
        }

        let keep = Set(slots.map(\.key))
        for (key, layer) in elements where !keep.contains(key) {
            elements[key] = nil
            remove(layer, animated: animate)
        }

        CATransaction.commit()
    }

    // MARK: - Layout

    private struct Slot {
        enum Content {
            case dot(DotLayer.Style)
            case time(String)
        }

        let key: String
        let content: Content
        let frame: CGRect
        /// Later circles sit on top of earlier ones.
        let depth: CGFloat
    }

    /// One pass that both sizes the capsule and places its contents, so the
    /// status item length and the drawing can never disagree.
    private static func slots(for model: PillModel) -> (slots: [Slot], width: CGFloat) {
        var dots: [(key: String, style: DotLayer.Style)] = model.indicators.map { indicator in
            switch indicator {
            case let .run(ref, status):
                ("run:\(ref)", status == .running ? .running : .queued)
            case .checking:
                ("checking", .checking)
            }
        }
        if model.overflowCount > 0 { dots.append(("overflow", .overflow(model.overflowCount))) }
        if model.showsWarning { dots.append(("warning", .warning)) }

        var slots: [Slot] = []
        let origin = PillMetrics.contentOriginX
        let outer = PillMetrics.dotDiameter + 2 * PillMetrics.dotRing
        for (index, dot) in dots.enumerated() {
            let centerX = origin + PillMetrics.dotDiameter / 2 + CGFloat(index) * PillMetrics.dotStep
            slots.append(Slot(
                key: dot.key,
                content: .dot(dot.style),
                frame: CGRect(x: centerX - outer / 2, y: (PillMetrics.height - outer) / 2, width: outer, height: outer),
                depth: CGFloat(index + 1)
            ))
        }

        let stackEnd = origin + PillMetrics.dotDiameter + CGFloat(max(dots.count - 1, 0)) * PillMetrics.dotStep
        let width: CGFloat
        if dots.isEmpty {
            // A lone mark becomes a 22 pt circle.
            width = PillMetrics.leadingInset * 2 + PillMetrics.markWidth
        } else if let elapsed = model.elapsed {
            let x = stackEnd + PillMetrics.timeGap
            let textWidth = PillText.width(of: elapsed)
            slots.append(Slot(key: "time", content: .time(elapsed), frame: PillText.frame(x: x, width: textWidth), depth: 0))
            width = x + textWidth + PillMetrics.timeTrailingInset
        } else {
            width = stackEnd + PillMetrics.dotTrailingInset
        }
        return (slots, max(PillMetrics.height, ceil(width)))
    }

    private func layoutCapsule(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        let y = floor((bounds.height - PillMetrics.height) / 2)
        capsule.frame = CGRect(x: bounds.width - pillWidth, y: y, width: pillWidth, height: PillMetrics.height)
        mark.frame = CGRect(
            x: PillMetrics.leadingInset,
            y: (PillMetrics.height - PillMetrics.markHeight) / 2,
            width: PillMetrics.markWidth,
            height: PillMetrics.markHeight
        )
        CATransaction.commit()
    }

    private func element(_ key: String, make: () -> CALayer) -> CALayer {
        if let existing = elements[key] { return existing }
        let layer = make()
        layer.contentsScale = window?.backingScaleFactor ?? 2
        layer.sublayers?.forEach { $0.contentsScale = layer.contentsScale }
        layer.setValue(true, forKey: "isNew")
        capsule.addSublayer(layer)
        elements[key] = layer
        return layer
    }

    private func place(_ layer: CALayer, animated: Bool, frame: CGRect, depth: CGFloat) {
        layer.zPosition = depth
        guard layer.value(forKey: "isNew") as? Bool == true else {
            layer.frame = frame
            return
        }
        layer.setValue(nil, forKey: "isNew")
        // New elements fade in where they belong instead of sliding from the origin.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = frame
        layer.opacity = 1
        CATransaction.commit()
        guard animated else { return }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.7
        grow.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [fade, grow]
        group.duration = PillMetrics.transitionDuration
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.28, 1)
        layer.add(group, forKey: "appear")
    }

    private func remove(_ layer: CALayer, animated: Bool) {
        guard animated else {
            layer.removeFromSuperlayer()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        layer.opacity = 0
        layer.transform = CATransform3DMakeScale(0.7, 0.7, 1)
        CATransaction.commit()
    }
}

/// One circle in the stack: a Kaggle-colored disc inside a white ring, which
/// keeps overlapping circles apart on the blue capsule. Green while running,
/// orange while queued, yellow with "!" when a check failed, white with the
/// count of runs that did not fit.
final class DotLayer: CALayer {
    enum Style: Equatable {
        case running, queued, checking, warning
        case overflow(Int)
    }

    private let ring = CALayer()
    private let disc = CALayer()
    private let glyph = PillText.makeLayer(color: KaggleStyle.ink)
    private var glyphFont = PillText.font

    override init() {
        super.init()
        ring.borderColor = NSColor.white.cgColor
        addSublayer(ring)
        addSublayer(disc)
        addSublayer(glyph)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ style: Style) {
        var ringFill: NSColor? = .white
        var discFill: NSColor = .clear
        var text = ""
        var font = PillText.font
        switch style {
        case .running:
            discFill = KaggleStyle.green
        case .queued:
            discFill = KaggleStyle.orange
        case .checking:
            ringFill = nil
        case .warning:
            discFill = KaggleStyle.yellow
            text = "!"
            font = .systemFont(ofSize: 9.5, weight: .black)
        case let .overflow(count):
            discFill = .white
            text = "+\(count)"
            font = .monospacedDigitSystemFont(ofSize: count < 10 ? 8 : 6.5, weight: .heavy)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A hollow ring alone marks the check in progress.
        ring.backgroundColor = ringFill?.cgColor
        ring.borderWidth = ringFill == nil ? PillMetrics.dotRing : 0
        disc.backgroundColor = discFill.cgColor
        glyph.string = text
        glyph.font = font
        glyph.fontSize = font.pointSize
        glyphFont = font
        CATransaction.commit()
        setNeedsLayout()
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.cornerRadius = bounds.height / 2
        disc.frame = bounds.insetBy(dx: PillMetrics.dotRing, dy: PillMetrics.dotRing)
        disc.cornerRadius = disc.bounds.height / 2
        glyph.frame = PillText.frame(font: glyphFont, x: 0, width: bounds.width, height: bounds.height)
        CATransaction.commit()
    }
}
