import Foundation
import XCTest
@testable import Puddle
@testable import PuddleCore

private final class RoutineDisk: SnapshotPersistence, @unchecked Sendable {
    var snapshot = AppSnapshot()
    func load() throws -> AppSnapshot { snapshot }
    func save(_ next: AppSnapshot) throws { snapshot = next }
}
private final class RoutineSecrets: SecretStore, @unchecked Sendable {
    func read(_ key: String) throws -> Data? { nil }
    func write(_ data: Data, key: String) throws {}
    func delete(_ key: String) throws {}
}
private actor RoutineHTTP: HTTPTransport {
    var generations = 0
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: String
        if request.url?.path == "/v1/models" { body = #"{"data":[{"id":"fixture"}]}"# }
        else if request.httpMethod == "POST" { generations += 1; body = #"{"choices":[{"message":{"content":"Fixture daily review."},"finish_reason":"stop"}]}"# }
        else { body = "{}" }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor IncorrectBriefingHTTP: HTTPTransport {
    var generations = 0
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var object: [String: Any] = ["data": [["id": "fixture"]]]
        if request.url?.path == "/v1/chat/completions" {
            generations += 1
            let message: [String: Any]
            if generations == 1 {
                message = ["tool_calls": [["id": "brief", "type": "function", "function": ["name": "read_executive_brief", "arguments": "{}"]]]]
            } else {
                message = ["content": "The 14:00 review is in ~3h 17m. Alex's release checklist is due today, Friday."]
            }
            object = ["choices": [["message": message, "finish_reason": generations == 1 ? "tool_calls" : "stop"]]]
        }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor final class RoutineWorkflowTests: XCTestCase {
    private final class Scheduler: ReminderScheduling { func reconcile(tasks: [AssistantTask], enabled: Bool) async throws {} }
    func testDefaultRoutinePersistsCorrectCountdownAndNeverSchedulesAnUndatedTitle() async throws {
        let now = AssistantDates.parse("2026-10-30T12:43:00+05:30")!
        let disk = RoutineDisk(), http = IncorrectBriefingHTTP(), routine = AssistantRoutine()
        disk.snapshot.routines = [routine]
        disk.snapshot.tasks = [AssistantTask(title: "Alex will review the release checklist by Friday.")]
        disk.snapshot.calendarEvents = [CalendarEvent(id: "review", title: "UI test review", start: "2026-10-30T14:00:00+05:30", end: "2026-10-30T14:30:00+05:30")]
        let store = PuddleStore(cache: disk, secrets: RoutineSecrets(), transport: http, reminderScheduler: Scheduler())
        await store.start(); store.runRoutineNow(routine.id, now: now)
        for _ in 0..<200 where store.routineTask != nil { try await Task.sleep(for: .milliseconds(5)) }
        let run = try XCTUnwrap(store.state.routineRuns.first)
        XCTAssertEqual(run.status, .completed)
        XCTAssertTrue(run.result.contains("Starts in 1h 17m"), run.result)
        XCTAssertTrue(run.result.contains("No scheduled due date"), run.result)
        XCTAssertFalse(run.result.contains("3h 17m")); XCTAssertFalse(run.result.contains("is due today"))
        XCTAssertEqual(disk.snapshot.routineRuns.first?.result, run.result)
        XCTAssertNil(disk.snapshot.tasks.first?.dueAt)
        let restarted = PuddleStore(cache: disk, secrets: RoutineSecrets(), transport: RoutineHTTP(), reminderScheduler: Scheduler())
        await restarted.start()
        XCTAssertEqual(restarted.state.routineRuns.first?.result, run.result)
        XCTAssertNil(restarted.state.tasks.first?.dueAt)
        let count = await http.generations; XCTAssertEqual(count, 2)
    }

    func testDueRoutineAdvancesBeforeExecutionAndDoesNotRunTwice() async throws {
        let disk = RoutineDisk(), http = RoutineHTTP(), now = Date()
        var routine = AssistantRoutine(); routine.enabled = true; routine.nextRunAt = now.addingTimeInterval(-60); disk.snapshot.routines = [routine]
        let store = PuddleStore(cache: disk, secrets: RoutineSecrets(), transport: http, reminderScheduler: Scheduler())
        await store.start(); store.processRoutines(now: now); store.processRoutines(now: now)
        for _ in 0..<200 where store.routineTask != nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.state.routineRuns.count, 1); XCTAssertEqual(store.state.routineRuns.first?.status, .completed)
        XCTAssertGreaterThan(store.state.routines[0].nextRunAt ?? .distantPast, now)
        let count = await http.generations; XCTAssertEqual(count, 1)
    }
    func testOldMissedRoutineIsRecordedWithoutModelGeneration() async {
        let disk = RoutineDisk(), http = RoutineHTTP(), now = Date()
        var routine = AssistantRoutine(); routine.enabled = true; routine.nextRunAt = now.addingTimeInterval(-86400); disk.snapshot.routines = [routine]
        let store = PuddleStore(cache: disk, secrets: RoutineSecrets(), transport: http, reminderScheduler: Scheduler())
        await store.start(); store.processRoutines(now: now)
        XCTAssertEqual(store.state.routineRuns.first?.status, .missed)
        let count = await http.generations; XCTAssertEqual(count, 0)
    }
    func testRoutineCannotUseWriteTools() async {
        let store = PuddleStore(cache: RoutineDisk(), secrets: RoutineSecrets(), transport: RoutineHTTP(), reminderScheduler: Scheduler())
        await store.start()
        do { _ = try await store.readRoutineTool(AgentToolCall(name: AgentTool.remind.rawValue, arguments: "{}")); XCTFail("Write tool accepted") } catch {}
        XCTAssertTrue(store.state.tasks.isEmpty)
    }
}
