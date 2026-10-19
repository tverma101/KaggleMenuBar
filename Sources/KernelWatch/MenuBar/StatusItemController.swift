import AppKit
import Combine
import SwiftUI

/// Owns the status item: keeps the pill in sync with the store, shows or hides
/// the item automatically, and toggles the panel on click.
@MainActor
final class StatusItemController: NSObject {
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
    private var shrinkGeneration = 0
    /// Ticks the elapsed-time labels while a run with a start time is shown.
    private var clock: Timer?

    init(store: NotebookStore) {
        self.store = store
        // A launch after quitting while hidden finds the position gone.
        ItemPosition.restore()
        statusItem = NSStatusBar.system.statusItem(withLength: PillMetrics.height)
        super.init()

        statusItem.autosaveName = ItemPosition.autosaveName
        statusItem.behavior = []
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
    }

    @objc private func togglePanel(_ sender: Any?) {
        if panel.isOpen {
            panel.dismiss()
            return
        }
        guard let button = statusItem.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        button.highlight(true)
        panel.open(below: anchor)
    }

    private func render() {
        let now = Date()
        let model = Self.pillModel(for: store, now: now)
        let isVisible = store.isStatusItemVisible
        updateAccessibility(now: now)
        setItemVisible(isVisible)
        updateClock()
        guard model != renderedModel else { return }

        // The status item grows before the pill animates and shrinks only once
        // the pill has finished, so the capsule never clips or jumps. Changing
        // `length` every frame would make neighbouring items jitter.
        let animated = renderedModel != nil && isVisible
        let target = StatusPillView.width(for: model)
        shrinkGeneration += 1
        if target >= statusItem.length || !animated {
            statusItem.length = target
            syncPillFrame()
        }
        pillView.apply(model, animated: animated)
        renderedModel = model

        if target < statusItem.length {
            let generation = shrinkGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + PillMetrics.transitionDuration) { [weak self] in
                guard let self, self.shrinkGeneration == generation else { return }
                self.statusItem.length = target
                self.syncPillFrame()
            }
        }
    }

    /// Hiding a status item makes macOS forget where the user dragged it, and a
    /// returning item lands at the far left, which is the hidden side of menu
    /// bar managers like Hidden Bar. The position is saved before hiding and
    /// written back before the item returns.
    private func setItemVisible(_ visible: Bool) {
        guard statusItem.isVisible != visible else { return }
        if visible {
            ItemPosition.restore()
            statusItem.isVisible = true
        } else {
            ItemPosition.remember()
            panel.dismiss()
            statusItem.isVisible = false
        }
    }

    private func updateClock() {
        let needsClock = statusItem.isVisible && store.activeRuns.contains { $0.lastRunAt != nil }
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
            if runs.isEmpty, store.lastUpdated == nil, store.errorMessage == nil {
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
            if store.activeRuns.isEmpty {
                summary = store.lastUpdated == nil ? "Kaggle: checking notebooks" : "Kaggle: nothing running"
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

/// The status item's saved place in the menu bar. AppKit keeps it under
/// "NSStatusItem Preferred Position <autosave name>" and deletes it whenever the
/// item is hidden, so a copy is kept under a key AppKit leaves alone.
enum ItemPosition {
    static let autosaveName = "KernelWatchStatusItem"
    private static let systemKey = "NSStatusItem Preferred Position \(autosaveName)"
    private static let savedKey = "savedStatusItemPosition"

    static func remember() {
        let defaults = UserDefaults.standard
        guard let position = defaults.object(forKey: systemKey) as? Double else { return }
        defaults.set(position, forKey: savedKey)
    }

    static func restore() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: systemKey) == nil,
              let position = defaults.object(forKey: savedKey) as? Double
        else { return }
        defaults.set(position, forKey: systemKey)
    }
}
