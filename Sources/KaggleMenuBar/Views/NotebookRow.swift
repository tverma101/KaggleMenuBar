import SwiftUI

struct NotebookRow: View {
    let run: NotebookRun
    let now: Date
    let onOpen: (URL) -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            if let url = run.kaggleURL { onOpen(url) }
        } label: {
            HStack(spacing: 10) {
                RunRing(run: run, now: now)

                VStack(alignment: .leading, spacing: 1) {
                    Text(run.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)

                    HStack(spacing: 4) {
                        if let project = run.project, project != "Unassigned" {
                            Text(project).foregroundStyle(.secondary).lineLimit(1)
                            Text("·").foregroundStyle(.tertiary)
                        }
                        Text(run.status.label)
                            .foregroundStyle(Color(nsColor: KaggleStyle.textColor(for: run.status)))
                        if let elapsed {
                            Text("·").foregroundStyle(.tertiary)
                            Text(elapsed).foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                }

                Spacer(minLength: 6)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
            )
        }
        .buttonStyle(.plain)
        .disabled(run.kaggleURL == nil)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .help(lastRunHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(run.title), \(run.status.label)\(elapsed.map { ", \($0)" } ?? "")")
        .accessibilityHint("Opens the notebook on Kaggle")
    }

    /// Time since Kaggle's last run timestamp, e.g. "47m" or "2h 14m".
    private var elapsed: String? {
        run.lastRunAt.map { ElapsedTime.label(since: $0, now: now) }
    }

    private var lastRunHelp: String {
        guard let start = run.lastRunAt else { return run.ref }
        return "\(run.ref)\nLast run started \(start.formatted(date: .omitted, time: .shortened))"
    }
}
