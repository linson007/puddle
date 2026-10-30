#if DEBUG
import Foundation
import XCTest
import PuddleCore
@testable import Puddle

final class UITestWorkspaceTests: XCTestCase {
    @MainActor func testReopeningMarkedAcceptanceBundleWithoutArgumentsKeepsSyntheticStorage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ui-marked-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UITestWorkspace.makeStore(arguments: ["Puddle"], bundledWorkspace: directory.path)
        await store.start()
        XCTAssertFalse(store.mailConnected); XCTAssertFalse(store.calendarConnected)
        XCTAssertTrue(store.addTask(title: "Synthetic icon-launch task", dueAt: nil))
        let reopened = UITestWorkspace.makeStore(arguments: ["Puddle"], bundledWorkspace: directory.path)
        await reopened.start()
        XCTAssertEqual(reopened.state.tasks.map(\.title), ["Synthetic icon-launch task"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("fixture-secrets.json").path))
        store.suspendConnectionWork(); reopened.suspendConnectionWork()
    }
    func testAcceptanceMarkerRejectsInvalidPathsAndExplicitArgumentsTakePrecedence() throws {
        for marker: Any in ["", "/", "/tmp/..", "relative/workspace", "/tmp/bad\npath", 42] {
            XCTAssertThrowsError(try UITestWorkspace.launchArguments(["Puddle"], bundledWorkspace: marker), "Marker: \(String(reflecting: marker))")
        }
        let explicit = ["Puddle", "--ui-test-workspace", "/tmp/explicit-fixture"]
        XCTAssertEqual(try UITestWorkspace.launchArguments(explicit, bundledWorkspace: "/tmp/other-fixture"), explicit)
        XCTAssertEqual(try UITestWorkspace.launchArguments(["Puddle"], bundledWorkspace: nil), ["Puddle"])
    }
    @MainActor func testEmptyWorkspaceNeedsNoAccountOrModelToSaveWorkAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ui-empty-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let arguments = ["Puddle", "--ui-test-workspace", directory.path, "--ui-test-empty"]
        let store = UITestWorkspace.makeStore(arguments: arguments)
        await store.start()
        XCTAssertFalse(store.mailConnected); XCTAssertFalse(store.calendarConnected)
        XCTAssertNil(store.state.account); XCTAssertNil(store.state.outlookAccount); XCTAssertNil(store.splashModel)
        XCTAssertTrue(store.state.tasks.isEmpty); XCTAssertFalse(store.state.profile.configured)
        XCTAssertEqual(store.state.settings.splashAddress, "http://127.0.0.1:65534")
        XCTAssertTrue(store.addTask(title: "First launch commitment", dueAt: nil))
        let restarted = UITestWorkspace.makeStore(arguments: arguments)
        await restarted.start()
        XCTAssertEqual(restarted.state.tasks.map(\.title), ["First launch commitment"])
        XCTAssertFalse(restarted.mailConnected); XCTAssertFalse(restarted.calendarConnected)
        let secrets = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: directory.appendingPathComponent("fixture-secrets.json")))
        XCTAssertNil(secrets["google-tokens"]); XCTAssertNil(secrets["google-accounts"]); XCTAssertNil(secrets["microsoft-accounts"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("provider-journal.txt").path))
    }

    func testSyntheticProviderWritesStayInsideTheFixtureAndOtherHostsAreBlocked() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ui-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let http = UITestHTTP(directory: directory)
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/sendMail")!); request.httpMethod = "POST"
        let accepted = try await http.send(request); XCTAssertEqual(accepted.1.statusCode, 202)
        request.url = URL(string: "https://unrecognized.example/send")
        do { _ = try await http.send(request); XCTFail("A fixture request escaped to an external host") } catch {}
        let journal = try String(contentsOf: directory.appendingPathComponent("provider-journal.txt"), encoding: .utf8)
        XCTAssertEqual(journal, "POST graph.microsoft.com/v1.0/me/sendMail\n")
    }
}
#endif
