import AppKit
import SwiftUI
import XCTest
@testable import KaggleMenuBar

/// Opening and closing are animated, so these check where each transition
/// ends, including a close cut short by a quick second click.
@MainActor
final class MenuBarPanelTests: XCTestCase {
    private let anchor = NSRect(x: 400, y: 600, width: 40, height: 22)

    override func setUp() async throws {
        _ = NSApplication.shared
    }

    private func makePanel() -> MenuBarPanel {
        MenuBarPanel(content: Color.gray.frame(width: 200, height: 120))
    }

    private func settle(_ seconds: TimeInterval = 0.6) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testClosingOrdersThePanelOutOnceItHasFaded() {
        let panel = makePanel()
        panel.open(below: anchor)
        settle()
        XCTAssertTrue(panel.isVisible)

        panel.dismiss()
        XCTAssertFalse(panel.isOpen)
        settle()
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.alphaValue, 1, "the next open starts from a reset panel")
    }

    func testReopeningWhileClosingKeepsThePanelOpen() {
        let panel = makePanel()
        panel.open(below: anchor)
        settle()
        panel.dismiss()
        settle(0.05)
        panel.open(below: anchor)
        settle()

        XCTAssertTrue(panel.isOpen)
        XCTAssertTrue(panel.isVisible, "the cancelled close must not order the panel out")
        XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.01)
        panel.dismiss()
        settle()
    }
}
