import Foundation
import XCTest
@testable import KernelWatch

private actor FixtureCommands {
    var list: String
    var statuses: [String: String] = [:]
    private(set) var statusReferences: [String] = []

    init(list: String) { self.list = list }

    func setList(_ list: String) { self.list = list }
    func setStatus(_ status: String, for ref: String) { statuses[ref] = status }

    func run(_ arguments: [String], timeout: TimeInterval) async throws -> String {
        if arguments.starts(with: ["kernels", "list"]) { return list }
        guard arguments.count == 3, arguments.starts(with: ["kernels", "status"]),
              !arguments[2].isEmpty else {
            throw NSError(domain: "FixtureCommands", code: 1)
        }
        statusReferences.append(arguments[2])
        let status = statuses[arguments[2]] ?? (arguments[2] == "demo/running" ? "RUNNING" : "COMPLETE")
        return "Notebook has status \"KernelWorkerStatus.\(status)\""
    }
}

final class KaggleCLITests: XCTestCase {
    func testSharedHubSnapshotPreservesProjectStatusAndUnavailableCount() throws {
        let snapshot = try KaggleCLI.decodeHubSnapshot(#"""
        {"activeRuns":[{"ref":"demo/run","title":"Training","status":"QUEUED",
          "lastRunAt":"2026-10-19T12:00:00.000000","project":"MathNotes"}],
         "notebooksChecked":98,"unavailableCount":1,"checkedAt":1792450000}
        """#)
        XCTAssertEqual(snapshot.notebooksChecked, 98)
        XCTAssertEqual(snapshot.unavailableCount, 1)
        XCTAssertEqual(snapshot.activeRuns.first?.project, "MathNotes")
        XCTAssertEqual(snapshot.activeRuns.first?.status, .queued)
        XCTAssertNotNil(snapshot.activeRuns.first?.lastRunAt)
    }

    func testUnqueryableRowsDoNotAbortOtherNotebookStatusChecks() async throws {
        let fixture = FixtureCommands(list: #"""
        [
          {"ref":"", "title":"Unqueryable row", "lastRunTime":"2026-10-19T12:00:00"},
          {"ref":null, "title":"Null ref"},
          {"title":"Missing ref"},
          {"ref":"   "},
          {"ref":"not-a-reference"},
          {"ref":"demo/running", "title":"Running"},
          {"ref":" demo/finished ", "title":"Finished"}
        ]
        """#)
        let cli = KaggleCLI(command: { args, timeout in try await fixture.run(args, timeout: timeout) }, pause: {})
        let snapshot = try await cli.activitySnapshot()
        let references = await fixture.statusReferences
        XCTAssertEqual(Set(references), ["demo/running", "demo/finished"])
        XCTAssertEqual(references.count, 2)
        XCTAssertEqual(snapshot.notebooksChecked, 2)
        XCTAssertEqual(snapshot.activeRuns.map(\.ref), ["demo/running"])
    }

    func testOnlyUnqueryableRowsFailRatherThanReportIdle() async {
        let fixture = FixtureCommands(list: #"[{"ref":"", "title":"Unqueryable row"}]"#)
        let cli = KaggleCLI(command: { args, timeout in try await fixture.run(args, timeout: timeout) }, pause: {})
        do {
            _ = try await cli.activitySnapshot()
            XCTFail("An unreadable list is not a confirmed idle account")
        } catch {
            let references = await fixture.statusReferences
            XCTAssertTrue(references.isEmpty)
        }
    }

    func testFinishedCacheAvoidsRepeatedCallsAndChangedRunTimeInvalidatesIt() async throws {
        let fixture = FixtureCommands(list: #"[{"ref":"demo/finished","lastRunTime":"2026-10-19T12:00:00"},{"ref":"demo/running"}]"#)
        let cli = KaggleCLI(command: { args, timeout in try await fixture.run(args, timeout: timeout) }, pause: {})
        _ = try await cli.activitySnapshot()
        _ = try await cli.activitySnapshot()
        let references = await fixture.statusReferences
        XCTAssertEqual(references.filter { $0 == "demo/finished" }.count, 1)
        XCTAssertEqual(references.filter { $0 == "demo/running" }.count, 2)

        await fixture.setList(#"[{"ref":"demo/finished","lastRunTime":"2026-10-19T13:00:00"}]"#)
        await fixture.setStatus("QUEUED", for: "demo/finished")
        let snapshot = try await cli.activitySnapshot()
        XCTAssertEqual(snapshot.activeRuns.map(\.status), [.queued])
    }

    func testJustPushedNotebookIsQueuedAndOldDraftIsIgnored() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let recent = formatter.string(from: Date().addingTimeInterval(-120))
        let fixture = FixtureCommands(list: #"[{"ref":"demo/pushed","lastRunTime":"\#(recent)"},{"ref":"demo/draft"}]"#)
        await fixture.setStatus("NEW_SCRIPT", for: "demo/pushed")
        await fixture.setStatus("NEW_SCRIPT", for: "demo/draft")
        let cli = KaggleCLI(command: { args, timeout in try await fixture.run(args, timeout: timeout) }, pause: {})
        let snapshot = try await cli.activitySnapshot()
        XCTAssertEqual(snapshot.activeRuns.map(\.ref), ["demo/pushed"])
        XCTAssertEqual(snapshot.activeRuns.map(\.status), [.queued])
    }

    func testUnknownStatusIsNotCachedAsFinishedOrReportedIdle() async {
        let fixture = FixtureCommands(list: #"[{"ref":"demo/new-state"}]"#)
        await fixture.setStatus("UNKNOWN_NEW_STATE", for: "demo/new-state")
        let cli = KaggleCLI(command: { args, timeout in try await fixture.run(args, timeout: timeout) }, pause: {})
        do {
            _ = try await cli.activitySnapshot()
            XCTFail("Unknown states cannot safely mean idle")
        } catch {}
        await fixture.setStatus("RUNNING", for: "demo/new-state")
        do {
            let snapshot = try await cli.activitySnapshot()
            XCTAssertEqual(snapshot.activeRuns.count, 1)
        } catch { XCTFail("Unknown state must remain retryable") }
    }
}
