import AppKit

/// Plain-text reports for the clipboard, redacted, so a failure can be pasted
/// into an issue without opening the log.
@MainActor
enum DiagnosticReport {
    /// State, the newest failure and the recent log.
    static func full(store: NotebookStore, log: DiagnosticLog = .shared) -> String {
        var lines = summary(store: store)
        lines += ["", "Recent log (\(log.fileURL.path)):"]
        lines += log.recentEntries(limit: 80)
        return Redactor.redact(lines.joined(separator: "\n"))
    }

    /// State and the newest failure only.
    static func failureDetails(store: NotebookStore) -> String {
        Redactor.redact(summary(store: store).joined(separator: "\n"))
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func summary(store: NotebookStore) -> [String] {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "dev"
        let source = ActivitySource.configured()
        let hub = ActivitySource.installedHub()
        let kaggle = (try? KaggleCLI.kaggleExecutableURL().path) ?? "not found"
        let resolved: String = switch source {
        case .automatic: hub.map { "kaggle-hub at \($0.path)" } ?? "Kaggle CLI directly (no kaggle-hub found)"
        case .hub: hub.map { "kaggle-hub at \($0.path)" } ?? "kaggle-hub, but none was found"
        case .direct: "Kaggle CLI directly"
        }

        var lines = [
            "KaggleMenuBar \(version) (\(build)), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Source: \(source.rawValue), using \(resolved)",
            "Kaggle CLI: \(kaggle)",
            "State: \(store.connectionState), \(store.runningCount) running, \(store.queuedCount) queued, "
                + "\(store.notebooksChecked) notebooks checked, \(store.unavailableCount) unavailable",
            "Last update: \(store.lastUpdated.map(timestamp) ?? "never"), failures in a row: \(store.failureStreak)",
        ]
        if let shown = store.errorMessage {
            lines.append("Shown error: \(shown)")
        }
        if let record = store.lastFailure {
            lines += [
                "",
                "Last failure at \(timestamp(record.date)) (\(record.streak) in a row): \(record.message)",
            ]
            if let failure = record.failure {
                lines.append("Command: \(failure.command) (exit \(failure.exitCode), \(failure.kind.rawValue))")
                if let cause = failure.cause { lines.append("Cause: \(cause)") }
                if !failure.detail.isEmpty {
                    lines += ["Output tail:", String(failure.detail.suffix(4000))]
                }
            }
        }
        return lines
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeZone(separator: .omitted))
    }
}
