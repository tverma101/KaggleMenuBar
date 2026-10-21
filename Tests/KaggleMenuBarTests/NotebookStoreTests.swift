import Foundation
import XCTest
@testable import KaggleMenuBar

private actor ScriptedKaggle: KaggleActivityProviding {
    enum Reply: Sendable {
        case snapshot(ActivitySnapshot)
        /// A failure the store retries once before showing.
        case failure
        /// A failure retrying cannot fix, shown at once.
        case missingCLI
        case rateLimited
    }

    enum TestError: Error { case unavailable }
    private var replies: [Reply]
    private(set) var requests = 0

    init(_ replies: [Reply]) { self.replies = replies }
    func signIn() async throws {}

    func activitySnapshot() async throws -> ActivitySnapshot {
        requests += 1
        guard !replies.isEmpty else { throw TestError.unavailable }
        switch replies.removeFirst() {
        case .snapshot(let snapshot): return snapshot
        case .failure: throw TestError.unavailable
        case .missingCLI: throw KaggleCLIError.missingCLI
        case .rateLimited: throw KaggleCLIError.rateLimited(retryAfter: 300)
        }
    }
}

/// Holds the first snapshot open until released, like a slow hub check.
private actor HeldKaggle: KaggleActivityProviding {
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var requests = 0
    var isHolding: Bool { gate != nil }

    func signIn() async throws {}

    func activitySnapshot() async throws -> ActivitySnapshot {
        requests += 1
        if requests == 1 { await withCheckedContinuation { gate = $0 } }
        return ActivitySnapshot(activeRuns: [], notebooksChecked: 1)
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

@MainActor
final class NotebookStoreTests: XCTestCase {
    /// One fixed suite: removing a domain leaves its empty plist behind, so a
    /// fresh name per test would add a file to ~/Library/Preferences every run.
    private static let suite = "KaggleMenuBarTests"
    private let log = DiagnosticLog(directory: FileManager.default.temporaryDirectory
        .appending(path: "KaggleMenuBarStoreTests-\(UUID().uuidString)"))

    override func tearDown() {
        log.flush()
        try? FileManager.default.removeItem(at: log.fileURL.deletingLastPathComponent())
    }

    private func testDefaults(connected: Bool) -> UserDefaults {
        let defaults = UserDefaults(suiteName: Self.suite)!
        defaults.removePersistentDomain(forName: Self.suite)
        defaults.set(connected, forKey: "hasConnectedToKaggle")
        return defaults
    }

    private func withStore(_ replies: [ScriptedKaggle.Reply], connected: Bool = true,
                           now: @escaping () -> Date = Date.init,
                           body: (NotebookStore, ScriptedKaggle) async -> Void) async {
        let defaults = testDefaults(connected: connected)
        defer { defaults.removePersistentDomain(forName: Self.suite) }
        let cli = ScriptedKaggle(replies)
        let store = NotebookStore(cli: cli, defaults: defaults, now: now, startPolling: false, log: log)
        await body(store, cli)
    }

    private var idle: ActivitySnapshot { ActivitySnapshot(activeRuns: [], notebooksChecked: 24) }

    func testFirstSuccessfulIdleCheckHidesItem() async {
        await withStore([.snapshot(idle)]) { store, _ in
            XCTAssertTrue(store.isStatusItemVisible, "The first check must remain reachable")
            await store.refresh()
            XCTAssertNotNil(store.lastUpdated)
            XCTAssertTrue(store.activeRuns.isEmpty)
            XCTAssertFalse(store.isStatusItemVisible)
            XCTAssertFalse(store.isRefreshing)
        }
    }

    func testQueuedAndRunningNotebooksRestoreItemAndCompletionHidesIt() async {
        let queued = NotebookRun(ref: "demo/queued", title: "Queued", status: .queued)
        let running = NotebookRun(ref: "demo/running", title: "Running", status: .running)
        await withStore([
            .snapshot(idle),
            .snapshot(ActivitySnapshot(activeRuns: [queued], notebooksChecked: 24)),
            .snapshot(ActivitySnapshot(activeRuns: [running], notebooksChecked: 24)),
            .snapshot(idle)
        ]) { store, _ in
            await store.refresh()
            XCTAssertFalse(store.isStatusItemVisible)
            await store.refresh()
            XCTAssertTrue(store.isStatusItemVisible)
            XCTAssertEqual(store.queuedCount, 1)
            await store.refresh()
            XCTAssertTrue(store.isStatusItemVisible)
            XCTAssertEqual(store.runningCount, 1)
            await store.refresh()
            XCTAssertFalse(store.isStatusItemVisible)
        }
    }

    func testRepeatedFailureIsVisibleAndSuccessfulIdleRetryHidesIt() async {
        await withStore([.snapshot(idle), .failure, .failure, .snapshot(idle)]) { store, _ in
            await store.refresh()
            XCTAssertFalse(store.isStatusItemVisible)
            await store.refresh()
            XCTAssertNil(store.errorMessage, "One transient failure is retried before it is shown")
            XCTAssertEqual(store.failureStreak, 1)
            XCTAssertEqual(store.nextPollDelay, .seconds(15))
            await store.refresh()
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(store.nextPollDelay, .seconds(45))
            XCTAssertTrue(store.isStatusItemVisible, "An error is not confirmation that no jobs exist")
            await store.refresh()
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(store.failureStreak, 0)
            XCTAssertEqual(store.nextPollDelay, NotebookStore.pollInterval)
            XCTAssertFalse(store.isStatusItemVisible)
        }
    }

    func testOneTransientFailureKeepsTheLastGoodRuns() async {
        let running = NotebookRun(ref: "demo/running", title: "Running", status: .running)
        await withStore([.snapshot(ActivitySnapshot(activeRuns: [running], notebooksChecked: 24)), .failure]) { store, _ in
            await store.refresh()
            await store.refresh()
            XCTAssertEqual(store.activeRuns, [running])
            XCTAssertNil(store.errorMessage)
            XCTAssertNotNil(store.lastFailure, "Copy details still has the failure")
            XCTAssertTrue(store.isStatusItemVisible)
        }
    }

    func testSetupFailureIsShownAtOnce() async {
        await withStore([.missingCLI]) { store, _ in
            await store.refresh()
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(store.snapshotState, .failed)
            XCTAssertTrue(store.isStatusItemVisible)
        }
    }

    func testFirstCheckFailureStopsCheckingPresentationAndCanRecover() async {
        await withStore([.failure, .failure, .snapshot(idle)]) { store, _ in
            XCTAssertEqual(store.snapshotState, .checking)
            await store.refresh()
            XCTAssertEqual(store.snapshotState, .checking, "Still checking during the quick retry")
            XCTAssertFalse(store.isRefreshing)
            await store.refresh()
            XCTAssertNil(store.lastUpdated)
            XCTAssertNotNil(store.errorMessage)
            XCTAssertFalse(store.isRefreshing)
            XCTAssertEqual(store.snapshotState, .failed)
            XCTAssertTrue(store.isStatusItemVisible)
            await store.refresh()
            XCTAssertEqual(store.snapshotState, .idle)
            XCTAssertFalse(store.isStatusItemVisible)
        }
    }

    func testRateLimitBlocksManualRefreshUntilCooldownThenRecovers() async {
        var clock = Date(timeIntervalSince1970: 1_000)
        await withStore([.rateLimited, .snapshot(idle)], now: { clock }) { store, cli in
            await store.refresh()
            XCTAssertEqual(store.retryAfter, clock.addingTimeInterval(300))
            XCTAssertEqual(store.snapshotState, .failed, "A rate limit is shown at once with its wait")
            XCTAssertEqual(store.nextPollDelay, .seconds(300))
            await store.refresh()
            let blockedRequests = await cli.requests
            XCTAssertEqual(blockedRequests, 1)

            clock = clock.addingTimeInterval(301)
            await store.refresh()
            let resumedRequests = await cli.requests
            XCTAssertEqual(resumedRequests, 2)
            XCTAssertNil(store.retryAfter)
            XCTAssertNil(store.errorMessage)
            XCTAssertFalse(store.isStatusItemVisible)
        }
    }

    func testDisconnectedSetupRemainsReachableWithoutCallingKaggle() async {
        await withStore([], connected: false) { store, cli in
            await store.refresh()
            let requests = await cli.requests
            XCTAssertEqual(requests, 0)
            XCTAssertEqual(store.connectionState, .disconnected)
            XCTAssertTrue(store.isStatusItemVisible)
        }
    }

    func testTrackSignalDuringACheckRunsOneMoreCheck() async throws {
        let defaults = testDefaults(connected: true)
        defer { defaults.removePersistentDomain(forName: Self.suite) }
        let cli = HeldKaggle()
        let store = NotebookStore(cli: cli, defaults: defaults, startPolling: false, log: log)

        let first = Task { await store.refresh() }
        while !(await cli.isHolding) { await Task.yield() }
        store.refreshSoon()
        await cli.release()
        await first.value

        let deadline = Date().addingTimeInterval(5)
        while await cli.requests < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let requests = await cli.requests
        XCTAssertEqual(requests, 2, "A notebook tracked mid-check must get its own snapshot")
    }

    func testTrackSignalIsIgnoredBeforeConnecting() async throws {
        await withStore([], connected: false) { store, cli in
            store.refreshSoon()
            try? await Task.sleep(for: .milliseconds(50))
            let requests = await cli.requests
            XCTAssertEqual(requests, 0)
        }
    }

    func testIdleDemoUsesTheSameVisibilityRuleAsLiveSnapshots() {
        XCTAssertFalse(NotebookStore(demo: "idle").isStatusItemVisible)
        for scenario in ["queued", "running", "checking", "error", "disconnected"] {
            XCTAssertTrue(NotebookStore(demo: scenario).isStatusItemVisible, scenario)
        }
    }
}
