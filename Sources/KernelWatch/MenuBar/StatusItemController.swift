import AppKit
import Combine
import OSLog
import SwiftUI

/// Owns the status item: keeps the pill in sync with the store, shows or hides
/// the item automatically, and toggles the panel on click.
@MainActor
final class StatusItemController: NSObject {
    private let logger = Logger(subsystem: "app.kernelwatch.KernelWatch", category: "MenuBar")
    private let store: NotebookStore
    private let statusItem: NSStatusItem
    private let pillView = StatusPillView(frame: .zero)
    private lazy var panel: MenuBarPanel = {
        let panel = MenuBarPanel(content: StatusPopover(store: store, onOpen: { [weak self] url in
            NSWorkspace.shared.open(url)
            self?.panel.dismiss()
        }))
        panel.onClose = { [weak self] in self?.statusItem.button?.highlight(false) }
        return panel
    }()

    private var subscription: AnyCancellable?
    private var renderedModel: PillModel?
    /// Whether the pill is showing. Idle collapses the item rather than
    /// removing it; see `setItemShown`.
    private var isShown = true
    private var shrinkGeneration = 0
    /// Ticks the elapsed-time labels while a run with a start time is shown.
    private var clock: Timer?

    init(store: NotebookStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: PillMetrics.height)
        super.init()

        // The autosave name is how macOS remembers where the user put the item.
        statusItem.autosaveName = "KernelWatchStatusItem"
        statusItem.behavior = []
        // Builds that hid the item with `isVisible` left it saved as hidden.
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = nil
            button.title = ""
            button.imagePosition = .noImage
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])

            pillView.frame = button.bounds
            pillView.autoresizingMask = [.width, .height]
            button.addSubview(pillView)
        }

        subscription = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
        render()

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(hiddenBarAskedForPresence(_:)),
            name: HiddenBarPresence.request, object: nil, suspensionBehavior: .deliverImmediately)
        announcePresence()
    }

    @objc private func hiddenBarAskedForPresence(_ notification: Notification) {
        announcePresence()
    }

    /// Tells Hidden Bar whether the item has anything to show. While its icons
    /// are hidden, Hidden Bar hides an idle item the way it hides its hidden
    /// section, which leaves no gap and keeps the item's place.
    private func announcePresence() {
        guard let bundle = Bundle.main.bundleIdentifier else { return }
        DistributedNotificationCenter.default().postNotificationName(
            isShown ? HiddenBarPresence.active : HiddenBarPresence.idle,
            object: bundle, userInfo: nil, deliverImmediately: true)
    }

    @objc private func togglePanel(_ sender: Any?) {
        if panel.isOpen {
            panel.dismiss()
            return
        }
        showPanel()
    }

    /// Reopening Kaggle from Spotlight/Finder also works while its item is hidden.
    func showPanel() {
        let anchor: NSRect
        if isShown, let button = statusItem.button, let window = button.window {
            anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            button.highlight(true)
        } else {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            guard let screen else { return }
            let visible = screen.visibleFrame
            anchor = NSRect(x: visible.maxX - StatusPopover.width - 12,
                            y: visible.maxY + 5, width: StatusPopover.width, height: 0)
        }
        panel.open(below: anchor)
        logger.info("Opened status panel; item shown=\(self.isShown, privacy: .public)")
    }

    private func render() {
        let now = Date()
        let model = Self.pillModel(for: store, now: now)
        let target = StatusPillView.width(for: model)
        updateAccessibility(now: now)
        setItemShown(store.isStatusItemVisible, width: target)
        updateClock()
        guard model != renderedModel else { return }

        // The status item grows before the pill animates and shrinks only once
        // the pill has finished, so the capsule never clips or jumps. Changing
        // `length` every frame would make neighbouring items jitter.
        let animated = renderedModel != nil && isShown
        shrinkGeneration += 1
        if isShown, target >= statusItem.length || !animated {
            statusItem.length = target
            syncPillFrame()
        }
        pillView.apply(model, animated: animated)
        renderedModel = model

        if isShown, target < statusItem.length {
            let generation = shrinkGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + PillMetrics.transitionDuration) { [weak self] in
                guard let self, self.shrinkGeneration == generation else { return }
                self.statusItem.length = target
                self.syncPillFrame()
            }
        }
    }

    /// Idle collapses the item to zero width instead of setting `isVisible`.
    /// macOS 27 keeps an app's menu bar position only while its item exists: a
    /// removed item, or one the app quit with, returns at the far left, which is
    /// the hidden side of menu bar managers like Hidden Bar. A zero-width item
    /// still leaves a gap of about 10 pt, so Hidden Bar is also told to hide it.
    private func setItemShown(_ shown: Bool, width: CGFloat) {
        guard shown != isShown else { return }
        isShown = shown
        // A pending shrink must not reopen a collapsed item.
        shrinkGeneration += 1
        if shown {
            statusItem.length = width
            pillView.isHidden = false
            syncPillFrame()
        } else {
            panel.dismiss()
            pillView.isHidden = true
            statusItem.length = 0
        }
        announcePresence()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isShown == shown else { return }
            let x = self.statusItem.button?.window?.frame.minX ?? -1
            self.logger.info("Status item shown=\(shown, privacy: .public), x=\(x, privacy: .public), active runs=\(self.store.activeRuns.count, privacy: .public)")
        }
    }

    private func updateClock() {
        let needsClock = isShown && store.activeRuns.contains { $0.lastRunAt != nil }
        if needsClock, clock == nil {
            // Labels change once a minute; a 15 s tick keeps them within a few
            // seconds without waking the app more than it needs to.
            let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.render() }
            }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            clock = timer
        } else if !needsClock, let clock {
            clock.invalidate()
            self.clock = nil
        }
    }

    private func syncPillFrame() {
        guard let button = statusItem.button else { return }
        button.layoutSubtreeIfNeeded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillView.frame = button.bounds
        pillView.layoutSubtreeIfNeeded()
        CATransaction.commit()
    }

    static func pillModel(for store: NotebookStore, now: Date) -> PillModel {
        var model = PillModel()
        switch store.connectionState {
        case .disconnected:
            break
        case .connecting:
            model.indicators = [.checking]
        case .connected:
            // Running circles first, then queued, so the colors read as two groups.
            let running = store.activeRuns.filter { $0.status == .running }
            let queued = store.activeRuns.filter { $0.status == .queued }
            let runs = running + queued
            let visible = runs.count > PillMetrics.maxVisibleDots
                ? Array(runs.prefix(PillMetrics.maxVisibleDots - 1))
                : runs
            model.indicators = visible.map { .run(ref: $0.ref, status: $0.status) }
            model.overflowCount = runs.count - visible.count
            // The longest-running notebook, or the longest wait when none has started.
            let timed = (running.isEmpty ? queued : running).compactMap(\.lastRunAt)
            model.elapsed = timed.min().map { ElapsedTime.compact(since: $0, now: now) }
            if runs.isEmpty, store.snapshotState == .checking {
                model.indicators = [.checking]
            }
        }
        model.showsWarning = store.errorMessage != nil
        return model
    }

    private func updateAccessibility(now: Date) {
        guard let button = statusItem.button else { return }
        let summary: String
        switch store.connectionState {
        case .disconnected:
            summary = "Kaggle: not connected"
        case .connecting:
            summary = "Kaggle: connecting"
        case .connected:
            if store.snapshotState == .failed {
                summary = "Kaggle: status check failed"
            } else if store.activeRuns.isEmpty {
                summary = store.snapshotState == .checking ? "Kaggle: checking notebooks" : "Kaggle: nothing running"
            } else {
                summary = "Kaggle: \(store.runningCount) running, \(store.queuedCount) queued"
            }
        }
        button.setAccessibilityLabel(summary)

        var lines = [summary]
        lines += store.activeRuns.prefix(8).map { run in
            let elapsed = run.lastRunAt.map { " \(ElapsedTime.label(since: $0, now: now))" } ?? ""
            return "\(run.status.label)\(elapsed) · \(run.title)"
        }
        if store.activeRuns.count > 8 { lines.append("and \(store.activeRuns.count - 8) more") }
        if let error = store.errorMessage { lines.append(error) }
        button.toolTip = lines.joined(separator: "\n")
    }
}

/// Hidden Bar's notifications for apps whose status items go idle. The object
/// is the sender's bundle identifier.
private enum HiddenBarPresence {
    static let idle = Notification.Name("com.dwarvesv.minimalbar.statusItemsIdle")
    static let active = Notification.Name("com.dwarvesv.minimalbar.statusItemsActive")
    /// Posted when Hidden Bar starts.
    static let request = Notification.Name("com.dwarvesv.minimalbar.statusItemsPresenceRequest")
}
