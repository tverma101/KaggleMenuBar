import AppKit
import SwiftUI

/// Borderless glass panel that drops from the status item like a menu bar
/// extra window: no arrow, aligned to the item's leading edge, closed by a
/// click elsewhere, Escape, or switching apps. It grows from just under the
/// item as it fades in and shrinks back a little as it fades out.
@MainActor
final class MenuBarPanel: NSPanel {
    static let cornerRadius: CGFloat = 16
    private static let gap: CGFloat = 5

    private let hostingView: NSHostingView<AnyView>
    /// The glass, inside a plain container so it can scale while the window
    /// keeps its frame.
    private let surface: NSView
    private var anchor: NSRect = .zero
    private var contentSize: CGSize = .zero
    private var outsideClickMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// Lets a newer open or close cancel the end of an older one.
    private var transitionGeneration = 0
    private(set) var isOpen = false
    var onClose: (() -> Void)?

    init<Content: View>(content: Content) {
        hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        surface = Self.makeBackground(containing: hostingView)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace, .fullScreenAuxiliary]

        // Report the SwiftUI ideal size without adding Auto Layout constraints;
        // the panel frame is set explicitly so it stays top-anchored.
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.rootView = AnyView(
            content.onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] size in
                self?.contentSizeChanged(size)
            }
        )
        let container = NSView()
        container.wantsLayer = true
        surface.wantsLayer = true
        surface.frame = container.bounds
        surface.autoresizingMask = [.width, .height]
        container.addSubview(surface)
        contentView = container
    }

    override var canBecomeKey: Bool { true }

    func open(below anchor: NSRect) {
        self.anchor = anchor
        hostingView.layoutSubtreeIfNeeded()
        let ideal = hostingView.intrinsicContentSize
        if ideal.width > 0, ideal.height > 0 { contentSize = ideal }
        reposition()

        isOpen = true
        // A panel reopened while still closing fades back from where it is.
        if !isVisible { alphaValue = 0 }
        makeKeyAndOrderFront(nil)
        NSApp.activate()
        // Opening with the mouse should not land a focus ring on the first
        // button; Tab still moves focus into the panel.
        makeFirstResponder(nil)
        transition(opening: true)
        installMonitors()
    }

    func dismiss() {
        guard isOpen else { return }
        isOpen = false
        removeMonitors()
        transition(opening: false)
        onClose?()
    }

    private func transition(opening: Bool) {
        transitionGeneration += 1
        let generation = transitionGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = opening ? Motion.fadeIn : Motion.fadeOut
            context.timingFunction = CAMediaTimingFunction(name: opening ? .easeOut : .easeIn)
            animator().alphaValue = opening ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !opening, self.transitionGeneration == generation else { return }
                self.orderOut(nil)
                self.alphaValue = 1
                self.surface.layer?.removeAnimation(forKey: Motion.key)
            }
        })

        guard let layer = surface.layer else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            layer.removeAnimation(forKey: Motion.key)
            return
        }
        // An interrupted transition carries on from its current scale.
        let current = layer.animation(forKey: Motion.key) == nil
            ? nil : layer.presentation().map { NSValue(caTransform3D: $0.transform) }
        let scale: CAAnimation
        if opening {
            let spring = CASpringAnimation(perceptualDuration: Motion.grow, bounce: 0)
            spring.keyPath = "transform"
            spring.fromValue = current ?? Self.scaledFromTop(Motion.openScale, layer: layer)
            spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            spring.duration = spring.settlingDuration
            scale = spring
        } else {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = current ?? NSValue(caTransform3D: CATransform3DIdentity)
            shrink.toValue = Self.scaledFromTop(Motion.closeScale, layer: layer)
            shrink.duration = Motion.fadeOut
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            // Held until the window is ordered out.
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            scale = shrink
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                // The window shadow follows the panel's shape when it is
                // taken, so retake it once the panel is at full size.
                guard let self, opening, self.transitionGeneration == generation else { return }
                self.invalidateShadow()
            }
        }
        layer.add(scale, forKey: Motion.key)
        CATransaction.commit()
    }

    /// Scales about the middle of the top edge, the side nearest the status
    /// item. Layer transforms apply about the anchor point, and the container
    /// is not flipped, so the top edge is at the largest y.
    private static func scaledFromTop(_ scale: CGFloat, layer: CALayer) -> NSValue {
        let size = layer.bounds.size
        let pivot = CGPoint(x: size.width * (0.5 - layer.anchorPoint.x),
                            y: size.height * (1 - layer.anchorPoint.y))
        var transform = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -pivot.x, -pivot.y, 0)
        return NSValue(caTransform3D: transform)
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    private func contentSizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != contentSize else { return }
        contentSize = size
        if isVisible { reposition() }
    }

    /// Top-anchored under the status item, clamped to the screen's visible area.
    private func reposition() {
        guard contentSize != .zero else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - Self.gap - contentSize.height)
        origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - contentSize.width - 6)
        setFrame(NSRect(origin: origin, size: contentSize), display: true)
        invalidateShadow()
    }

    private func installMonitors() {
        removeMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    private func removeMonitors() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        outsideClickMonitor = nil
        resignObserver = nil
    }

    private static func makeBackground(containing content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
        }

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        content.frame = effect.bounds
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        return effect
    }
}

private enum Motion {
    static let key = "drop"
    static let openScale: CGFloat = 0.94
    static let closeScale: CGFloat = 0.97
    /// The spring's perceived duration; it settles a little later.
    static let grow: TimeInterval = 0.22
    static let fadeIn: TimeInterval = 0.18
    static let fadeOut: TimeInterval = 0.15
}
