import Foundation

/// A failed Kaggle CLI or kaggle-hub command, reduced to one line someone can
/// act on, with the redacted output tail that explains it.
struct CommandFailure: Sendable, Equatable {
    enum Kind: String, Sendable {
        /// Network trouble, a timeout, a Kaggle 5xx or a crash: retry first.
        case transient
        case rateLimited
        /// Kaggle rejected the saved credentials.
        case auth
        /// The CLI is missing, too old or was called wrongly; retrying won't help.
        case setup
        /// Nothing recognizable: retry once before showing it.
        case unknown
    }

    /// The line shown in the panel.
    let summary: String
    let kind: Kind
    /// The line the output ended with, e.g. the Python exception, when it
    /// differs from `summary`.
    let cause: String?
    /// e.g. "kaggle-hub monitor-snapshot".
    let command: String
    let exitCode: Int32
    /// Redacted end of stdout and stderr.
    let detail: String
    /// Seconds to wait, when Kaggle or the hub said how long.
    let retryAfter: TimeInterval?

    /// Retrying soon is pointless, or the wait is already known.
    var showsImmediately: Bool {
        switch kind {
        case .rateLimited, .auth, .setup: true
        case .transient, .unknown: false
        }
    }

    static let detailLimit = 16_000

    init(result: ProcessResult, command: String, timeout: TimeInterval) {
        self.command = command
        exitCode = result.exitCode
        let output = Self.normalized(result.stdout + "\n" + result.stderr)
        detail = String(Redactor.redact(output).suffix(Self.detailLimit))
        retryAfter = Self.retrySeconds(in: output)

        let lastLine = Self.lastMeaningfulLine(in: output)
        let kind = result.timedOut ? .transient : Self.kind(of: output, lastLine: lastLine)
        self.kind = kind

        let summary: String
        if result.timedOut {
            summary = "\(command) did not finish within \(Int(timeout)) seconds. Retrying."
        } else {
            summary = Self.summary(kind: kind, lastLine: lastLine, output: output, exitCode: result.exitCode)
        }
        let shown = Redactor.redact(summary)
        self.summary = shown
        cause = lastLine.map(Redactor.redact).flatMap { $0 == shown ? nil : String($0.prefix(500)) }
    }

    // MARK: - Reading the output

    /// The exception line a Python traceback ends with, else the last line
    /// that is not part of a traceback. The start of a traceback only names
    /// files, which is how a cut-off stack frame once ended up in the panel.
    static func lastMeaningfulLine(in output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if let exception = lines.last(where: { $0.firstMatch(of: exceptionLine) != nil }) {
            return exception.trimmingCharacters(in: .whitespaces)
        }
        return lines.last(where: { line in
            // Frames and their source lines are indented; carets mark columns.
            guard let first = line.first, !first.isWhitespace else { return false }
            if line.hasPrefix("Traceback") || line.hasPrefix("During handling") || line.hasPrefix("The above exception") {
                return false
            }
            return !line.allSatisfy { "^~ ".contains($0) }
        })?.trimmingCharacters(in: .whitespaces)
    }

    private static let exceptionLine = #/^[A-Za-z_][\w.]*(?:Error|Exception|Exit|Interrupt)\b/#

    /// Drops terminal color codes and the hub's "kaggle-hub: " prefix, which
    /// would otherwise hide the line structure.
    private static func normalized(_ text: String) -> String {
        text.replacing(#/\u{1B}\[[0-9;]*[A-Za-z]/#, with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("kaggle-hub: ") ? $0.dropFirst("kaggle-hub: ".count) : $0 }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func retrySeconds(in output: String) -> TimeInterval? {
        guard let match = output.firstMatch(of: #/(?i)retry in (\d+) seconds/#) else { return nil }
        return TimeInterval(match.1)
    }

    static func kind(of output: String, lastLine: String?) -> Kind {
        let text = output.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }

        if (text.contains("429") && has("too many requests", "rate limit")) || has("kaggle rate limit") {
            return .rateLimited
        }
        if has("401 client error", "unauthorized", "403 client error", "could not find kaggle.json",
               "you must authenticate", "kaggle_username", "invalid credentials", "kaggle auth login") {
            return .auth
        }
        if has("connectionerror", "connection reset", "connection aborted", "connection refused",
               "max retries exceeded", "timed out", "timeout", "name resolution", "nodename nor servname",
               "network is unreachable", "remotedisconnected", "sslerror", "ssl:", "eof occurred",
               "incomplete read", "broken pipe", "database is locked", "temporarily unavailable",
               "bad gateway", "service unavailable", "gateway timeout")
            || text.firstMatch(of: #/\b5\d\d server error\b/#) != nil {
            return .transient
        }
        if has("not installed", "missing from path", "command not found", "no such file or directory",
               "unrecognized arguments", "invalid choice", "usage: kaggle") {
            return .setup
        }
        // A traceback with no exception line: the CLI died mid-way.
        if lastLine == nil, has("traceback", "file \"") { return .transient }
        return .unknown
    }

    private static func summary(kind: Kind, lastLine: String?, output: String, exitCode: Int32) -> String {
        switch kind {
        case .rateLimited:
            return "Kaggle is limiting requests. Checks resume after a short wait."
        case .auth:
            return "Kaggle rejected the saved sign-in. Run `kaggle auth login` in Terminal, then refresh."
        case .transient:
            if lastLine == nil { return "The Kaggle CLI crashed without an error message. Details are in the diagnostic log." }
            let text = output.lowercased()
            if let code = text.firstMatch(of: #/\b(5\d\d) (?:server error|bad gateway|service unavailable)/#)?.1 {
                return "Kaggle's API returned an error (HTTP \(code)). Retrying."
            }
            if text.contains("database is locked") {
                return "kaggle-hub's cache was busy. Retrying."
            }
            return "Can't reach Kaggle right now. Retrying."
        case .setup, .unknown:
            guard let lastLine else {
                return output.isEmpty
                    ? "The Kaggle command failed with exit status \(exitCode) and no output."
                    : "The Kaggle CLI crashed without an error message. Details are in the diagnostic log."
            }
            return String(lastLine.prefix(240))
        }
    }
}
