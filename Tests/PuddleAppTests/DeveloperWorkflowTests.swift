import Foundation
import XCTest
import PuddleCore
@testable import Puddle

private final class DeveloperDisk: SnapshotPersistence, @unchecked Sendable {
    var state = AppSnapshot()
    var failWrite = false
    func load() throws -> AppSnapshot { state }
    func save(_ value: AppSnapshot) throws { if failWrite { throw PuddleError("Fixture disk full") }; state = value }
}
private struct DeveloperSecrets: SecretStore {
    func read(_ key: String) throws -> Data? { nil }
    func write(_ data: Data, key: String) throws {}
    func delete(_ key: String) throws {}
}
@MainActor private final class DeveloperReminders: ReminderScheduling {
    func reconcile(tasks: [AssistantTask], enabled: Bool) async throws {}
}
private actor DeveloperModel: HTTPTransport {
    var requests: [URLRequest] = []
    var calls = 0
    let path: String
    init(path: String = "Main.swift") { self.path = path }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body: [String: Any]
        switch request.url!.path {
        case "/ready": body = ["status": "ready"]
        case "/v1/models": body = ["data": [["id": "fixture", "max_model_len": 32768]]]
        default:
            calls += 1
            if calls == 1 {
                body = ["choices": [["message": ["tool_calls": [["id": "read-source", "type": "function", "function": ["name": "read_project_file", "arguments": ["path": path, "start_line": 1]]]]], "finish_reason": "tool_calls"]]]
            } else { body = ["choices": [["message": ["content": "Main.swift:2 contains the greeting."], "finish_reason": "stop"]]] }
        }
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor final class DeveloperWorkflowTests: XCTestCase {
    private func fixture(_ disk: DeveloperDisk = DeveloperDisk(), model: DeveloperModel = DeveloperModel()) -> PuddleStore {
        PuddleStore(cache: disk, secrets: DeveloperSecrets(), transport: model, reminderScheduler: DeveloperReminders())
    }
    private func project(_ name: String = "Project") throws -> DeveloperProject {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("puddle-app-project-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("// fixture\nlet greeting = \"hello\"\n".utf8).write(to: root.appendingPathComponent("Main.swift"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return DeveloperProject(name: name, path: root.path)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Fixture did not finish")
    }
    func testToolsRequireDeveloperRoleAndExplicitProjectSelection() async throws {
        let store = fixture(); await store.start()
        let selected = try project()
        XCTAssertTrue(store.saveDeveloperProject(selected, isNew: true))
        XCTAssertFalse(store.availableTools.contains(.projectRead))
        store.chooseDeveloperProfile()
        XCTAssertTrue(store.availableTools.contains(.projectRead)); XCTAssertTrue(store.availableTools.contains(.developerWorkspace))
        XCTAssertTrue(store.selectDeveloperProject(nil))
        XCTAssertFalse(store.availableTools.contains(.projectRead)); XCTAssertTrue(store.availableTools.contains(.developerWorkspace))
        store.enterDemo(); store.chooseDeveloperProfile()
        XCTAssertFalse(store.availableTools.contains(.projectRead))
    }
    func testProjectAndSessionPersistAndFailedSavesKeepDraft() async throws {
        let disk = DeveloperDisk(), store = fixture(disk); await store.start()
        let selected = try project(); XCTAssertTrue(store.saveDeveloperProject(selected, isNew: true))
        let id = try XCTUnwrap(store.createDevelopmentSession(kind: .debug))
        let saved = try XCTUnwrap(store.state.developmentSessions.first)
        store.developerWorkspace.edit(saved) { $0.problem = "A reproducible failure"; $0.observed = "Timeout" }
        disk.failWrite = true
        XCTAssertFalse(store.saveDevelopmentSession(store.developerWorkspace.draft(saved)))
        XCTAssertEqual(store.developerWorkspace.draft(saved).observed, "Timeout")
        XCTAssertTrue(store.state.developmentSessions[0].observed.isEmpty)
        disk.failWrite = false
        XCTAssertTrue(store.saveDevelopmentSession(store.developerWorkspace.draft(saved)))
        let restarted = fixture(disk); await restarted.start()
        XCTAssertEqual(restarted.state.activeDeveloperProjectID, selected.id)
        XCTAssertEqual(restarted.state.developmentSessions.first { $0.id == id }?.observed, "Timeout")
        let moved = try project("Moved")
        let reconnected = DeveloperProject(id: selected.id, name: selected.name, path: moved.path)
        XCTAssertFalse(restarted.saveDeveloperProject(reconnected))
        XCTAssertTrue(restarted.saveDeveloperProject(reconnected, reconnecting: true))
        XCTAssertEqual(restarted.state.activeDeveloperProject?.path, moved.path)
        XCTAssertEqual(restarted.state.developmentSessions.first { $0.id == id }?.projectID, selected.id)
    }
    func testRemovingConnectionPreservesNotesAndUncommittedDraftAndRejectsStaleProjectEditor() async throws {
        let disk = DeveloperDisk(), store = fixture(disk); await store.start()
        let selected = try project(); store.saveDeveloperProject(selected, isNew: true)
        _ = store.createDevelopmentSession(kind: .debug)
        let saved = try XCTUnwrap(store.state.developmentSessions.first)
        store.developerWorkspace.edit(saved) { $0.findings = "Unsaved evidence" }
        store.removeDeveloperProject(selected.id)
        XCTAssertTrue(store.state.developerProjects.isEmpty); XCTAssertNil(store.state.developmentSessions[0].projectID)
        XCTAssertEqual(store.state.developmentSessions[0].projectName, selected.name)
        XCTAssertEqual(store.developerWorkspace.draft(saved).findings, "Unsaved evidence")
        XCTAssertNil(store.developerWorkspace.draft(saved).projectID)
        XCTAssertFalse(store.saveDeveloperProject(selected)); XCTAssertTrue(store.state.developerProjects.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: selected.path))
    }
    func testFailedRemovalAndSelectionDoNotRevokeSavedConnectionOrLoseSessionDraft() async throws {
        let disk = DeveloperDisk(), store = fixture(disk); await store.start()
        let selected = try project(); store.saveDeveloperProject(selected, isNew: true)
        disk.failWrite = true
        XCTAssertFalse(store.selectDeveloperProject(nil)); store.removeDeveloperProject(selected.id)
        XCTAssertEqual(store.state.activeDeveloperProjectID, selected.id); XCTAssertEqual(store.state.developerProjects.count, 1)
    }
    func testSourceToolRoundTripIncludesLinesReferencesAndNoAccountCalls() async throws {
        let disk = DeveloperDisk(), model = DeveloperModel(), store = fixture(disk, model: model); await store.start()
        let selected = try project(); store.saveDeveloperProject(selected, isNew: true); store.chooseDeveloperProfile()
        store.ask("Please inspect Main.swift and cite the greeting's line.")
        try await wait { !store.isThinking }
        XCTAssertEqual(store.state.chat.last?.content, "Main.swift:2 contains the greeting.")
        let receipt = try XCTUnwrap(store.state.chat.first(where: { $0.role == "user" })?.receipts?.first)
        XCTAssertEqual(receipt.tool, "read_project_file"); XCTAssertEqual(receipt.status, "completed")
        XCTAssertEqual(receipt.references.first?.title, "Main.swift:1")
        let requests = await model.requests
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "127.0.0.1" })
        let text = String(decoding: try XCTUnwrap(requests.last?.httpBody), as: UTF8.self)
        XCTAssertTrue(text.contains("greeting")); XCTAssertTrue(text.contains("2: let"))
    }
    func testToolTraversalFailureProducesFailedReceiptAndNeverReturnsOutsideContents() async throws {
        let disk = DeveloperDisk(), model = DeveloperModel(path: "../outside.txt"), store = fixture(disk, model: model); await store.start()
        store.saveDeveloperProject(try project(), isNew: true); store.chooseDeveloperProfile()
        store.ask("Read a source file")
        try await wait { !store.isThinking }
        let receipts = store.state.chat.first(where: { $0.role == "user" })?.receipts ?? []
        XCTAssertEqual(receipts.first?.status, "failed"); XCTAssertTrue(receipts.first?.references.isEmpty == true)
        let requests = await model.requests
        XCTAssertTrue(String(decoding: try XCTUnwrap(requests.last?.httpBody), as: UTF8.self).contains("Tool failed"))
    }
    func testLatestInspectionWinsAndProjectSwitchKeepsOtherDrafts() async throws {
        let store = fixture(); await store.start()
        let first = try project("First"), second = try project("Second")
        store.saveDeveloperProject(first, isNew: true)
        let id = try XCTUnwrap(store.createDevelopmentSession(kind: .debug)), saved = store.state.developmentSessions[0]
        store.developerWorkspace.edit(saved) { $0.findings = "Preserve across project switches" }
        store.developerWorkspace.inspect(.search("old"), project: first)
        store.saveDeveloperProject(second, isNew: true)
        XCTAssertNil(store.developerWorkspace.selectedSessionID)
        store.developerWorkspace.inspect(.read("Main.swift", 1), project: second)
        try await wait { !store.developerWorkspace.isInspecting }
        if case .excerpt(let value) = store.developerWorkspace.inspection { XCTAssertTrue(value.text.contains("greeting")) }
        else { XCTFail("Expected current read result") }
        XCTAssertEqual(store.developerWorkspace.drafts[id]?.findings, "Preserve across project switches")
    }
}
