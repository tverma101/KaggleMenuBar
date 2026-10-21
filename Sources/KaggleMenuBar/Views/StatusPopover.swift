import AppKit
import SwiftUI

struct StatusPopover: View {
    @ObservedObject var store: NotebookStore
    let onOpen: (URL) -> Void

    static let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            separator

            content

            if let errorMessage = store.errorMessage {
                errorNotice(errorMessage)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

            separator

            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            BrandBadge()

            VStack(alignment: .leading, spacing: 1) {
                Text("Kaggle notebooks")
                    .font(.system(size: 13, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            if store.connectionState == .connected {
                RefreshButton(isRefreshing: store.isRefreshing, retryAfter: store.retryAfter) {
                    Task { await store.refresh() }
                }
            }
        }
    }

    private var headerSubtitle: String {
        switch store.connectionState {
        case .disconnected:
            return "Not connected"
        case .connecting:
            return "Connecting…"
        case .connected:
            if store.snapshotState == .failed { return "Status check failed" }
            if store.activeRuns.isEmpty {
                return store.snapshotState == .checking ? "Checking notebooks…" : "Nothing running"
            }
            var parts: [String] = []
            if store.runningCount > 0 { parts.append("\(store.runningCount) running") }
            if store.queuedCount > 0 { parts.append("\(store.queuedCount) queued") }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.connectionState {
        case .disconnected:
            connectPrompt
        case .connecting:
            message(progress: true, "Finish signing in to Kaggle in your browser.")
        case .connected:
            if !store.activeRuns.isEmpty {
                runList
            } else if store.snapshotState == .failed {
                message(progress: false, "Notebook status is unavailable. Use Refresh to try again.")
            } else if store.snapshotState == .checking {
                message(progress: true, "Checking your latest notebook runs…")
            } else {
                message(progress: false, "The menu bar item hides until a notebook is queued or running.")
            }
        }
    }

    private var runList: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.activeRuns) { run in
                        NotebookRow(run: run, now: context.date, onOpen: onOpen)
                    }
                }
                .padding(6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 6 * 44 + 12)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect your Kaggle account once. Queued and running notebooks then show up in the menu bar on their own.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    store.connect()
                } label: {
                    Text("Connect Kaggle")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(nsColor: KaggleStyle.accent))
                .controlSize(.regular)

                Link("CLI setup", destination: URL(string: "https://github.com/Kaggle/kaggle-cli#installation")!)
                    .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func message(progress: Bool, _ text: String) -> some View {
        HStack(spacing: 10) {
            if progress {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private func errorNotice(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: KaggleStyle.warning))
            VStack(alignment: .leading, spacing: 5) {
                Text(message)
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                CopyButton(title: "Copy details") {
                    DiagnosticReport.failureDetails(store: store)
                }
            }
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: KaggleStyle.warning).opacity(0.14))
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(footerStatus)
                .monospacedDigit()
            Spacer()
            diagnosticsMenu
            FooterButton(title: "Quit") { NSApp.terminate(nil) }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var diagnosticsMenu: some View {
        Menu("Diagnostics") {
            Button("Copy Diagnostics") {
                DiagnosticReport.copy(DiagnosticReport.full(store: store))
            }
            Button("Show Log in Finder") {
                DiagnosticLog.shared.ensureFileExists()
                NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.shared.fileURL])
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Copy a redacted report, or open the diagnostic log")
    }

    private var footerStatus: String {
        if store.isRefreshing { return "Checking…" }
        if store.snapshotState == .failed { return "Last check failed" }
        if store.failureStreak > 0 { return "Check failed · retrying" }
        if store.unavailableCount > 0 { return "\(store.notebooksChecked) checked · \(store.unavailableCount) unavailable" }
        if let lastUpdated = store.lastUpdated {
            return "Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))"
        }
        return "Uses the official Kaggle CLI"
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 14)
    }
}

private struct RefreshButton: View {
    let isRefreshing: Bool
    let retryAfter: Date?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if isRefreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color.primary.opacity(isHovered ? 0.08 : 0)))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(isRefreshing || (retryAfter.map { $0 > Date() } ?? false))
        .onHover { isHovered = $0 }
        .help("Check Kaggle now")
        .accessibilityLabel("Refresh")
    }
}

/// Copies text made on click, then says so for a moment.
private struct CopyButton: View {
    let title: String
    let text: () -> String

    @State private var copied = false
    @State private var isHovered = false

    var body: some View {
        Button {
            DiagnosticReport.copy(text())
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovered ? .primary : .secondary)
        .onHover { isHovered = $0 }
    }
}

private struct FooterButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .foregroundStyle(isHovered ? .primary : .secondary)
            .onHover { isHovered = $0 }
    }
}
