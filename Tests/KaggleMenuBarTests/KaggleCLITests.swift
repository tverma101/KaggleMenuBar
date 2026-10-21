import Foundation
import XCTest
@testable import KaggleMenuBar

/// Answers Kaggle CLI and kaggle-hub calls from canned output.
private actor FixtureCommands {
    var list: String
    var statuses: [String: String] = [:]
    var failures: [String: ProcessResult] = [:]
    var hubResult = ProcessResult(exitCode: 0, stdout: #"{"activeRuns":[],"notebooksChecked":0}"#, stderr: "")
    private(set) var statusReferences: [String] = []
    private(set) var tools: [KaggleCLI.Tool] = []

    init(list: String) { self.list = list }

    func setList(_ list: String) { self.list = list }
    func setStatus(_ status: String, for ref: String) { statuses[ref] = status }
    func setFailure(_ result: ProcessResult, for ref: String) { failures[ref] = result }
    func setHubResult(_ result: ProcessResult) { hubResult = result }

    func run(_ tool: KaggleCLI.Tool, _ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        tools.append(tool)
        if case .hub = tool { return hubResult }
        if arguments.starts(with: ["kernels", "list"]) { return ProcessResult(exitCode: 0, stdout: list, stderr: "") }
        guard arguments.count == 3, arguments.starts(with: ["kernels", "status"]),
              !arguments[2].isEmpty else {
            throw NSError(domain: "FixtureCommands", code: 1)
        }
        let ref = arguments[2]
        statusReferences.append(ref)
        if let failure = failures[ref] { return failure }
        let status = statuses[ref] ?? "COMPLETE"
        return ProcessResult(exitCode: 0, stdout: "\(ref) has status \"KernelWorkerStatus.\(status)\"\n", stderr: "")
    }
}

/// Kaggle's `lastRunTime` format for a moment `hours` ago.
private func listed(hoursAgo hours: Double, from now: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
    return formatter.string(from: now.addingTimeInterval(-hours * 3600))
}

private func listJSON(_ rows: [(ref: String, hoursAgo: Double?)]) -> String {
    let items = rows.map { row in
        let time = row.hoursAgo.map { #","lastRunTime":"\#(listed(hoursAgo: $0))""# } ?? ""
        return #"{"ref":"\#(row.ref)","title":"\#(row.ref)"\#(time)}"#
    }
    return "[" + items.joined(separator: ",") + "]"
}

final class KaggleCLITests: XCTestCase {
    private var logDirectory: URL!
    private var log: DiagnosticLog!

    override func setUp() {
        logDirectory = FileManager.default.temporaryDirectory.appending(path: "KaggleMenuBarTests-\(UUID().uuidString)")
        log = DiagnosticLog(directory: logDirectory)
    }

    override func tearDown() {
        log.flush()
        try? FileManager.default.removeItem(at: logDirectory)
    }

    private func directCLI(_ fixture: FixtureCommands, now: @escaping @Sendable () -> Date = { Date() }) -> KaggleCLI {
        KaggleCLI(source: .direct, command: { tool, args, timeout in try await fixture.run(tool, args, timeout: timeout) },
                  pause: {}, locateHub: { nil }, now: now, log: log)
    }

    // MARK: - Hub mode

    func testSharedHubSnapshotPreservesProjectStatusAndUnavailableCount() throws {
        let snapshot = try KaggleCLI.decodeHubSnapshot(#"""
        {"activeRuns":[{"ref":"demo/run","title":"Training","status":"QUEUED",
          "lastRunAt":"2026-10-19T12:00:00.000000","project":"MathNotes"}],
         "notebooksChecked":98,"unavailableCount":1,"checkedAt":1792450000}
        """#)
        XCTAssertEqual(snapshot.notebooksChecked, 98)
        XCTAssertEqual(snapshot.unavailableCount, 1)
        XCTAssertEqual(snapshot.activeRuns.first?.project, "MathNotes")
        XCTAssertEqual(snapshot.activeRuns.first?.status, .queued)
        XCTAssertNotNil(snapshot.activeRuns.first?.lastRunAt)
        XCTAssertEqual(snapshot.source, .hub)
    }

    /// The bug behind "random" errors: the hub cut a traceback after its first
    /// 1500 characters and the app showed the last line, a stack frame path.
    func testTruncatedHubTracebackIsNotShownAsAFilePath() async throws {
        let fixture = FixtureCommands(list: "[]")
        await fixture.setHubResult(ProcessResult(exitCode: 2, stdout: "", stderr: """
            kaggle-hub: Traceback (most recent call last):
              File "\(NSHomeDirectory())/.local/share/uv/tools/kaggle/lib/python3.14/site-packages/requests/adapters.py", line 667, in send
                resp = conn.urlopen(
              File "\(NSHomeDirectory())/.local/share/uv/tools/kaggle/lib/python3.14/site-
            """))
        let hub = URL(fileURLWithPath: "/usr/local/bin/kaggle-hub")
        let cli = KaggleCLI(source: .hub, command: { tool, args, timeout in try await fixture.run(tool, args, timeout: timeout) },
                            pause: {}, locateHub: { hub }, log: log)
        do {
            _ = try await cli.activitySnapshot()
            XCTFail("A failed hub check is not a snapshot")
        } catch let error as KaggleCLIError {
            let message = try XCTUnwrap(error.errorDescription)
            XCTAssertFalse(message.contains("File \""), message)
            XCTAssertTrue(message.contains("crashed without an error message"), message)
            XCTAssertFalse(error.showsImmediately, "A crash is retried once before it is shown")
        }

        log.flush()
        let entry = try XCTUnwrap(log.recentEntries(limit: 5).last)
        XCTAssertTrue(entry.contains(#""event":"command_failed""#), entry)
        XCTAssertTrue(entry.contains("kaggle-hub monitor-snapshot"), entry)
        XCTAssertTrue(entry.contains("~/.local/share/uv"), "The full tail is logged with the home folder shortened")
    }

    func testHubRateLimitCarriesTheHubsWait() async {
        let fixture = FixtureCommands(list: "[]")
        await fixture.setHubResult(ProcessResult(exitCode: 2, stdout: "",
            stderr: "kaggle-hub: Kaggle rate limit: retry in 120 seconds. Cached notebook results remain available.\n"))
        let cli = KaggleCLI(source: .automatic, command: { tool, args, timeout in try await fixture.run(tool, args, timeout: timeout) },
                            pause: {}, locateHub: { URL(fileURLWithPath: "/tmp/kaggle-hub") }, log: log)
        do {
            _ = try await cli.activitySnapshot()
            XCTFail("Rate limits are failures")
        } catch KaggleCLIError.rateLimited(let wait) {
            XCTAssertEqual(wait, 120)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testAutomaticSourceWithoutHubPollsTheCLIDirectly() async throws {
        let fixture = FixtureCommands(list: listJSON([("demo/running", 1)]))
        await fixture.setStatus("RUNNING", for: "demo/running")
        let cli = KaggleCLI(source: .automatic, command: { tool, args, timeout in try await fixture.run(tool, args, timeout: timeout) },
                            pause: {}, locateHub: { nil }, log: log)
        let snapshot = try await cli.activitySnapshot()
        XCTAssertEqual(snapshot.source, .direct)
        XCTAssertEqual(snapshot.activeRuns.map(\.ref), ["demo/running"])
        let tools = await fixture.tools
        XCTAssertTrue(tools.allSatisfy { $0 == .kaggle })
    }

    func testForcedHubSourceWithoutHubIsASetupError() async {
        let cli = KaggleCLI(source: .hub, command: { _, _, _ in XCTFail("No command should run"); throw CancellationError() },
                            pause: {}, locateHub: { nil }, log: log)
        do {
            _ = try await cli.activitySnapshot()
            XCTFail("A missing hub is not idle")
        } catch let error as KaggleCLIError {
            XCTAssertTrue(error.showsImmediately)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    // MARK: - Direct mode

    func testUnqueryableRowsDoNotAbortOtherNotebookStatusChecks() async throws {
        let recent = listed(hoursAgo: 1)
        let fixture = FixtureCommands(list: #"""
        [
          {"ref":"", "title":"Unqueryable row", "lastRunTime":"\#(recent)"},
          {"ref":null, "title":"Null ref"},
          {"title":"Missing ref"},
          {"ref":"   "},
          {"ref":"not-a-reference"},
          {"ref":"demo/running", "title":"Running", "lastRunTime":"\#(recent)"},
          {"ref":" demo/finished ", "title":"Finished", "lastRunTime":"\#(recent)"}
        ]
        """#)
        await fixture.setStatus("RUNNING", for: "demo/running")
        let snapshot = try await directCLI(fixture).activitySnapshot()
        let references = await fixture.statusReferences
        XCTAssertEqual(Set(references), ["demo/running", "demo/finished"])
        XCTAssertEqual(references.count, 2)
        XCTAssertEqual(snapshot.notebooksChecked, 2)
        XCTAssertEqual(snapshot.activeRuns.map(\.ref), ["demo/running"])
    }

    func testOnlyUnqueryableRowsFailRatherThanReportIdle() async {
        let fixture = FixtureCommands(list: #"[{"ref":"", "title":"Unqueryable row"}]"#)
        do {
            _ = try await directCLI(fixture).activitySnapshot()
            XCTFail("An unreadable list is not a confirmed idle account")
        } catch {
            let references = await fixture.statusReferences
            XCTAssertTrue(references.isEmpty)
        }
    }

    func testFinishedNotebooksAreNotRecheckedAndAChangedRunTimeIs() async throws {
        let fixture = FixtureCommands(list: listJSON([("demo/finished", 3), ("demo/running", 1)]))
        await fixture.setStatus("RUNNING", for: "demo/running")
        let cli = directCLI(fixture)
        _ = try await cli.activitySnapshot()
        _ = try await cli.activitySnapshot()
        let references = await fixture.statusReferences
        XCTAssertEqual(references.filter { $0 == "demo/finished" }.count, 1)
        XCTAssertEqual(references.filter { $0 == "demo/running" }.count, 2, "Active notebooks are checked every poll")

        await fixture.setList(listJSON([("demo/finished", 0.1)]))
        await fixture.setStatus("QUEUED", for: "demo/finished")
        let snapshot = try await cli.activitySnapshot()
        XCTAssertEqual(snapshot.activeRuns.map(\.status), [.queued])
    }

    func testOldNotebooksCostNoStatusRequestsButNewlyListedOnesDo() async throws {
        let fixture = FixtureCommands(list: listJSON([("demo/last-week", 170), ("demo/no-runs", nil)]))
        let cli = directCLI(fixture)
        _ = try await cli.activitySnapshot()
        var references = await fixture.statusReferences
        XCTAssertEqual(references, [])

        await fixture.setList(listJSON([("demo/brand-new", nil), ("demo/last-week", 170), ("demo/no-runs", nil)]))
        await fixture.setStatus("QUEUED", for: "demo/brand-new")
        _ = try await cli.activitySnapshot()
        references = await fixture.statusReferences
        XCTAssertEqual(references, ["demo/brand-new"])
    }

    func testRecentNotebooksAreRecheckedForRepushesEveryFewMinutes() async throws {
        let clock = TestClock()
        let fixture = FixtureCommands(list: listJSON([("demo/yesterday", 20)]))
        let cli = directCLI(fixture, now: { clock.now })
        _ = try await cli.activitySnapshot()
        _ = try await cli.activitySnapshot()
        var references = await fixture.statusReferences
        XCTAssertEqual(references.count, 1, "Not again within two minutes")

        clock.advance(by: 121)
        // Re-pushed: Kaggle still lists the old run time.
        await fixture.setStatus("RUNNING", for: "demo/yesterday")
        let snapshot = try await cli.activitySnapshot()
        references = await fixture.statusReferences
        XCTAssertEqual(references.count, 2)
        XCTAssertEqual(snapshot.activeRuns.map(\.status), [.running])
        XCTAssertEqual(snapshot.activeRuns.first?.lastRunAt, clock.now,
                       "A run time 20 hours old belongs to an earlier run; time it from when it was seen active")
    }

    func testJustPushedNotebookIsQueuedAndOldDraftIsIgnored() async throws {
        let fixture = FixtureCommands(list: listJSON([("demo/pushed", 0.03), ("demo/draft", 5)]))
        await fixture.setStatus("NEW_SCRIPT", for: "demo/pushed")
        await fixture.setStatus("NEW_SCRIPT", for: "demo/draft")
        let snapshot = try await directCLI(fixture).activitySnapshot()
        XCTAssertEqual(snapshot.activeRuns.map(\.ref), ["demo/pushed"])
        XCTAssertEqual(snapshot.activeRuns.map(\.status), [.queued])
    }

    func testUnknownStatusIsNotCachedAsFinishedOrReportedIdle() async {
        let fixture = FixtureCommands(list: listJSON([("demo/new-state", 1)]))
        await fixture.setStatus("UNKNOWN_NEW_STATE", for: "demo/new-state")
        let cli = directCLI(fixture)
        do {
            _ = try await cli.activitySnapshot()
            XCTFail("Unknown states cannot safely mean idle")
        } catch {}
        await fixture.setStatus("RUNNING", for: "demo/new-state")
        do {
            let snapshot = try await cli.activitySnapshot()
            XCTAssertEqual(snapshot.activeRuns.count, 1)
        } catch { XCTFail("Unknown state must remain retryable") }
    }

    func testInaccessibleNotebookIsCountedWithoutFailingTheOthers() async throws {
        let fixture = FixtureCommands(list: listJSON([("demo/deleted", 2), ("demo/running", 1)]))
        await fixture.setFailure(ProcessResult(exitCode: 1, stdout: "",
            stderr: "404 Client Error: Not Found for url: https://api.kaggle.com/v1/kernels.KernelsApiService/GetKernelSessionStatus\n"),
            for: "demo/deleted")
        await fixture.setStatus("RUNNING", for: "demo/running")
        let snapshot = try await directCLI(fixture).activitySnapshot()
        XCTAssertEqual(snapshot.unavailableCount, 1)
        XCTAssertEqual(snapshot.activeRuns.map(\.ref), ["demo/running"])
    }

    func testRunStartPrefersListedTimeUnlessItBelongsToAnEarlierRun() {
        let now = Date()
        let listed = now.addingTimeInterval(-3 * 3600)
        XCTAssertEqual(DirectModeState.runStart(listed: listed, activeSince: now), listed)
        let stale = now.addingTimeInterval(-30 * 3600)
        XCTAssertEqual(DirectModeState.runStart(listed: stale, activeSince: now), now)
        XCTAssertEqual(DirectModeState.runStart(listed: nil, activeSince: now), now)
        XCTAssertNil(DirectModeState.runStart(listed: nil, activeSince: nil))
    }
}

final class CommandFailureTests: XCTestCase {
    private func failure(stdout: String = "", stderr: String, exit: Int32 = 1, timedOut: Bool = false) -> CommandFailure {
        CommandFailure(result: ProcessResult(exitCode: exit, stdout: stdout, stderr: stderr, timedOut: timedOut),
                       command: "kaggle kernels list", timeout: 60)
    }

    func testFullTracebackIsSummarizedFromItsExceptionLine() {
        let result = failure(stderr: """
            Traceback (most recent call last):
              File "/opt/kaggle/lib/python3.14/site-packages/urllib3/connectionpool.py", line 787, in urlopen
                response = self._make_request(
                           ^^^^^^^^^^^^^^^^^^^
            urllib3.exceptions.NameResolutionError: Failed to resolve 'api.kaggle.com'

            During handling of the above exception, another exception occurred:

            Traceback (most recent call last):
              File "/opt/kaggle/bin/kaggle", line 10, in <module>
                sys.exit(main())
            requests.exceptions.ConnectionError: HTTPSConnectionPool(host='api.kaggle.com', port=443): Max retries exceeded
            """)
        XCTAssertEqual(result.kind, .transient)
        XCTAssertEqual(result.summary, "Can't reach Kaggle right now. Retrying.")
        XCTAssertEqual(result.cause, "requests.exceptions.ConnectionError: HTTPSConnectionPool(host='api.kaggle.com', port=443): Max retries exceeded")
        XCTAssertFalse(result.showsImmediately)
    }

    func testCredentialErrorsShowAtOnce() {
        let result = failure(stderr: "401 Client Error: Unauthorized for url: https://api.kaggle.com/v1/kernels.KernelsApiService/ListKernels\n")
        XCTAssertEqual(result.kind, .auth)
        XCTAssertTrue(result.showsImmediately)
        XCTAssertTrue(result.summary.contains("kaggle auth login"))
    }

    func testServerErrorNamesTheStatusCode() {
        let result = failure(stderr: "requests.exceptions.HTTPError: 503 Server Error: Service Unavailable for url: https://api.kaggle.com\n")
        XCTAssertEqual(result.kind, .transient)
        XCTAssertEqual(result.summary, "Kaggle's API returned an error (HTTP 503). Retrying.")
    }

    func testLineNumbersInTracebacksAreNotMistakenForStatusCodes() {
        let result = failure(stderr: """
            Traceback (most recent call last):
              File "/opt/kaggle/cli.py", line 503, in main
            ValueError: Unsupported format option json(ref)
            """)
        XCTAssertEqual(result.kind, .unknown)
        XCTAssertEqual(result.summary, "ValueError: Unsupported format option json(ref)")
    }

    func testTimeoutSaysHowLongItWaited() {
        let result = failure(stderr: "", exit: -15, timedOut: true)
        XCTAssertEqual(result.kind, .transient)
        XCTAssertEqual(result.summary, "kaggle kernels list did not finish within 60 seconds. Retrying.")
    }

    func testOldCLIWithoutTheSubcommandIsASetupError() {
        let result = failure(stderr: "usage: kaggle [-h] [-v] {competitions,c,datasets,d}\nkaggle: error: argument command: invalid choice: 'auth'\n", exit: 2)
        XCTAssertEqual(result.kind, .setup)
        XCTAssertTrue(result.showsImmediately)
        XCTAssertEqual(result.summary, "kaggle: error: argument command: invalid choice: 'auth'")
    }

    func testEmptyOutputReportsTheExitStatus() {
        let result = failure(stderr: "", exit: 7)
        XCTAssertEqual(result.summary, "The Kaggle command failed with exit status 7 and no output.")
    }

    func testDetailsAreRedacted() {
        let result = failure(stderr: "Authorization: Bearer abc.def-123 failed; KGAT_0123456789abcdef rejected\n{\"username\":\"me\",\"key\":\"0123abcd\"}\n")
        XCTAssertFalse(result.detail.contains("abc.def-123"))
        XCTAssertFalse(result.detail.contains("KGAT_0123"))
        XCTAssertFalse(result.detail.contains("0123abcd"))
        XCTAssertTrue(result.detail.contains("[redacted]"))
    }
}

final class ProcessRunnerTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    func testStdoutAndStderrAreKeptApart() async throws {
        let result = try await ProcessRunner.run(shell, arguments: ["-c", "echo out; echo err >&2; exit 3"], timeout: 10)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stdout, "out\n")
        XCTAssertEqual(result.stderr, "err\n")
        XCTAssertFalse(result.timedOut)
    }

    func testLargeOutputOnBothPipesDoesNotDeadlock() async throws {
        let script = #"head -c 300000 /dev/zero | tr '\0' a; head -c 300000 /dev/zero | tr '\0' b >&2"#
        let result = try await ProcessRunner.run(shell, arguments: ["-c", script], timeout: 20)
        XCTAssertEqual(result.stdout.count, 300_000)
        XCTAssertEqual(result.stderr.count, 300_000)
    }

    func testTimeoutStopsTheCommand() async throws {
        let started = Date()
        let result = try await ProcessRunner.run(shell, arguments: ["-c", "exec sleep 20"], timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testCommandIgnoringSIGTERMIsKilled() async throws {
        let started = Date()
        let result = try await ProcessRunner.run(shell, arguments: ["-c", "trap '' TERM; while :; do sleep 0.2; done"], timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5 + ProcessRunner.killGrace + ProcessRunner.drainLimit + 2)
    }

    func testGrandchildHoldingThePipeDoesNotHoldTheCheck() async throws {
        let started = Date()
        let result = try await ProcessRunner.run(shell, arguments: ["-c", "(sleep 6 &); echo done"], timeout: 30)
        XCTAssertEqual(result.stdout, "done\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), ProcessRunner.drainLimit + 2)
    }

    func testCancellationStopsTheCommand() async throws {
        let started = Date()
        let shell = shell
        let task = Task { try await ProcessRunner.run(shell, arguments: ["-c", "exec sleep 20"], timeout: 30) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled check does not return output")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}

final class DiagnosticLogTests: XCTestCase {
    func testEntriesAreRedactedAndRotateIntoOneBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "KaggleMenuBarLog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory, maxBytes: 2_000)
        for index in 0..<120 {
            log.record("snapshot", ["index": index])
        }
        log.record("command_failed", ["stderr_tail": "token=abc123 \(NSHomeDirectory())/x", "exit": 1])
        log.flush()

        let entries = log.recentEntries(limit: 500)
        XCTAssertEqual(entries.last.map { $0.contains(#""event":"command_failed""#) }, true)
        XCTAssertEqual(entries.dropLast().last.map { $0.contains(#""index":119"#) }, true)
        XCTAssertLessThan(entries.count, 121, "Entries older than the backup are dropped")
        let current = try Data(contentsOf: log.fileURL)
        XCTAssertLessThanOrEqual(current.count, 2_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "diagnostics.1.jsonl").path))
        let all = entries.joined(separator: "\n")
        XCTAssertFalse(all.contains("abc123"))
        XCTAssertFalse(all.contains(NSHomeDirectory()))
    }
}

/// A clock tests move by hand.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()
    var now: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
}
