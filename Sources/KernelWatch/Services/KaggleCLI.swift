import Foundation

protocol KaggleActivityProviding: Sendable {
    func signIn() async throws
    func activitySnapshot() async throws -> ActivitySnapshot
}

struct KaggleCLI: KaggleActivityProviding {
    typealias Command = @Sendable ([String], TimeInterval) async throws -> String
    typealias Pause = @Sendable () async throws -> Void
    private static let notebookLimit = 100
    private let command: Command?
    private let pause: Pause
    private let statusCache = NotebookStatusCache()

    init(command: Command? = nil,
         pause: @escaping Pause = { try await Task.sleep(for: .seconds(1)) }) {
        self.command = command
        self.pause = pause
    }

    func signIn() async throws {
        do {
            _ = try await run(["auth", "login"], timeout: 300)
        } catch let error as KaggleCLIError {
            throw error
        } catch {
            throw KaggleCLIError.signInFailed
        }
    }

    func activitySnapshot() async throws -> ActivitySnapshot {
        // Production reads go through the shared hub so this app and repo
        // agents cannot independently sweep the same Kaggle account.
        if command == nil { return try await sharedActivitySnapshot() }
        let output = try await run(
            [
                "kernels", "list", "--mine",
                "--sort-by", "dateRun",
                "--page-size", String(Self.notebookLimit),
                "--format", "json(ref,title,lastRunTime)"
            ],
            timeout: 60
        )
        let notebooks = try Self.decodeNotebooks(from: output)
        let activeRuns = try await activeRuns(for: notebooks)

        return ActivitySnapshot(
            activeRuns: activeRuns.sorted { lhs, rhs in
                if lhs.status == rhs.status {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.status == .running
            },
            notebooksChecked: notebooks.count
        )
    }

    private func sharedActivitySnapshot() async throws -> ActivitySnapshot {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [environment["KAGGLE_HUB_PATH"], "\(home)/.local/bin/kaggle-hub", "/opt/homebrew/bin/kaggle-hub"].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw KaggleCLIError.missingHub
        }
        let output = try await run(["monitor-snapshot"], timeout: 900, executable: URL(fileURLWithPath: path))
        return try Self.decodeHubSnapshot(output)
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
        }, notebooksChecked: snapshot.notebooksChecked, unavailableCount: snapshot.unavailableCount ?? 0)
    }

    private func activeRuns(for notebooks: [NotebookMetadata]) async throws -> [NotebookRun] {
        var activeRuns: [NotebookRun] = []
        for notebook in notebooks {
            try Task.checkCancellation()
            // Finished runs do not need another status request until their run
            // date changes. Expire the cache as a fallback for stale list data.
            if await statusCache.isFinished(notebook) { continue }
            try await pause()
            if let run = try await runStatus(for: notebook) {
                activeRuns.append(run)
            } else {
                await statusCache.rememberFinished(notebook)
            }
        }
        return activeRuns
    }

    private func runStatus(for notebook: NotebookMetadata) async throws -> NotebookRun? {
        let output = try await run(["kernels", "status", notebook.ref], timeout: 45)
        guard let rawStatus = Self.status(in: output) else {
            throw KaggleCLIError.unreadableStatus(notebook.ref)
        }
        guard ["QUEUED", "RUNNING", "COMPLETE", "ERROR", "CANCEL_REQUESTED", "CANCEL_ACKNOWLEDGED", "NEW_SCRIPT"].contains(rawStatus) else {
            throw KaggleCLIError.unreadableStatus(notebook.ref)
        }
        let lastRunAt = KaggleTimestamp.date(from: notebook.lastRunTime)
        let rawStatusForDisplay: String
        switch rawStatus {
        case "CANCEL_REQUESTED":
            // A cancellation request is still consuming a running session until
            // Kaggle acknowledges it.
            rawStatusForDisplay = "RUNNING"
        case "NEW_SCRIPT":
            // A just-pushed version waits as NEW_SCRIPT; a draft that never ran
            // reports it too, so only a recent run counts as queued.
            let isRecent = lastRunAt.map { Date().timeIntervalSince($0) < 3600 } ?? false
            rawStatusForDisplay = isRecent ? "QUEUED" : rawStatus
        default:
            rawStatusForDisplay = rawStatus
        }
        guard let status = NotebookRunStatus(rawValue: rawStatusForDisplay) else { return nil }

        return NotebookRun(
            ref: notebook.ref,
            title: notebook.title.isEmpty ? notebook.ref : notebook.title,
            status: status,
            lastRunAt: lastRunAt
        )
    }

    private func run(_ arguments: [String], timeout: TimeInterval, executable configuredExecutable: URL? = nil) async throws -> String {
        if let command { return try await command(arguments, timeout) }
        let executable = try configuredExecutable ?? Self.kaggleExecutableURL()
        return try await Task.detached(priority: .utility) {
            let process = Process()
            let outputPipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            do {
                try process.run()
            } catch {
                throw KaggleCLIError.couldNotStart(error.localizedDescription)
            }

            let timeoutWork = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout,
                execute: timeoutWork
            )

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeoutWork.cancel()

            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                if arguments.starts(with: ["auth", "login"]) {
                    throw KaggleCLIError.signInFailed
                }
                if output.localizedCaseInsensitiveContains("rate limit")
                    || (output.contains("429") && output.localizedCaseInsensitiveContains("too many requests")) {
                    throw KaggleCLIError.rateLimited
                }
                throw KaggleCLIError.commandFailed(Self.shortMessage(from: output))
            }
            return output
        }.value
    }

    private static func kaggleExecutableURL() throws -> URL {
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

    private static func decodeNotebooks(from output: String) throws -> [NotebookMetadata] {
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

    private static func shortMessage(from output: String) -> String {
        let line = output
            .split(whereSeparator: \.isNewline)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line, !line.isEmpty else {
            return "The Kaggle command failed. Try reconnecting and refreshing."
        }
        return String(line.prefix(180))
    }
}

private actor NotebookStatusCache {
    private struct Entry {
        let lastRunTime: String?
        let checkedAt: Date
    }
    private var finished: [String: Entry] = [:]

    func isFinished(_ notebook: NotebookMetadata) -> Bool {
        guard let entry = finished[notebook.ref] else { return false }
        return entry.lastRunTime == notebook.lastRunTime
            && Date().timeIntervalSince(entry.checkedAt) < 15 * 60
    }

    func rememberFinished(_ notebook: NotebookMetadata) {
        finished[notebook.ref] = Entry(lastRunTime: notebook.lastRunTime, checkedAt: Date())
    }
}

private struct NotebookMetadata: Decodable, Sendable {
    let ref: String
    let title: String
    let lastRunTime: String?

    private enum CodingKeys: String, CodingKey {
        case ref
        case title
        case lastRunTime
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
    case unreadableStatus(String)
    case commandFailed(String)
    case couldNotStart(String)
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .missingCLI:
            "Kaggle CLI not found. Install it, then try again."
        case .missingHub:
            "Kaggle Compute Hub is unavailable. Restore kaggle-hub to resume shared notebook checks."
        case .signInFailed:
            "Kaggle sign-in did not finish. Check the browser flow and try again."
        case .unreadableNotebookList:
            "Kaggle returned a notebook list the app could not read. Update the Kaggle CLI and retry."
        case .rateLimited:
            "Kaggle is limiting status requests. Waiting five minutes before retrying."
        case let .unreadableStatus(ref):
            "Could not read the latest run status for \(ref)."
        case let .commandFailed(message):
            message
        case let .couldNotStart(message):
            "Could not start the Kaggle CLI: \(message)"
        }
    }
}
