import Foundation
import OSLog

/// A JSON-lines record of launches, command failures, snapshots and status
/// item changes under `~/Library/Logs/KaggleMenuBar`, so an error that will not
/// reproduce still leaves its full command output behind. Every entry is
/// redacted before it is written and is mirrored to the unified log.
final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog(
        directory: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/KaggleMenuBar", directoryHint: .isDirectory)
    )

    let fileURL: URL
    private let backupURL: URL
    private let directory: URL
    /// The current file rolls over to a single backup at this size, so the
    /// log never holds more than about twice this.
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "app.kernelwatch.KernelWatch.diagnostics", qos: .utility)
    private let logger = Logger(subsystem: "app.kernelwatch.KernelWatch", category: "Diagnostics")
    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current)

    init(directory: URL, maxBytes: Int = 1_000_000) {
        self.directory = directory
        self.maxBytes = maxBytes
        fileURL = directory.appending(path: "diagnostics.jsonl")
        backupURL = directory.appending(path: "diagnostics.1.jsonl")
    }

    /// Values must be strings, numbers, booleans or arrays of those.
    func record(_ event: String, _ fields: [String: any Sendable] = [:]) {
        let time = Date()
        queue.async { self.append(event, fields, at: time) }
    }

    /// The newest `limit` entries, oldest first.
    func recentEntries(limit: Int) -> [String] {
        queue.sync {
            let text = [backupURL, fileURL]
                .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
                .joined()
            return text.split(whereSeparator: \.isNewline).suffix(limit).map(String.init)
        }
    }

    /// Creates the file if nothing has been logged yet, so it can be revealed.
    func ensureFileExists() {
        queue.sync { try? openForAppending()?.close() }
    }

    /// Waits for pending writes. Tests use it before reading the file.
    func flush() {
        queue.sync {}
    }

    private func append(_ event: String, _ fields: [String: any Sendable], at time: Date) {
        var object: [String: Any] = ["time": Self.timestamp.format(time), "event": event]
        for (key, value) in fields {
            object[key] = Self.jsonValue(value)
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return }
        logger.log("\(String(decoding: data, as: UTF8.self), privacy: .public)")

        let fileManager = FileManager.default
        let size = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        if size > 0, size + data.count + 1 > maxBytes {
            if fileManager.fileExists(atPath: backupURL.path) {
                _ = try? fileManager.replaceItemAt(backupURL, withItemAt: fileURL)
            } else {
                try? fileManager.moveItem(at: fileURL, to: backupURL)
            }
        }
        guard let handle = openForAppending() else { return }
        defer { try? handle.close() }
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }

    private func openForAppending() -> FileHandle? {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }

    private static func jsonValue(_ value: any Sendable) -> Any {
        switch value {
        case let text as String: Redactor.redact(text)
        case let texts as [String]: texts.map(Redactor.redact)
        case let flag as Bool: flag
        case let number as Int: number
        case let number as Int32: Int(number)
        case let number as Double: number.isFinite ? (number * 1000).rounded() / 1000 : 0
        default: Redactor.redact(String(describing: value))
        }
    }
}

/// Removes credentials and the home folder path from text that leaves the
/// process: the diagnostic log, copied diagnostics and error details.
enum Redactor {
    private static let rules: [(NSRegularExpression, String)] = [
        (#"KGAT_[A-Za-z0-9_]+"#, "[redacted]"),
        (#"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+"#, "$1[redacted]"),
        // kaggle.json: {"username": "...", "key": "..."}
        (#"("key"\s*:\s*")[^"]+"#, "$1[redacted]"),
        (#"(?i)([\w-]*(?:api[_-]?key|token|secret|password)[\w-]*["']?\s*[=:]\s*["']?)[^\s"',;]+"#, "$1[redacted]"),
    ].map { pattern, template in
        (try! NSRegularExpression(pattern: pattern), template)
    }

    static func redact(_ text: String) -> String {
        var result = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        for (expression, template) in rules {
            result = expression.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }
}
