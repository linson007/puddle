import Foundation
import XCTest
import PuddleCore
@testable import Puddle

private final class TaskChatDisk: SnapshotPersistence, @unchecked Sendable {
    var state = AppSnapshot(); var failWrite = false
    func load() throws -> AppSnapshot { state }
    func save(_ snapshot: AppSnapshot) throws { if failWrite { throw PuddleError("Fixture disk full") }; state = snapshot }
}
private struct TaskChatSecrets: SecretStore {
    func read(_ key: String) throws -> Data? { nil }
    func write(_ data: Data, key: String) throws {}
    func delete(_ key: String) throws {}
}
@MainActor private final class TaskChatReminders: ReminderScheduling { func reconcile(tasks: [AssistantTask], enabled: Bool) async throws {} }
private actor TaskChatHTTP: HTTPTransport {
    let taskID: UUID
    init(_ id: UUID) { taskID = id }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let object: [String: Any]
        if request.url!.path == "/ready" { object = [:] }
        else if request.url!.path == "/v1/models" { object = ["data": [["id": "fixture"]]] }
        else {
            let input = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = input["messages"] as! [[String: Any]]
            if messages.last?["role"] as? String == "tool" { object = ["choices": [["message": ["content": "Reviewed change processed."], "finish_reason": "stop"]]] }
            else {
                let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["task_id": taskID.uuidString, "operation": "complete", "value": ""]), as: UTF8.self)
                object = ["choices": [["message": ["tool_calls": [["id": "complete-fixture", "type": "function", "function": ["name": "update_task", "arguments": arguments]]]], "finish_reason": "tool_calls"]]]
            }
        }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor final class TaskChatWorkflowTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }; XCTFail("Task fixture timed out")
    }
    func testCompletionWaitsForReviewAndRejectsTaskChangedDuringReview() async throws {
        let disk = TaskChatDisk(), task = AssistantTask(title: "Review launch")
        disk.state.tasks = [task]; disk.state.settings.automaticallyLearn = false
        let store = PuddleStore(cache: disk, secrets: TaskChatSecrets(), transport: TaskChatHTTP(task.id), reminderScheduler: TaskChatReminders())
        await store.start(); store.ask("Complete Review launch")
        try await wait { store.pendingApproval != nil }
        XCTAssertFalse(store.state.tasks[0].completed)
        store.updateTask(task.id, title: "Changed while reviewing", dueAt: nil)
        store.resolveApproval(true); try await wait { !store.isThinking }
        XCTAssertFalse(store.state.tasks[0].completed); XCTAssertEqual(store.state.tasks[0].title, "Changed while reviewing")
        store.suspendConnectionWork()
    }
    func testReviewedCompletionAndRecurringSuccessorAreSavedTogether() async throws {
        let disk = TaskChatDisk(); var task = AssistantTask(title: "Daily review", dueAt: Date().addingTimeInterval(60))
        task.repetition = TaskRepetition(frequency: .daily, dueAt: task.dueAt!)
        disk.state.tasks = [task]; disk.state.settings.automaticallyLearn = false
        let store = PuddleStore(cache: disk, secrets: TaskChatSecrets(), transport: TaskChatHTTP(task.id), reminderScheduler: TaskChatReminders())
        await store.start(); store.ask("Complete Daily review")
        try await wait { store.pendingApproval != nil }; store.resolveApproval(true); try await wait { !store.isThinking }
        XCTAssertTrue(disk.state.tasks[0].completed); XCTAssertEqual(disk.state.tasks.count, 2)
        XCTAssertEqual(disk.state.chat.first(where: { $0.role == "user" })?.receipts?.first(where: { $0.tool == "update_task" })?.status, "completed")
        store.toggleTask(task.id); store.toggleTask(task.id); XCTAssertEqual(disk.state.tasks.count, 2)
        store.suspendConnectionWork()
    }
}
