import Foundation

struct KaggleCLI: Sendable {
    private static let notebookLimit = 100
    private static let statusConcurrency = 4

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

    private func activeRuns(for notebooks: [NotebookMetadata]) async throws -> [NotebookRun] {
        guard !notebooks.isEmpty else { return [] }

        return try await withThrowingTaskGroup(of: NotebookRun?.self) { group in
            var nextIndex = 0
            let initialCount = min(Self.statusConcurrency, notebooks.count)

            for _ in 0..<initialCount {
                let notebook = notebooks[nextIndex]
                nextIndex += 1
                group.addTask {
                    try await self.runStatus(for: notebook)
                }
            }

            var activeRuns: [NotebookRun] = []
            while let result = try await group.next() {
                if let result {
                    activeRuns.append(result)
                }

                if nextIndex < notebooks.count {
                    let notebook = notebooks[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        try await self.runStatus(for: notebook)
                    }
                }
            }

            return activeRuns
        }
    }

    private func runStatus(for notebook: NotebookMetadata) async throws -> NotebookRun? {
        let output = try await run(["kernels", "status", notebook.ref], timeout: 45)
        guard let rawStatus = Self.status(in: output) else {
            throw KaggleCLIError.unreadableStatus(notebook.ref)
        }
        guard let status = NotebookRunStatus(rawValue: rawStatus) else { return nil }

        return NotebookRun(
            ref: notebook.ref,
            title: notebook.title.isEmpty ? notebook.ref : notebook.title,
            status: status,
            lastRunAt: KaggleTimestamp.date(from: notebook.lastRunTime)
        )
    }

    private func run(_ arguments: [String], timeout: TimeInterval) async throws -> String {
        let executable = try Self.kaggleExecutableURL()
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
            return try JSONDecoder().decode([NotebookMetadata].self, from: Data(json.utf8))
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
        ref = try values.decode(String.self, forKey: .ref)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ref
        lastRunTime = try? values.decodeIfPresent(String.self, forKey: .lastRunTime)
    }
}

private enum KaggleCLIError: LocalizedError {
    case missingCLI
    case signInFailed
    case unreadableNotebookList
    case unreadableStatus(String)
    case commandFailed(String)
    case couldNotStart(String)

    var errorDescription: String? {
        switch self {
        case .missingCLI:
            "Kaggle CLI not found. Install it, then try again."
        case .signInFailed:
            "Kaggle sign-in did not finish. Check the browser flow and try again."
        case .unreadableNotebookList:
            "Kaggle returned a notebook list the app could not read. Update the Kaggle CLI and retry."
        case let .unreadableStatus(ref):
            "Could not read the latest run status for \(ref)."
        case let .commandFailed(message):
            message
        case let .couldNotStart(message):
            "Could not start the Kaggle CLI: \(message)"
        }
    }
}
