import Foundation
import XCTest
@testable import PuddleCore

final class WorkPortfolioTests: XCTestCase {
    func testDecisionRequiresRationaleAndAcceptsSourceBackedOutcome() throws {
        var decision = WorkDecision(); decision.title = "Choose launch date"; decision.status = .decided
        XCTAssertThrowsError(try decision.validated())
        decision.rationale = "The support team is available."; decision.options = "Monday or Tuesday"
        decision.evidence = [SourceReference(title: "Plan", url: URL(string: "https://example.com/plan")!)]
        XCTAssertNoThrow(try decision.validated())
        decision.evidence = [SourceReference(title: "Invalid", url: URL(string: "javascript:alert(1)")!)]
        XCTAssertThrowsError(try decision.validated())
    }
    func testVIPAttentionNeedsExplicitMatchingSenderAndSelectedProviderBriefIsTruthful() {
        var person = PersonContext(); person.name = "Alex"; person.email = "alex@example.com"; person.isVIP = true
        let message = MailMessage(id: "outlook", threadID: "thread", subject: "Launch", sender: "Alex <alex@example.com>", recipient: "me@example.com", date: Date(), snippet: "Follow up", body: "Discuss launch", labels: ["UNREAD"], provider: .outlook)
        XCTAssertEqual(MailAttention.assess(message, people: [person]).reasons.first, "VIP sender: Alex")
        person.isVIP = false; XCTAssertEqual(MailAttention.assess(message, people: [person]).reasons, ["Unread"])
        person.isVIP = true
        var state = AppSnapshot(); state.people = [person]; state.outlookMessages = [message]; state.settings.mailProvider = .outlook
        XCTAssertEqual(ExecutiveBrief(snapshot: state).flaggedMail.map(\.id), ["outlook"])
        state.settings.mailProvider = .google; XCTAssertTrue(ExecutiveBrief(snapshot: state).flaggedMail.isEmpty)
    }
    func testMeetingPreparationUsesCalendarScopedSeriesAcrossTitleChanges() throws {
        let data = Data(#"{"items":[{"id":"occurrence","summary":"New title","recurringEventId":"series","start":{"dateTime":"2027-01-01T09:00:00Z"}}]}"#.utf8)
        let event = try XCTUnwrap(GoogleCalendarClient.decode(data, calendarID: "team").first)
        XCTAssertEqual(event.seriesID, "team|series")
        let related = MeetingNote(title: "Previous title", calendarEventID: "previous", calendarSeriesID: "team|series")
        let unrelated = MeetingNote(title: "New title", calendarEventID: "other", calendarSeriesID: "different|series")
        var state = AppSnapshot(); state.meetings = [related, unrelated]
        XCTAssertEqual(MeetingPreparation(event: event, snapshot: state).notes.map(\.id), [related.id])
        let roundTrip = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(roundTrip.meetings.first?.calendarSeriesID, "team|series")
    }
    func testGlobalSearchCoversWorkRecordsAndSelectedMailCache() {
        var state = AppSnapshot(), project = WorkProject(), person = PersonContext(), decision = WorkDecision()
        project.title = "Orbital launch"; person.name = "Alex"; person.notes = "Orbital coordinator"; decision.title = "Orbital date"
        state.workProjects = [project]; state.people = [person]; state.workDecisions = [decision]
        let matches = WorkspaceSearch.search("orbital", in: state)
        XCTAssertEqual(Set(matches.map(\.kind)), [.project, .person, .decision])
        person.email = "invalid\r\naddress"; XCTAssertThrowsError(try person.validated())
    }
}
