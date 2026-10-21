import Foundation

struct NotebookRun: Identifiable, Hashable, Sendable {
    let ref: String
    let title: String
    let status: NotebookRunStatus
    /// Kaggle's `lastRunTime` for the notebook, when the CLI reports one.
    var lastRunAt: Date? = nil
    var project: String? = nil

    var id: String { ref }

    var kaggleURL: URL? {
        let parts = ref.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return URL(string: "https://www.kaggle.com/code/\(parts[0])/\(parts[1])")
    }
}

enum NotebookRunStatus: String, CaseIterable, Hashable, Sendable, Decodable {
    case queued = "QUEUED"
    case running = "RUNNING"

    var label: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        }
    }
}

struct ActivitySnapshot: Sendable {
    let activeRuns: [NotebookRun]
    let notebooksChecked: Int
    var unavailableCount: Int = 0
}

/// Time since a run's `lastRunAt`, in whole minutes.
enum ElapsedTime {
    /// Menu bar form: "now", "47m", "1h12m", "11h".
    static func compact(since start: Date, now: Date) -> String {
        let minutes = wholeMinutes(since: start, now: now)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours >= 10 || remainder == 0 { return "\(hours)h" }
        return "\(hours)h\(remainder)m"
    }

    /// Panel form: "just now", "47m", "2h 14m".
    static func label(since start: Date, now: Date) -> String {
        let minutes = wholeMinutes(since: start, now: now)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    private static func wholeMinutes(since start: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(start) / 60))
    }
}

enum KaggleTimestamp {
    /// Parses the CLI's `lastRunTime`, e.g. `2026-10-18T19:34:50.560000`.
    /// Kaggle reports UTC without a zone suffix.
    static func date(from raw: String?) -> Date? {
        guard var raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.hasSuffix("Z") { raw.removeLast() }

        let parts = raw.split(separator: ".", maxSplits: 1)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let base = formatter.date(from: String(parts[0])) else { return nil }

        if parts.count == 2, let fraction = Double("0." + parts[1].prefix(6)) {
            return base.addingTimeInterval(fraction)
        }
        return base
    }
}
