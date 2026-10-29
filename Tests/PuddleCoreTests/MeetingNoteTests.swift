import Foundation
import XCTest
@testable import PuddleCore

final class MeetingNoteTests: XCTestCase {
    func testMeetingNotesAndMetadataSurviveStateRoundTrip() throws {
        let note = MeetingNote(title: "Review", calendarEventID: "event", joinLink: try MeetingJoinLink("https://meet.google.com/abc-defg-hij"))
        var draft = MeetingDraft(note)
        draft.participants = "Mira, Li"; draft.agenda = "Review launch"; draft.notes = "Keep the first version small."
        draft.transcript = "Mira: We will review on Friday."
        var state = AppSnapshot(); state.meetings = [try draft.applying(to: note)]
        let restored = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.meetings, state.meetings)
        XCTAssertEqual(restored.meetings[0].id, note.id)
        XCTAssertEqual(restored.meetings[0].calendarEventID, "event")
        XCTAssertEqual(restored.meetings[0].joinLink?.provider, .googleMeet)
    }

    func testLegacyStateMigratesToMeetingCapableSchemaWithoutLosingChat() throws {
        let message = ChatLine(role: "user", content: "Existing conversation")
        let payload: [String: Any] = ["schemaVersion": 1, "chat": try JSONSerialization.jsonObject(with: JSONEncoder().encode([message]))]
        let state = try JSONDecoder().decode(AppSnapshot.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertGreaterThanOrEqual(AppSnapshot.currentSchemaVersion, 2)
        XCTAssertEqual(state.schemaVersion, AppSnapshot.currentSchemaVersion)
        XCTAssertTrue(state.meetings.isEmpty); XCTAssertEqual(state.chat.first?.content, message.content)
    }

    func testInvalidDraftCannotReplaceSavedNotes() {
        let note = MeetingNote(title: "Original")
        var draft = MeetingDraft(note); draft.title = "   "
        XCTAssertThrowsError(try draft.applying(to: note))
        draft.title = "Valid"; draft.transcript = String(repeating: "x", count: 200_001)
        XCTAssertThrowsError(try draft.applying(to: note))
        XCTAssertEqual(note.title, "Original"); XCTAssertTrue(note.transcript.isEmpty)
    }

    func testAllDayDateIsLocalAndMalformedDatesAreRejected() throws {
        let date = try XCTUnwrap(AssistantDates.calendarDate("2026-10-30"))
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        XCTAssertEqual(components.year, 2026); XCTAssertEqual(components.month, 10); XCTAssertEqual(components.day, 30)
        XCTAssertNil(AssistantDates.calendarDate("2026-02-30"))
        XCTAssertNil(AssistantDates.calendarDate("2026-10-30garbage"))
    }
}
