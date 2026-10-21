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
    /// Consecutive failed checks. The first transient one is retried quietly.
    @Published private(set) var failureStreak = 0
    /// The newest failure, shown or not, for "Copy details".
    @Published private(set) var lastFailure: FailureRecord?
    /// How long the polling loop waits before the next check.
    private(set) var nextPollDelay: Duration = NotebookStore.pollInterval

    struct FailureRecord: Equatable {
        let message: String
        let failure: CommandFailure?
        let date: Date
        let streak: Int
    }

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
    /// Quick retries after the first and second failure in a row. A brief
    /// network drop or Kaggle 5xx then never reaches the panel.
    static let retryDelays: [Duration] = [.seconds(15), .seconds(45)]
    /// A transient failure is shown once it happens this many times in a row.
    static let failuresBeforeShowing = 2
    private let cli: any KaggleActivityProviding
    private let log: DiagnosticLog
    private var loggedSnapshot: (signature: String, date: Date)?
    private let defaults: UserDefaults
    private let now: () -> Date
    private var pollingTask: Task<Void, Never>?
    private var refreshRequested = false

    private let isDemo: Bool

    init(cli: any KaggleActivityProviding = KaggleCLI(),
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         startPolling: Bool = true,
         log: DiagnosticLog = .shared) {
        self.cli = cli
        self.defaults = defaults
        self.now = now
        self.log = log
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
    /// Selected with `KAGGLE_MENUBAR_DEMO=<scenario>` at launch.
    init(demo scenario: String) {
        cli = KaggleCLI()
        log = .shared
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
                log.record("sign_in_failed", ["error": error.localizedDescription])
            }
        }
    }

    func refresh() async {
        guard !isDemo, connectionState == .connected else { return }
        nextPollDelay = await performRefresh()
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
                guard let delay = await self?.pollOnce() else { return }
                try? await Task.sleep(for: delay)
            }
        }
    }

    private func pollOnce() async -> Duration {
        nextPollDelay = await performRefresh()
        return nextPollDelay
    }

    /// Runs one check and returns how long to wait before the next.
    private func performRefresh() async -> Duration {
        guard connectionState == .connected, !isRefreshing else { return Self.pollInterval }
        if let retryAfter, retryAfter > now() {
            return .seconds(max(1, retryAfter.timeIntervalSince(now())))
        }
        retryAfter = nil
        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshRequested {
                refreshRequested = false
                refreshSoon()
            }
        }

        let started = ContinuousClock.now
        do {
            let snapshot = try await cli.activitySnapshot()
            activeRuns = snapshot.activeRuns
            notebooksChecked = snapshot.notebooksChecked
            unavailableCount = snapshot.unavailableCount
            lastUpdated = now()
            errorMessage = nil
            logSnapshot(snapshot, duration: ContinuousClock.now - started, recovering: failureStreak)
            failureStreak = 0
            return Self.pollInterval
        } catch is CancellationError {
            return Self.pollInterval
        } catch {
            return recordFailure(error, duration: ContinuousClock.now - started)
        }
    }

    private func recordFailure(_ error: Error, duration: Duration) -> Duration {
        failureStreak += 1
        let cliError = error as? KaggleCLIError
        let message = error.localizedDescription
        let shown = cliError?.showsImmediately == true || failureStreak >= Self.failuresBeforeShowing
        lastFailure = FailureRecord(message: message, failure: cliError?.failure, date: now(), streak: failureStreak)
        // Until then the last good snapshot stands and the check repeats soon.
        if shown { errorMessage = message }

        var delay = failureStreak <= Self.retryDelays.count ? Self.retryDelays[failureStreak - 1] : Self.pollInterval
        if case let .rateLimited(wait) = cliError {
            retryAfter = now().addingTimeInterval(wait)
            delay = .seconds(wait)
        }
        log.record("check_failed", [
            "error": message,
            "kind": cliError?.failure?.kind.rawValue ?? (cliError.map { "\($0)" } ?? String(describing: type(of: error))),
            "streak": failureStreak,
            "shown": shown,
            "seconds": duration.seconds,
            "retry_in": delay.seconds,
        ])
        logger.error("Notebook check failed (\(self.failureStreak, privacy: .public) in a row): \(message, privacy: .public)")
        return delay
    }

    /// A line per change rather than per poll, plus one every half hour, so
    /// the log reaches back days instead of hours.
    private func logSnapshot(_ snapshot: ActivitySnapshot, duration: Duration, recovering streak: Int) {
        let runs = snapshot.activeRuns.map { "\($0.status.rawValue) \($0.ref)" }
        let signature = ([snapshot.source.rawValue, "\(snapshot.unavailableCount)"] + runs).joined(separator: "|")
        let date = now()
        if streak == 0, let last = loggedSnapshot, last.signature == signature,
           date.timeIntervalSince(last.date) < 30 * 60 {
            return
        }
        loggedSnapshot = (signature, date)
        var fields: [String: any Sendable] = [
            "source": snapshot.source.rawValue,
            "checked": snapshot.notebooksChecked,
            "unavailable": snapshot.unavailableCount,
            "runs": Array(runs.prefix(12)),
            "seconds": duration.seconds,
        ]
        if streak > 0 { fields["recovered_after"] = streak }
        log.record("snapshot", fields)
        logger.info("Snapshot checked=\(snapshot.notebooksChecked, privacy: .public), running=\(self.runningCount, privacy: .public), queued=\(self.queuedCount, privacy: .public)")
    }

    deinit {
        pollingTask?.cancel()
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
