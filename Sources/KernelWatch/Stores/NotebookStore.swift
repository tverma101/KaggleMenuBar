import Combine
import Foundation
import OSLog

@MainActor
final class NotebookStore: ObservableObject {
    private let logger = Logger(subsystem: "app.kernelwatch.KernelWatch", category: "Polling")
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
    }

    enum SnapshotState: Equatable {
        case checking, active, idle, failed
    }

    var snapshotState: SnapshotState {
        if errorMessage != nil { return .failed }
        if lastUpdated == nil { return .checking }
        return activeRuns.isEmpty ? .idle : .active
    }

    @Published private(set) var connectionState: ConnectionState
    @Published private(set) var activeRuns: [NotebookRun] = []
    @Published private(set) var notebooksChecked = 0
    @Published private(set) var unavailableCount = 0
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var retryAfter: Date?

    /// Keep setup/checking/errors reachable; a confirmed idle account stays quiet.
    /// Derive this from the snapshot so visibility cannot drift from the run list.
    var isStatusItemVisible: Bool {
        connectionState != .connected
            || lastUpdated == nil
            || errorMessage != nil
            || !activeRuns.isEmpty
    }

    private static let connectedPreference = "hasConnectedToKaggle"
    /// The hub refreshes its newest notebook page once a minute, so a poll at
    /// the same pace shows a new agent run within about a minute.
    static let pollInterval: Duration = .seconds(60)
    private let cli: any KaggleActivityProviding
    private let defaults: UserDefaults
    private let now: () -> Date
    private var pollingTask: Task<Void, Never>?
    private var refreshRequested = false

    private let isDemo: Bool

    init(cli: any KaggleActivityProviding = KaggleCLI(),
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         startPolling: Bool = true) {
        self.cli = cli
        self.defaults = defaults
        self.now = now
        isDemo = false
        let wasConnected = defaults.bool(forKey: Self.connectedPreference)
        connectionState = wasConnected ? .connected : .disconnected
        if wasConnected && startPolling {
            beginPolling()
        }
    }

    var runningCount: Int {
        activeRuns.filter { $0.status == .running }.count
    }

    var queuedCount: Int {
        activeRuns.filter { $0.status == .queued }.count
    }

    /// Fixed sample state for screenshots and layout checks; never calls Kaggle.
    /// Selected with `KERNEL_WATCH_DEMO=<scenario>` at launch.
    init(demo scenario: String) {
        cli = KaggleCLI()
        defaults = .standard
        self.now = Date.init
        isDemo = true
        let now = Date()
        func run(_ slug: String, _ status: NotebookRunStatus, minutesAgo: Double) -> NotebookRun {
            NotebookRun(
                ref: "demo/\(slug)",
                title: slug,
                status: status,
                lastRunAt: now.addingTimeInterval(-minutesAgo * 60)
            )
        }

        connectionState = .connected
        lastUpdated = now
        switch scenario {
        case "disconnected":
            connectionState = .disconnected
            lastUpdated = nil
        case "checking":
            lastUpdated = nil
            isRefreshing = true
        case "queued":
            activeRuns = [run("llm-finetune-qlora", .queued, minutesAgo: 3)]
        case "running":
            activeRuns = [run("llm-finetune-qlora", .running, minutesAgo: 47)]
        case "many":
            activeRuns = [
                run("llm-finetune-qlora", .running, minutesAgo: 134),
                run("vision-transformer-ablation", .running, minutesAgo: 41),
                run("tabular-baseline-lightgbm", .running, minutesAgo: 6),
                run("data-cleaning-pass-2", .queued, minutesAgo: 4),
                run("eval-sweep-seeds", .queued, minutesAgo: 2),
                run("submission-ensemble", .queued, minutesAgo: 1),
                run("audio-features-export", .queued, minutesAgo: 1),
                run("cv-folds-rebuild", .queued, minutesAgo: 0.5),
            ]
        case "error":
            activeRuns = [run("llm-finetune-qlora", .running, minutesAgo: 47)]
            errorMessage = "Kaggle CLI timed out. Will retry in two minutes."
        case "idle":
            activeRuns = []
        case "cycle":
            // Hides and brings back the status item every few seconds, to check
            // that it returns to the place the user dragged it to.
            let busy = [
                run("llm-finetune-qlora", .running, minutesAgo: 47),
                run("eval-sweep-seeds", .queued, minutesAgo: 3),
            ]
            activeRuns = busy
            pollingTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(8))
                    guard let self else { return }
                    self.activeRuns = self.activeRuns.isEmpty ? busy : []
                }
            }
        default:
            activeRuns = [
                run("llm-finetune-qlora", .running, minutesAgo: 47),
                run("vision-transformer-ablation", .running, minutesAgo: 12),
                run("eval-sweep-seeds", .queued, minutesAgo: 3),
            ]
        }
        notebooksChecked = 24
    }

    func connect() {
        guard !isDemo else { return }
        guard connectionState != .connecting else { return }
        connectionState = .connecting
        errorMessage = nil

        Task {
            do {
                try await cli.signIn()
                defaults.set(true, forKey: Self.connectedPreference)
                connectionState = .connected
                beginPolling()
            } catch {
                connectionState = .disconnected
                errorMessage = error.localizedDescription
            }
        }
    }

    func refresh() async {
        guard !isDemo, connectionState == .connected else { return }
        await performRefresh()
    }

    /// `kaggle-hub track` signals this after an agent registers a submission.
    /// Check now instead of waiting for the next poll; a check already in
    /// flight is followed by one more so it cannot miss the new notebook.
    func refreshSoon() {
        guard !isDemo, connectionState == .connected else { return }
        if isRefreshing {
            refreshRequested = true
            return
        }
        pollingTask?.cancel()
        pollingTask = nil
        beginPolling()
    }

    private func beginPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.performRefresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    private func performRefresh() async {
        guard connectionState == .connected, !isRefreshing else { return }
        guard retryAfter.map({ $0 <= now() }) ?? true else { return }
        retryAfter = nil
        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshRequested {
                refreshRequested = false
                refreshSoon()
            }
        }

        do {
            let snapshot = try await cli.activitySnapshot()
            activeRuns = snapshot.activeRuns
            notebooksChecked = snapshot.notebooksChecked
            unavailableCount = snapshot.unavailableCount
            lastUpdated = now()
            errorMessage = nil
            logger.info("Snapshot checked=\(self.notebooksChecked, privacy: .public), running=\(self.runningCount, privacy: .public), queued=\(self.queuedCount, privacy: .public)")
        } catch {
            errorMessage = error.localizedDescription
            if case KaggleCLIError.rateLimited = error {
                retryAfter = now().addingTimeInterval(5 * 60)
            }
            logger.error("Notebook snapshot check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    deinit {
        pollingTask?.cancel()
    }
}
