import XCTest
@testable import PuddleCore

final class MeetingSearchTests: XCTestCase {
    func testSearchMatchesAcrossFieldsWithAccentCaseAndWidthFolding() throws {
        var note = MeetingNote(title: "Café review"); note.participants = "Mira"; note.transcript = "Launch readiness"
        XCTAssertEqual(try MeetingSearch.results(notes: [note], query: "CAFE mira launch").map(\.id), [note.id])
        XCTAssertEqual(try MeetingSearch.results(notes: [note], query: "ＬＡＵＮＣＨ").count, 1)
        XCTAssertTrue(try MeetingSearch.results(notes: [note], query: "launch absent").isEmpty)
    }
    func testUnsavedDraftReplacesSavedSourceAndSnippetIncludesMatchNearEnd() throws {
        var note = MeetingNote(title: "Saved title"); note.transcript = "Old transcript"
        var draft = MeetingDraft(note); draft.title = "Draft title"; draft.transcript = String(repeating: "Earlier discussion. ", count: 100) + "Unique final decision"
        let result = try XCTUnwrap(MeetingSearch.results(notes: [note], drafts: [note.id: draft], query: "unique").first)
        XCTAssertEqual(result.title, "Draft title"); XCTAssertTrue(result.hasUnsavedChanges)
        XCTAssertTrue(result.snippet.contains("Unique final decision")); XCTAssertLessThanOrEqual(result.snippet.count, 181)
        XCTAssertTrue(try MeetingSearch.results(notes: [note], drafts: [note.id: draft], query: "Old transcript").isEmpty)
    }
    func testSummaryActionsSearchAndChronologicalOrdering() throws {
        var first = MeetingNote(title: "First"), second = MeetingNote(title: "Second")
        first.updatedAt = Date(timeIntervalSince1970: 10); second.updatedAt = Date(timeIntervalSince1970: 20)
        first.summary = MeetingSummary(model: "fixture", sourceDigest: "older", decisions: [MeetingExcerpt(quote: "Approve preview")], actions: [MeetingAction(quote: "Send report", owner: "Mira", timing: "Friday")])
        XCTAssertEqual(try MeetingSearch.results(notes: [first], query: "approve").first?.field, "Previous summary")
        XCTAssertEqual(try MeetingSearch.results(notes: [first], query: "Friday Mira").count, 1)
        XCTAssertEqual(try MeetingSearch.results(notes: [first, second], query: " ").map(\.id), [second.id, first.id])
        XCTAssertThrowsError(try MeetingSearch.results(notes: [first], query: String(repeating: "x", count: 201)))
    }
}
