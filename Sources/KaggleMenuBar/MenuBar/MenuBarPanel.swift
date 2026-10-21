import AppKit
import SwiftUI

/// Borderless glass panel that drops from the status item like a menu bar
/// extra window: no arrow, aligned to the item's leading edge, closed by a
/// click elsewhere, Escape, or switching apps.
@MainActor
final class MenuBarPanel: NSPanel {
    static let cornerRadius: CGFloat = 16
    private static let gap: CGFloat = 5

    private let hostingView: NSHostingView<AnyView>
    private var anchor: NSRect = .zero
    private var contentSize: CGSize = .zero
    private var outsideClickMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    var onClose: (() -> Void)?

    init<Content: View>(content: Content) {
        hostingView = NSHostingView(rootView: AnyView(EmptyView()))
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
        contentView = Self.makeBackground(containing: hostingView)
    }

    override var canBecomeKey: Bool { true }

    var isOpen: Bool { isVisible }

    func open(below anchor: NSRect) {
        self.anchor = anchor
        hostingView.layoutSubtreeIfNeeded()
        let ideal = hostingView.intrinsicContentSize
        if ideal.width > 0, ideal.height > 0 { contentSize = ideal }
        reposition()

        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSApp.activate()
        // Opening with the mouse should not land a focus ring on the first
        // button; Tab still moves focus into the panel.
        makeFirstResponder(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
        installMonitors()
    }

    func dismiss() {
        guard isVisible else { return }
        removeMonitors()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.orderOut(nil)
                self?.alphaValue = 1
            }
        })
        onClose?()
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
