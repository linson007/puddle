import Foundation
import XCTest
import PuddleCore
@testable import Puddle

private final class SummaryDisk: SnapshotPersistence, @unchecked Sendable {
    var state = AppSnapshot(); var failWrite = false
    func load() throws -> AppSnapshot { state }
    func save(_ state: AppSnapshot) throws { if failWrite { throw PuddleError("Fixture full disk") }; self.state = state }
}
private struct SummarySecrets: SecretStore {
    func read(_ key: String) throws -> Data? { nil }
    func write(_ data: Data, key: String) throws {}
    func delete(_ key: String) throws {}
}
private struct SummaryFixtureHTTP: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = #"{"data":[{"id":"fixture"}]}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor private final class SummaryReminders: ReminderScheduling {
    func reconcile(tasks: [AssistantTask], enabled: Bool) async throws {}
}
private actor ControlledSummary: MeetingSummarizing {
    var pending: [(MeetingNote, CheckedContinuation<MeetingSummary, Never>)] = []
    var calls = 0
    func summarize(note: MeetingNote, contextTokens: Int, progress: @escaping @Sendable (Int, Int) async -> Void) async throws -> MeetingSummary {
        await progress(1, 1); calls += 1
        return await withCheckedContinuation { pending.append((note, $0)) }
    }
    func finishFirst() {
        let (note, continuation) = pending.removeFirst()
        continuation.resume(returning: MeetingSummary(model: "fixture", sourceDigest: MeetingSummary.digest(notes: note.notes, transcript: note.transcript),
            keyPoints: [MeetingExcerpt(quote: note.transcript)], actions: [MeetingAction(quote: note.transcript)]))
    }
}

@MainActor final class MeetingSummaryWorkflowTests: XCTestCase {
    private func fixture(_ disk: SummaryDisk, _ service: ControlledSummary) -> PuddleStore {
        PuddleStore(cache: disk, secrets: SummarySecrets(), transport: SummaryFixtureHTTP(), reminderScheduler: SummaryReminders(), meetingSummarizer: service)
    }
    private func note(_ store: PuddleStore) async throws -> UUID {
        let result1 = await store.createMeetingNote()
        let id = try XCTUnwrap(result1), note = try XCTUnwrap(store.state.meetings.first)
        store.meetingWorkspace.edit(note) { $0.transcript = "Mira: We agreed to postpone launch."; $0.notes = "My own note" }
        let result2 = await store.saveMeetingNote(id)
        XCTAssertTrue(result2); return id
    }
    private func started(_ service: ControlledSummary, count: Int = 1) async throws {
        for _ in 0..<200 {
            if await service.calls >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Summary did not start")
    }
    func testSummaryPersistsSeparatelyWithoutChangingNotesTasksOrMemories() async throws {
        let disk = SummaryDisk(), service = ControlledSummary()
        let store = fixture(disk, service); await store.start(); let id = try await note(store)
        store.generateMeetingSummary(id); let task = store.meetingSummaryTask
        try await started(service); await service.finishFirst(); await task?.value
        XCTAssertEqual(store.state.meetings[0].summary?.keyPoints.first?.quote, "Mira: We agreed to postpone launch.")
        XCTAssertEqual(store.state.meetings[0].notes, "My own note")
        XCTAssertTrue(store.state.tasks.isEmpty); XCTAssertTrue(store.state.memories.isEmpty)
        XCTAssertEqual(try disk.load().meetings[0].summary, store.state.meetings[0].summary)
        XCTAssertNil(store.meetingWorkspace.summarizingID)
    }
    func testUnsavedSourceChangesRejectLateSummary() async throws {
        let disk = SummaryDisk(), service = ControlledSummary()
        let store = fixture(disk, service); await store.start(); let id = try await note(store)
        store.generateMeetingSummary(id); let task = store.meetingSummaryTask
        try await started(service)
        store.meetingWorkspace.edit(store.state.meetings[0]) { $0.transcript = "Corrected: no decision yet." }
        await service.finishFirst(); await task?.value
        XCTAssertNil(store.state.meetings[0].summary)
        XCTAssertTrue(store.meetingWorkspace.summaryError?.contains("changed") == true)
        XCTAssertEqual(store.meetingWorkspace.draft(for: store.state.meetings[0]).transcript, "Corrected: no decision yet.")
        store.generateMeetingSummary(id)
        XCTAssertTrue(store.meetingWorkspace.summaryError?.contains("Save") == true)
        let calls = await service.calls; XCTAssertEqual(calls, 1)
    }
    func testCancellationAndDeletingNoteIgnoreNonCooperativeLateCompletion() async throws {
        let service = ControlledSummary()
        let subject = fixture(SummaryDisk(), service); await subject.start(); let id = try await note(subject)
        subject.generateMeetingSummary(id); let task = subject.meetingSummaryTask
        try await started(service); await subject.deleteMeetingNote(id)
        await service.finishFirst(); await task?.value
        XCTAssertTrue(subject.state.meetings.isEmpty); XCTAssertNil(subject.meetingWorkspace.summarizingID)
    }
    func testFailedSummarySaveRetainsPreviousSummaryAndSource() async throws {
        let disk = SummaryDisk(), service = ControlledSummary()
        let store = fixture(disk, service); await store.start(); let id = try await note(store)
        let previous = MeetingSummary(model: "previous", sourceDigest: "old")
        try await store.commit { $0.meetings[0].summary = previous }
        store.generateMeetingSummary(id); let task = store.meetingSummaryTask
        try await started(service); disk.failWrite = true
        await service.finishFirst(); await task?.value
        XCTAssertEqual(store.state.meetings[0].summary, previous)
        XCTAssertEqual(try disk.load().meetings[0].summary, previous)
        XCTAssertTrue(store.meetingWorkspace.summaryError?.contains("full disk") == true)
    }
    func testEnteringDemoClearsDraftsAndCancelsSummaryFromRealState() async throws {
        let service = ControlledSummary(), disk = SummaryDisk()
        let store = fixture(disk, service); await store.start(); let id = try await note(store)
        store.generateMeetingSummary(id); let task = store.meetingSummaryTask
        try await started(service)
        store.meetingWorkspace.edit(store.state.meetings[0]) { $0.title = "Uncommitted" }
        await store.enterDemo(); await service.finishFirst(); await task?.value
        XCTAssertTrue(store.meetingWorkspace.drafts.isEmpty); XCTAssertTrue(store.state.meetings.isEmpty)
        XCTAssertNil(try disk.load().meetings[0].summary)
    }

    private func savedAction(_ store: PuddleStore) async throws -> (UUID, MeetingAction) {
        let id = try await note(store), note = try XCTUnwrap(store.state.meetings.first)
        let action = MeetingAction(quote: note.transcript)
        try await store.commit { $0.meetings[0].summary = MeetingSummary(model: "fixture", sourceDigest: MeetingSummary.digest(notes: note.notes, transcript: note.transcript), actions: [action]) }
        return (id, action)
    }
    func testReviewedActionCreatesOneTaskWithSourceAndSurvivesRegeneration() async throws {
        let disk = SummaryDisk(), service = ControlledSummary()
        let store = fixture(disk, service); await store.start()
        let (id, action) = try await savedAction(store)
        let result3 = await store.createTaskFromMeeting(noteID: id, actionID: action.id, title: "Review launch timing", dueAt: nil);         let taskID = try XCTUnwrap(result3)
        let result4 = await store.createTaskFromMeeting(noteID: id, actionID: action.id, title: "Repeated click", dueAt: nil)
        XCTAssertEqual(result4, taskID)
        XCTAssertEqual(store.state.tasks.count, 1); XCTAssertNil(store.state.tasks[0].dueAt)
        XCTAssertEqual(store.state.tasks[0].meetingSource?.quote, action.quote)
        store.generateMeetingSummary(id); let task = store.meetingSummaryTask
        try await started(service); await service.finishFirst(); await task?.value
        let newAction = try XCTUnwrap(store.state.meetings[0].summary?.actions.first)
        XCTAssertNotEqual(newAction.id, action.id); XCTAssertEqual(newAction.taskID, taskID)
        let result5 = await store.createTaskFromMeeting(noteID: id, actionID: newAction.id, title: "Again", dueAt: nil)
        XCTAssertEqual(result5, taskID)
        XCTAssertEqual(store.state.tasks.count, 1)
        let restored = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(disk.state))
        XCTAssertEqual(restored.tasks[0].meetingSource, store.state.tasks[0].meetingSource)
    }
    func testFailedTaskSaveIsAtomicAndCanBeRetried() async throws {
        let disk = SummaryDisk()
        let subject = fixture(disk, ControlledSummary()); await subject.start()
        let (id, action) = try await savedAction(subject); disk.failWrite = true
        let result6 = await subject.createTaskFromMeeting(noteID: id, actionID: action.id, title: "Follow up", dueAt: nil)
        XCTAssertNil(result6)
        XCTAssertTrue(subject.state.tasks.isEmpty); XCTAssertNil(subject.state.meetings[0].summary?.actions[0].taskID)
        disk.failWrite = false
        let result7 = await subject.createTaskFromMeeting(noteID: id, actionID: action.id, title: "Follow up", dueAt: nil)
        XCTAssertNotNil(result7)
        XCTAssertEqual(subject.state.tasks.count, 1)
    }
    func testChangedSourceInvalidTitleAndPastDateCannotCreateTask() async throws {
        let store = fixture(SummaryDisk(), ControlledSummary()); await store.start()
        let (id, action) = try await savedAction(store)
        let result8 = await store.createTaskFromMeeting(noteID: id, actionID: action.id, title: " ", dueAt: nil)
        XCTAssertNil(result8)
        let result9 = await store.createTaskFromMeeting(noteID: id, actionID: action.id, title: "Valid", dueAt: Date.distantPast)
        XCTAssertNil(result9)
        store.meetingWorkspace.edit(store.state.meetings[0]) { $0.transcript = "Corrected source" }
        let result10 = await store.createTaskFromMeeting(noteID: id, actionID: action.id, title: "Valid", dueAt: nil)
        XCTAssertNil(result10)
        XCTAssertTrue(store.state.tasks.isEmpty)
    }
    func testDeletingNoteRetainsTaskSourceAndDeletingTaskAllowsExplicitRecreation() async throws {
        let store = fixture(SummaryDisk(), ControlledSummary()); await store.start()
        let (id, action) = try await savedAction(store)
        let result11 = await store.createTaskFromMeeting(noteID: id, actionID: action.id, title: "Follow up", dueAt: nil);         let first = try XCTUnwrap(result11)
        await store.deleteTask(first)
        let result12 = await store.createTaskFromMeeting(noteID: id, actionID: action.id, title: "Follow up again", dueAt: nil);         let second = try XCTUnwrap(result12)
        XCTAssertNotEqual(first, second)
        await store.deleteMeetingNote(id)
        XCTAssertEqual(store.state.tasks.count, 1); XCTAssertEqual(store.state.tasks[0].meetingSource?.quote, action.quote)
    }
}
