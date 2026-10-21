import Foundation

protocol KaggleActivityProviding: Sendable {
    func signIn() async throws
    func activitySnapshot() async throws -> ActivitySnapshot
}

/// Where snapshots come from. `automatic` uses kaggle-hub when one is
/// installed, so the app shares its cache and request budget with your own
/// scripts, and otherwise polls the Kaggle CLI itself.
enum ActivitySource: String, Sendable, CaseIterable {
    case automatic = "auto"
    case hub
    case direct

    static let preferenceKey = "activitySource"

    /// `defaults write app.kernelwatch.KernelWatch activitySource direct`, or
    /// `KAGGLE_MENUBAR_SOURCE=direct` for a single launch.
    static func configured(defaults: UserDefaults = .standard,
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> ActivitySource {
        let raw = environment["KAGGLE_MENUBAR_SOURCE"] ?? defaults.string(forKey: preferenceKey)
        return raw.flatMap(ActivitySource.init(rawValue:)) ?? .automatic
    }

    /// `KAGGLE_HUB_PATH`, then the usual install locations.
    static func installedHub(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [environment["KAGGLE_HUB_PATH"], "\(home)/.local/bin/kaggle-hub", "/opt/homebrew/bin/kaggle-hub"]
        return candidates.compactMap { $0 }
            .first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}

struct KaggleCLI: KaggleActivityProviding {
    /// The executable a command runs.
    enum Tool: Sendable, Equatable {
        case kaggle
        case hub(URL)
    }

    typealias Command = @Sendable (_ tool: Tool, _ arguments: [String], _ timeout: TimeInterval) async throws -> ProcessResult
    typealias Pause = @Sendable () async throws -> Void

    static let notebookLimit = 100
    /// The hub may wait for another process's turn at the request budget.
    static let hubTimeout: TimeInterval = 900

    private let source: ActivitySource
    private let command: Command?
    private let pause: Pause
    private let locateHub: @Sendable () -> URL?
    private let now: @Sendable () -> Date
    private let log: DiagnosticLog
    private let direct = DirectModeState()

    /// - Parameters:
    ///   - command: Replaces running real executables, for tests.
    ///   - pause: Spacing between direct-mode status requests.
    init(source: ActivitySource = .configured(),
         command: Command? = nil,
         pause: @escaping Pause = { try await Task.sleep(for: .seconds(2)) },
         locateHub: @escaping @Sendable () -> URL? = { ActivitySource.installedHub() },
         now: @escaping @Sendable () -> Date = { Date() },
         log: DiagnosticLog = .shared) {
        self.source = source
        self.command = command
        self.pause = pause
        self.locateHub = locateHub
        self.now = now
        self.log = log
    }

    func signIn() async throws {
        let result: ProcessResult
        do {
            result = try await execute(.kaggle, ["auth", "login"], timeout: 300)
        } catch let error as KaggleCLIError {
            throw error
        } catch {
            throw KaggleCLIError.signInFailed
        }
        guard result.succeeded else {
            _ = failure(result, tool: .kaggle, arguments: ["auth", "login"], timeout: 300)
            throw KaggleCLIError.signInFailed
        }
    }

    func activitySnapshot() async throws -> ActivitySnapshot {
        switch source {
        case .hub:
            guard let hub = locateHub() else { throw KaggleCLIError.missingHub }
            return try await hubSnapshot(hub)
        case .direct:
            return try await directSnapshot()
        case .automatic:
            if let hub = locateHub() { return try await hubSnapshot(hub) }
            return try await directSnapshot()
        }
    }

    // MARK: - Hub mode

    private func hubSnapshot(_ hub: URL) async throws -> ActivitySnapshot {
        let arguments = ["monitor-snapshot"]
        let result = try await execute(.hub(hub), arguments, timeout: Self.hubTimeout)
        guard result.succeeded else {
            throw failure(result, tool: .hub(hub), arguments: arguments, timeout: Self.hubTimeout)
        }
        do {
            return try Self.decodeHubSnapshot(result.stdout)
        } catch {
            log.record("hub_output_unreadable", [
                "stdout_tail": String(result.stdout.suffix(4000)),
                "stderr_tail": String(result.stderr.suffix(4000)),
            ])
            throw KaggleCLIError.unreadableHubSnapshot
        }
    }

    static func decodeHubSnapshot(_ output: String) throws -> ActivitySnapshot {
        struct SharedSnapshot: Decodable {
            struct Run: Decodable {
                let ref: String
                let title: String
                let status: NotebookRunStatus
                let lastRunAt: String?
                let project: String?
            }
            let activeRuns: [Run]
            let notebooksChecked: Int
            let unavailableCount: Int?
        }
        let snapshot = try JSONDecoder().decode(SharedSnapshot.self, from: Data(output.utf8))
        return ActivitySnapshot(activeRuns: snapshot.activeRuns.map {
            NotebookRun(ref: $0.ref, title: $0.title, status: $0.status,
                        lastRunAt: KaggleTimestamp.date(from: $0.lastRunAt), project: $0.project)
        }, notebooksChecked: snapshot.notebooksChecked, unavailableCount: snapshot.unavailableCount ?? 0,
           source: .hub)
    }

    // MARK: - Direct mode

    /// One list request per poll, then status requests only for notebooks that
    /// may have changed; see `DirectModeState.notebooksToCheck`.
    private func directSnapshot() async throws -> ActivitySnapshot {
        let listArguments = [
            "kernels", "list", "--mine",
            "--sort-by", "dateRun",
            "--page-size", String(Self.notebookLimit),
            "--format", "json(ref,title,lastRunTime)",
        ]
        let list = try await execute(.kaggle, listArguments, timeout: 60)
        let notebooks: [NotebookMetadata]
        if list.succeeded {
            notebooks = try Self.decodeNotebooks(from: list.stdout)
        } else if (list.stdout + list.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("Not found") == .orderedSame {
            notebooks = []
        } else {
            throw failure(list, tool: .kaggle, arguments: listArguments, timeout: 60)
        }

        for notebook in await direct.notebooksToCheck(notebooks, now: now()) {
            try Task.checkCancellation()
            try await pause()
            let status = try await status(of: notebook)
            await direct.record(status, for: notebook, at: now())
        }
        let (runs, unavailable) = await direct.finishPoll(listing: notebooks, now: now())

        return ActivitySnapshot(
            activeRuns: runs.sorted { lhs, rhs in
                if lhs.status == rhs.status {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.status == .running
            },
            notebooksChecked: notebooks.count,
            unavailableCount: unavailable,
            source: .direct
        )
    }

    private func status(of notebook: NotebookMetadata) async throws -> DirectModeState.Status {
        let arguments = ["kernels", "status", notebook.ref]
        let result = try await execute(.kaggle, arguments, timeout: 45)
        guard result.succeeded else {
            // A listed notebook can be deleted or private to someone else by
            // now. Count it rather than failing every other notebook.
            if Self.isUnavailable(result.stdout + "\n" + result.stderr) { return .unavailable }
            throw failure(result, tool: .kaggle, arguments: arguments, timeout: 45)
        }
        guard let raw = Self.status(in: result.stdout + "\n" + result.stderr) else {
            throw KaggleCLIError.unreadableStatus(notebook.ref)
        }
        switch raw {
        case "QUEUED":
            return .active(.queued)
        case "RUNNING", "CANCEL_REQUESTED":
            // A cancellation request still holds a session until Kaggle acknowledges it.
            return .active(.running)
        case "COMPLETE", "ERROR", "CANCEL_ACKNOWLEDGED":
            return .finished
        case "NEW_SCRIPT":
            // A just-pushed version waits as NEW_SCRIPT; a draft that never ran
            // reports it too, so only a recent run counts as queued.
            let listed = KaggleTimestamp.date(from: notebook.lastRunTime)
            let isRecent = listed.map { now().timeIntervalSince($0) < 3600 } ?? false
            return isRecent ? .active(.queued) : .finished
        default:
            throw KaggleCLIError.unreadableStatus(notebook.ref)
        }
    }

    static func isUnavailable(_ output: String) -> Bool {
        output.firstMatch(of: #/\b40[34] (?:Client Error|Forbidden|Not Found)\b/#) != nil
            || output.contains("Cannot access kernel")
            || output.contains("kernels.get")
    }

    // MARK: - Running commands

    private func execute(_ tool: Tool, _ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        let result: ProcessResult
        if let command {
            result = try await command(tool, arguments, timeout)
        } else {
            let executable: URL
            switch tool {
            case .kaggle: executable = try Self.kaggleExecutableURL()
            case let .hub(url): executable = url
            }
            do {
                result = try await ProcessRunner.run(executable, arguments: arguments, timeout: timeout)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.record("command_not_started", ["command": Self.label(tool, arguments), "error": error.localizedDescription])
                throw KaggleCLIError.couldNotStart(error.localizedDescription)
            }
        }
        if result.succeeded, result.duration > 30 {
            log.record("command_slow", ["command": Self.label(tool, arguments), "seconds": result.duration])
        }
        return result
    }

    /// Logs the whole failure and returns the error to throw.
    private func failure(_ result: ProcessResult, tool: Tool, arguments: [String], timeout: TimeInterval) -> KaggleCLIError {
        let failure = CommandFailure(result: result, command: Self.label(tool, arguments), timeout: timeout)
        var fields: [String: any Sendable] = [
            "command": failure.command,
            "exit": Int(result.exitCode),
            "seconds": result.duration,
            "timed_out": result.timedOut,
            "kind": failure.kind.rawValue,
            "summary": failure.summary,
            "stderr_tail": String(result.stderr.suffix(CommandFailure.detailLimit)),
            "stdout_tail": String(result.stdout.suffix(4000)),
        ]
        if case let .hub(url) = tool { fields["hub"] = url.path }
        if let cause = failure.cause { fields["cause"] = cause }
        log.record("command_failed", fields)

        if failure.kind == .rateLimited {
            return .rateLimited(retryAfter: failure.retryAfter ?? KaggleCLIError.defaultRateLimitWait)
        }
        return .commandFailed(failure)
    }

    private static func label(_ tool: Tool, _ arguments: [String]) -> String {
        switch tool {
        case .kaggle: (["kaggle"] + arguments).joined(separator: " ")
        case .hub: (["kaggle-hub"] + arguments).joined(separator: " ")
        }
    }

    static func kaggleExecutableURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        var candidates: [String] = []

        if let configuredPath = environment["KAGGLE_CLI_PATH"], !configuredPath.isEmpty {
            candidates.append(configuredPath)
        }

        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/kaggle" })
        }

        let home = fileManager.homeDirectoryForCurrentUser.path
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/kaggle",
            "/usr/local/bin/kaggle",
            "\(home)/.local/bin/kaggle",
            "\(home)/Library/Python/3.14/bin/kaggle",
            "\(home)/Library/Python/3.13/bin/kaggle",
            "\(home)/Library/Python/3.12/bin/kaggle",
            "\(home)/Library/Python/3.11/bin/kaggle"
        ])

        var visited = Set<String>()
        for candidate in candidates where visited.insert(candidate).inserted {
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        throw KaggleCLIError.missingCLI
    }

    // MARK: - Parsing

    static func decodeNotebooks(from output: String) throws -> [NotebookMetadata] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("Not found") != .orderedSame else {
            return []
        }

        guard let start = trimmed.firstIndex(of: "["),
              let end = trimmed.lastIndex(of: "]"), start <= end
        else {
            throw KaggleCLIError.unreadableNotebookList
        }

        let json = String(trimmed[start...end])
        do {
            let rows = try JSONDecoder().decode([NotebookMetadata].self, from: Data(json.utf8))
            // Kaggle can include a row with a title/date but no owner or ref.
            // Passing that blank to `kernels status` fails the entire snapshot.
            let notebooks = rows.filter { $0.hasQueryableReference }
            guard rows.isEmpty || !notebooks.isEmpty else {
                throw KaggleCLIError.unreadableNotebookList
            }
            return notebooks
        } catch {
            throw KaggleCLIError.unreadableNotebookList
        }
    }

    private static func status(in output: String) -> String? {
        guard let statusStart = output.range(of: "status", options: .caseInsensitive) else {
            return nil
        }
        let remainder = output[statusStart.upperBound...]
        guard let openingQuote = remainder.firstIndex(of: "\"") else { return nil }
        let valueStart = remainder.index(after: openingQuote)
        guard let closingQuote = remainder[valueStart...].firstIndex(of: "\"") else { return nil }

        let statusValue = remainder[valueStart..<closingQuote]
            .split(separator: ".")
            .last
            .map(String.init)?
            .uppercased()
        return statusValue
    }
}

/// What direct mode remembers between polls, so a poll spends status requests
/// only on notebooks that may have changed. kaggle-hub keeps the same
/// bookkeeping on disk; this copy lasts for the app session.
actor DirectModeState {
    enum Status: Equatable {
        case active(NotebookRunStatus)
        case finished
        case unavailable
    }

    private struct Entry {
        var listedRunTime: String?
        var status: Status
        var checkedAt: Date
        /// When this session first saw the current run active.
        var activeSince: Date?
    }

    /// Never-checked notebooks run this recently get a first status check.
    static let activeWindow: TimeInterval = 13 * 3600
    /// The newest notebooks run within this window are re-checked now and then,
    /// because a re-pushed version keeps the notebook's old `lastRunTime`.
    static let recentWindow: TimeInterval = 24 * 3600
    static let recentCount = 5
    static let recheckAge: TimeInterval = 120
    /// A listed run time this far behind the first active sighting belongs to
    /// an earlier run; Kaggle caps a session at 12 hours.
    static let staleRunTime: TimeInterval = 12 * 3600

    private var entries: [String: Entry] = [:]
    private var previouslyListed: Set<String>?

    /// Active notebooks every poll; a notebook whose run time changed or that
    /// newly appeared; never-checked notebooks run within 13 hours; and the
    /// five newest run within a day, at most every two minutes.
    func notebooksToCheck(_ notebooks: [NotebookMetadata], now: Date) -> [NotebookMetadata] {
        let recent = Set(notebooks
            .compactMap { notebook in
                KaggleTimestamp.date(from: notebook.lastRunTime).map { (notebook.ref, $0) }
            }
            .filter { now.timeIntervalSince($0.1) <= Self.recentWindow }
            .sorted { $0.1 > $1.1 }
            .prefix(Self.recentCount)
            .map(\.0))

        return notebooks.filter { notebook in
            let isRecent = recent.contains(notebook.ref)
            guard let entry = entries[notebook.ref] else {
                let listed = KaggleTimestamp.date(from: notebook.lastRunTime)
                let runRecently = listed.map { now.timeIntervalSince($0) <= Self.activeWindow } ?? false
                let isNew = previouslyListed.map { !$0.contains(notebook.ref) } ?? false
                return runRecently || isNew || isRecent
            }
            if case .active = entry.status { return true }
            if entry.listedRunTime != notebook.lastRunTime { return true }
            return isRecent && now.timeIntervalSince(entry.checkedAt) > Self.recheckAge
        }
    }

    func record(_ status: Status, for notebook: NotebookMetadata, at now: Date) {
        let previous = entries[notebook.ref]
        var activeSince: Date?
        if case .active = status {
            activeSince = previous?.activeSince ?? now
        }
        entries[notebook.ref] = Entry(listedRunTime: notebook.lastRunTime, status: status,
                                      checkedAt: now, activeSince: activeSince)
    }

    /// The active runs among the listed notebooks, and how many are unavailable.
    func finishPoll(listing notebooks: [NotebookMetadata], now: Date) -> (runs: [NotebookRun], unavailable: Int) {
        previouslyListed = Set(notebooks.map(\.ref))
        var runs: [NotebookRun] = []
        var unavailable = 0
        for notebook in notebooks {
            guard let entry = entries[notebook.ref] else { continue }
            switch entry.status {
            case let .active(status):
                runs.append(NotebookRun(
                    ref: notebook.ref,
                    title: notebook.title.isEmpty ? notebook.ref : notebook.title,
                    status: status,
                    lastRunAt: Self.runStart(listed: KaggleTimestamp.date(from: notebook.lastRunTime),
                                             activeSince: entry.activeSince)
                ))
            case .unavailable:
                unavailable += 1
            case .finished:
                break
            }
        }
        return (runs, unavailable)
    }

    static func runStart(listed: Date?, activeSince: Date?) -> Date? {
        guard let activeSince else { return listed }
        guard let listed else { return activeSince }
        return activeSince.timeIntervalSince(listed) > staleRunTime ? activeSince : listed
    }
}

struct NotebookMetadata: Decodable, Sendable {
    let ref: String
    let title: String
    let lastRunTime: String?

    private enum CodingKeys: String, CodingKey {
        case ref
        case title
        case lastRunTime
    }

    init(ref: String, title: String, lastRunTime: String?) {
        self.ref = ref
        self.title = title
        self.lastRunTime = lastRunTime
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ref = (try values.decodeIfPresent(String.self, forKey: .ref) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ref
        lastRunTime = try? values.decodeIfPresent(String.self, forKey: .lastRunTime)
    }

    var hasQueryableReference: Bool {
        let parts = ref.split(separator: "/", omittingEmptySubsequences: false)
        return (parts.count == 2 || parts.count == 3)
            && parts.allSatisfy { !$0.isEmpty && !$0.contains(where: \.isWhitespace) && !$0.hasPrefix("-") }
    }
}

enum KaggleCLIError: LocalizedError {
    case missingCLI
    case missingHub
    case signInFailed
    case unreadableNotebookList
    case unreadableHubSnapshot
    case unreadableStatus(String)
    case commandFailed(CommandFailure)
    case couldNotStart(String)
    case rateLimited(retryAfter: TimeInterval)

    static let defaultRateLimitWait: TimeInterval = 300

    var errorDescription: String? {
        switch self {
        case .missingCLI:
            "Kaggle CLI not found. Install it with `pipx install kaggle` or `uv tool install kaggle`, then refresh."
        case .missingHub:
            "kaggle-hub was not found. Install it, or set the activity source back to auto."
        case .signInFailed:
            "Kaggle sign-in did not finish. Check the browser flow and try again."
        case .unreadableNotebookList:
            "Kaggle returned a notebook list the app could not read. Update the Kaggle CLI and retry."
        case .unreadableHubSnapshot:
            "kaggle-hub returned output the app could not read. Details are in the diagnostic log."
        case .rateLimited:
            "Kaggle is limiting requests. Checks resume after a short wait."
        case let .unreadableStatus(ref):
            "Could not read the latest run status for \(ref)."
        case let .commandFailed(failure):
            failure.summary
        case let .couldNotStart(message):
            "Could not start the Kaggle CLI: \(message)"
        }
    }

    /// Show the error at once instead of retrying quietly first.
    var showsImmediately: Bool {
        switch self {
        case .missingCLI, .missingHub, .signInFailed, .couldNotStart, .rateLimited: true
        case .unreadableNotebookList, .unreadableHubSnapshot, .unreadableStatus: false
        case let .commandFailed(failure): failure.showsImmediately
        }
    }

    var failure: CommandFailure? {
        if case let .commandFailed(failure) = self { return failure }
        return nil
    }
}
