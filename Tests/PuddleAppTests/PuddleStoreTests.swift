import Foundation
import XCTest
import PuddleCore
@testable import Puddle

private final class TestSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    func write(_ data: Data, key: String) throws { lock.withLock { values[key] = data } }
    func delete(_ key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

private final class TestDisk: SnapshotPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var saved = AppSnapshot()
    var failRead = false
    var failWrite = false
    func load() throws -> AppSnapshot {
        try lock.withLock { if failRead { throw PuddleError("Corrupt fixture") }; return saved }
    }
    func save(_ state: AppSnapshot) throws {
        try lock.withLock { if failWrite { throw PuddleError("Full disk fixture") }; saved = state }
    }
}

private actor AppTransport: HTTPTransport {
    var delay = false
    var requests: [URLRequest] = []
    func setDelay() { delay = true }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body: String
        switch request.url!.path {
        case "/ready": body = #"{"status":"ready"}"#
        case "/v1/models": body = #"{"data":[{"id":"fixture","max_model_len":8192}]}"#
        default:
            if delay { try? await Task.sleep(for: .milliseconds(100)) }
            body = #"{"choices":[{"message":{"content":"Fixture answer"},"finish_reason":"stop"}]}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor ReminderModel: HTTPTransport {
    var generations = 0
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body: String
        switch request.url!.path {
        case "/ready": body = #"{"status":"ready"}"#
        case "/v1/models": body = #"{"data":[{"id":"fixture","max_model_len":8192}]}"#
        default:
            generations += 1
            if generations == 2 { throw PuddleError("Fixture interrupted after action") }
            if generations == 1 || generations == 3 {
                body = #"{"choices":[{"message":{"content":"","tool_calls":[{"id":"reminder-call","type":"function","function":{"name":"create_reminder","arguments":"{\"title\":\"Take a break\",\"due_at\":\"\"}"}}]},"finish_reason":"tool_calls"}]}"#
            } else { body = #"{"choices":[{"message":{"content":"The task remains saved."},"finish_reason":"stop"}]}"# }
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor private final class TestScheduler: ReminderScheduling {
    var tasks: [AssistantTask] = []
    func reconcile(tasks: [AssistantTask], enabled: Bool) async throws { self.tasks = tasks }
}

@MainActor final class PuddleStoreTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Fixture operation did not complete")
    }
    private func fixture(_ disk: TestDisk = TestDisk()) -> (PuddleStore, TestDisk, AppTransport, TestScheduler) {
        let transport = AppTransport(), scheduler = TestScheduler()
        let store = PuddleStore(cache: disk, secrets: TestSecrets(), transport: transport, reminderScheduler: scheduler)
        return (store, disk, transport, scheduler)
    }

    func testFailedLoadBlocksWritesAndRetryRecovers() async throws {
        let disk = TestDisk(); disk.failRead = true
        let (store, _, _, _) = fixture(disk)
        await store.start()
        XCTAssertFalse(store.storageAvailable)
        store.addTask(title: "Must not be acknowledged", dueAt: nil)
        XCTAssertTrue(store.state.tasks.isEmpty)
        disk.failRead = false
        await store.retryLoadingState()
        XCTAssertTrue(store.storageAvailable)
        store.addTask(title: "Saved", dueAt: nil)
        XCTAssertEqual(try disk.load().tasks.first?.title, "Saved")
    }

    func testWriteFailureRollsBackMemoryTaskAndReminderDelivery() async throws {
        let (store, disk, _, _) = fixture()
        await store.start()
        store.addTask(title: "Due", dueAt: .distantPast)
        disk.failWrite = true
        store.processReminders()
        XCTAssertNil(store.state.tasks[0].notifiedAt)
        XCTAssertTrue(store.state.chat.isEmpty)
        store.saveMemory(title: "Name", content: "Mira")
        XCTAssertTrue(store.state.memories.isEmpty)
        disk.failWrite = false
        store.processReminders(); store.processReminders()
        XCTAssertEqual(store.state.chat.count, 1)
        XCTAssertNotNil(try disk.load().tasks[0].notifiedAt)
    }

    func testNewConversationRejectsLateReplyEvenWhenTransportIgnoresCancellation() async throws {
        let (store, _, transport, _) = fixture()
        await store.start(); await transport.setDelay()
        store.ask("Explain binary search")
        while await transport.requests.filter({ $0.url?.path == "/v1/chat/completions" }).isEmpty { await Task.yield() }
        store.clearChat()
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertTrue(store.state.chat.isEmpty)
        XCTAssertEqual(store.state.conversations.count, 1)
        XCTAssertTrue(store.streamingReply.isEmpty)
        XCTAssertFalse(store.isThinking)
    }

    func testLearningToggleRemovesToolAndTaskEditingPersists() async throws {
        let (store, disk, _, scheduler) = fixture()
        await store.start()
        store.setAutomaticLearning(false)
        XCTAssertFalse(store.availableTools.contains(.remember))
        store.addTask(title: "Original", dueAt: nil)
        let id = store.state.tasks[0].id
        store.updateTask(id, title: "Changed", dueAt: Date().addingTimeInterval(600))
        store.snoozeTask(id)
        XCTAssertEqual(try disk.load().tasks[0].title, "Changed")
        XCTAssertNotNil(store.state.tasks[0].dueAt)
        store.deleteTask(id)
        await Task.yield()
        XCTAssertTrue(try disk.load().tasks.isEmpty)
        XCTAssertTrue(scheduler.tasks.isEmpty)
    }

    func testRetryAfterCreatedReminderCannotDuplicateActionAndRetainsDueMessages() async throws {
        let model = ReminderModel(), disk = TestDisk()
        let store = PuddleStore(cache: disk, secrets: TestSecrets(), transport: model, reminderScheduler: TestScheduler())
        await store.start()
        store.ask("Remind me to take a break")
        await waitUntil { store.pendingApproval != nil }
        store.resolveApproval(true)
        await waitUntil { !store.isThinking }
        XCTAssertEqual(store.state.tasks.count, 1)
        XCTAssertEqual(store.state.chat.first?.receipts?.first?.status, "completed")
        store.addTask(title: "Unrelated due reminder", dueAt: .distantPast); store.processReminders()
        store.retryLastQuestion()
        await waitUntil { !store.isThinking }
        XCTAssertEqual(store.state.tasks.count, 2)
        XCTAssertNil(store.pendingApproval)
        XCTAssertTrue(store.state.chat.contains { $0.kind == "reminder" })
        let requests = await model.requests.filter { $0.url?.path == "/v1/chat/completions" }
        let retryRequest = try XCTUnwrap(requests.dropFirst(2).first)
        let retry = try JSONSerialization.jsonObject(with: XCTUnwrap(retryRequest.httpBody)) as! [String: Any]
        let names = (retry["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertFalse(names.contains(AgentTool.remind.rawValue))
    }

    func testStoppingApprovalCreatesNoTask() async throws {
        let store = PuddleStore(cache: TestDisk(), secrets: TestSecrets(), transport: ReminderModel(), reminderScheduler: TestScheduler())
        await store.start(); store.ask("Remind me to take a break")
        await waitUntil { store.pendingApproval != nil }
        store.stopAI()
        await Task.yield()
        XCTAssertNil(store.pendingApproval); XCTAssertTrue(store.state.tasks.isEmpty)
    }

    func testDemoRetryAlsoPreservesReminderWithoutNewApproval() async throws {
        let (store, _, _, _) = fixture()
        store.enterDemo()
        store.ask("Remind me to take a break")
        await waitUntil { store.pendingApproval != nil }
        store.resolveApproval(true)
        await waitUntil { !store.isThinking }
        XCTAssertEqual(store.state.tasks.count, 2)
        store.retryLastQuestion()
        await waitUntil { !store.isThinking }
        XCTAssertNil(store.pendingApproval)
        XCTAssertEqual(store.state.tasks.count, 2)
        XCTAssertTrue(store.state.chat.last?.content.contains("already saved") == true)
    }

    func testSavedActiveChatIsInHistoryBeforeNewConversationAndAfterRestart() async throws {
        let disk = TestDisk()
        var saved = AppSnapshot()
        saved.chat = [ChatLine(role: "user", content: "My saved discussion"), ChatLine(role: "assistant", content: "Previous answer")]
        try disk.save(saved)
        let (store, _, _, _) = fixture(disk)
        await store.start()
        XCTAssertEqual(store.state.conversationHistory.count, 1)
        XCTAssertTrue(store.state.conversations.isEmpty)
        let id = store.state.currentConversationID
        store.section = .history; store.openConversation(id)
        XCTAssertEqual(store.section, .chat)
        XCTAssertEqual(store.state.chat, saved.chat)
        XCTAssertTrue(store.state.conversations.isEmpty)
        store.clearChat()
        XCTAssertEqual(store.state.conversationHistory.first?.id, id)
        store.openConversation(id)
        let (restarted, _, _, _) = fixture(disk)
        await restarted.start()
        XCTAssertEqual(restarted.state.currentConversationID, id)
        XCTAssertEqual(restarted.state.conversationHistory.count, 1)
        XCTAssertEqual(restarted.state.chat, saved.chat)
    }

    func testOpeningCurrentFromHistoryDoesNotCancelReply() async throws {
        let (store, _, transport, _) = fixture()
        await store.start(); await transport.setDelay()
        store.ask("Explain binary search")
        store.section = .history
        let id = try XCTUnwrap(store.state.conversationHistory.first?.id)
        store.openConversation(id)
        XCTAssertTrue(store.isThinking)
        XCTAssertEqual(store.section, .chat)
        await waitUntil { !store.isThinking }
        XCTAssertEqual(store.state.chat.last?.content, "Fixture answer")
        XCTAssertTrue(store.state.conversations.isEmpty)
    }
}
