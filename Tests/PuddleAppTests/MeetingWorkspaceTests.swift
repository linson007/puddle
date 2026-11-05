import Foundation
import XCTest
import PuddleCore
@testable import Puddle

private final class MeetingDisk: SnapshotPersistence, @unchecked Sendable {
    var state = AppSnapshot()
    var failWrite = false
    func load() throws -> AppSnapshot { state }
    func save(_ state: AppSnapshot) throws { if failWrite { throw PuddleError("Fixture full disk") }; self.state = state }
}
private struct EmptyMeetingSecrets: SecretStore {
    func read(_ key: String) throws -> Data? { nil }
    func write(_ data: Data, key: String) throws {}
    func delete(_ key: String) throws {}
}
private struct MeetingFixtureTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = #"{"data":[{"id":"fixture"}]}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor private final class MeetingFixtureReminders: ReminderScheduling {
    func reconcile(tasks: [AssistantTask], enabled: Bool) async throws {}
}

@MainActor final class MeetingWorkspaceTests: XCTestCase {
    private func fixture(_ disk: MeetingDisk) -> PuddleStore {
        PuddleStore(cache: disk, secrets: EmptyMeetingSecrets(), transport: MeetingFixtureTransport(), reminderScheduler: MeetingFixtureReminders())
    }

    func testDraftSurvivesSelectionAndSavedNoteSurvivesRestart() async throws {
        let disk = MeetingDisk()
        let subject = fixture(disk); await subject.start()
        let result1 = await subject.createMeetingNote();         let firstID = try XCTUnwrap(result1)
        let first = try XCTUnwrap(subject.state.meetings.first)
        subject.meetingWorkspace.edit(first) { $0.title = "First review"; $0.notes = "Useful decisions"; $0.transcript = "A supplied transcript" }
        _ = await subject.createMeetingNote()
        XCTAssertEqual(subject.meetingWorkspace.draft(for: first).notes, "Useful decisions")
        let result2 = await subject.saveMeetingNote(firstID)
        XCTAssertTrue(result2)
        XCTAssertFalse(subject.meetingWorkspace.isDirty(try XCTUnwrap(subject.state.meetings.first { $0.id == firstID })))
        let restarted = fixture(disk); await restarted.start()
        XCTAssertEqual(restarted.state.meetings.count, 2)
        XCTAssertEqual(restarted.state.meetings.first { $0.id == firstID }?.transcript, "A supplied transcript")
    }

    func testFailedSaveAndDeleteRetainDraftAndSavedVersion() async throws {
        let disk = MeetingDisk()
        let subject = fixture(disk); await subject.start()
        let result3 = await subject.createMeetingNote()
        let id = try XCTUnwrap(result3), note = try XCTUnwrap(subject.state.meetings.first)
        subject.meetingWorkspace.edit(note) { $0.notes = "Do not lose this draft" }
        disk.failWrite = true
        let result4 = await subject.saveMeetingNote(id)
        XCTAssertFalse(result4)
        XCTAssertTrue(subject.state.meetings[0].notes.isEmpty)
        await subject.deleteMeetingNote(id)
        XCTAssertEqual(subject.state.meetings.count, 1)
        XCTAssertEqual(subject.meetingWorkspace.draft(for: note).notes, "Do not lose this draft")
        disk.failWrite = false
        let result5 = await subject.saveMeetingNote(id)
        XCTAssertTrue(result5)
        XCTAssertEqual(try disk.load().meetings[0].notes, "Do not lose this draft")
    }

    func testCalendarNoteIsReusedAndRetainsMeetingLink() async throws {
        let store = fixture(MeetingDisk()); await store.enterDemo()
        let event = CalendarEvent(id: "event", title: "Standup", start: "2026-10-30", meetingLinks: [try MeetingJoinLink("https://meet.google.com/abc-defg-hij")])
        let first = await store.createMeetingNote(event: event), second = await store.createMeetingNote(event: event)
        XCTAssertEqual(first, second); XCTAssertEqual(store.state.meetings.count, 1)
        XCTAssertEqual(store.state.meetings[0].joinLink?.provider, .googleMeet)
        await store.clearChat(); XCTAssertEqual(store.state.meetings.count, 1)
    }

    func testTranscriptImportRequiresExplicitApplyAndPreservesExistingDraftWhenAppending() async throws {
        let disk = MeetingDisk()
        let store = fixture(disk); await store.start()
        let result6 = await store.createMeetingNote()
        let id = try XCTUnwrap(result6), note = try XCTUnwrap(store.state.meetings.first)
        store.meetingWorkspace.edit(note) { $0.transcript = "Existing transcript"; $0.notes = "My own notes" }
        let result = try TranscriptImport.decode(Data("Imported transcript".utf8), filename: "fixture.txt")
        store.meetingWorkspace.pendingImport = PendingTranscriptImport(noteID: id, result: result)
        XCTAssertEqual(store.meetingWorkspace.draft(for: note).transcript, "Existing transcript")
        XCTAssertTrue(store.useImportedTranscript(append: true))
        XCTAssertEqual(store.meetingWorkspace.draft(for: note).transcript, "Existing transcript\n\nImported transcript")
        XCTAssertEqual(store.meetingWorkspace.draft(for: note).notes, "My own notes")
        XCTAssertTrue(try disk.load().meetings[0].transcript.isEmpty)
        let result7 = await store.saveMeetingNote(id)
        XCTAssertTrue(result7)
        XCTAssertTrue(try disk.load().meetings[0].transcript.contains("Imported transcript"))
    }

    func testOversizedAppendKeepsOriginalDraftAndImportPreview() async throws {
        let store = fixture(MeetingDisk()); await store.start()
        let result8 = await store.createMeetingNote()
        let id = try XCTUnwrap(result8), note = try XCTUnwrap(store.state.meetings.first)
        store.meetingWorkspace.edit(note) { $0.transcript = String(repeating: "x", count: 200_000) }
        let result = try TranscriptImport.decode(Data("extra".utf8), filename: "fixture.txt")
        store.meetingWorkspace.pendingImport = PendingTranscriptImport(noteID: id, result: result)
        XCTAssertFalse(store.useImportedTranscript(append: true))
        XCTAssertEqual(store.meetingWorkspace.draft(for: note).transcript.count, 200_000)
        XCTAssertNotNil(store.meetingWorkspace.pendingImport)
        XCTAssertTrue(store.useImportedTranscript(append: false))
        XCTAssertEqual(store.meetingWorkspace.draft(for: note).transcript, "extra")
    }

    func testSearchCancellationCannotPublishObsoleteMatchesOrDiscardDrafts() async throws {
        let workspace = MeetingWorkspace()
        var first = MeetingNote(title: "First"), second = MeetingNote(title: "Second")
        first.notes = "Old query"; second.notes = "Current query"
        workspace.edit(second) { $0.notes = "Unsaved current result" }
        workspace.selectedID = first.id
        workspace.searchQuery = "old"; workspace.updateSearch(notes: [first, second])
        workspace.searchQuery = "unsaved"; workspace.updateSearch(notes: [first, second])
        for _ in 0..<200 { if !workspace.isSearching { break }; try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertFalse(workspace.isSearching); XCTAssertEqual(workspace.searchResults.map(\.id), [second.id])
        XCTAssertTrue(workspace.isDirty(second)); XCTAssertEqual(workspace.selectedID, first.id)
        workspace.searchQuery = "old"; workspace.updateSearch(notes: [first, second]); let search = workspace.searchTask; workspace.reset()
        await search?.value
        XCTAssertTrue(workspace.searchResults.isEmpty); XCTAssertTrue(workspace.drafts.isEmpty)
    }
}
