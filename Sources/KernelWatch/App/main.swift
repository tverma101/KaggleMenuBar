import AppKit

// A plain AppKit entry point: the app is only a status item and its panel, so
// there are no SwiftUI scenes that could open stray windows.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: NotebookStore?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        // Screen-capture and UI-automation tools only list regular apps, so a
        // verification run can opt into a Dock icon. Normal launches stay menu-bar-only.
        if environment["KERNEL_WATCH_DOCK"] == "1" {
            NSApp.setActivationPolicy(.regular)
        }
        let store = environment["KERNEL_WATCH_DEMO"].map { NotebookStore(demo: $0) } ?? NotebookStore()
        self.store = store
        statusItemController = StatusItemController(store: store)
    }
}
