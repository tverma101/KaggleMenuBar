import SwiftUI

/// The panel's version of a menu bar circle: a solid Kaggle-colored dot,
/// green while running and orange while queued.
struct RunDot: View {
    let status: NotebookRunStatus
    var diameter: CGFloat = 10

    var body: some View {
        Circle()
            .fill(Color(nsColor: KaggleStyle.statusColor(for: status)))
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }
}

/// Kaggle-blue disc with a white "k", the same mark the menu bar pill starts with.
struct KaggleBadge: View {
    var size: CGFloat = 26

    var body: some View {
        Circle()
            .fill(Color(nsColor: KaggleStyle.blue))
            .overlay {
                KaggleMarkShape()
                    .fill(.white)
                    .frame(
                        width: KaggleMark.width(forHeight: size * 0.5),
                        height: size * 0.5
                    )
                    .offset(x: -size * 0.02)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
