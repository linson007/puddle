import Foundation
import XCTest
@testable import PuddleCore

enum BriefingRegressionFixture {
    static let now = AssistantDates.parse("2026-10-30T12:43:00+05:30")!
    static var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Kolkata")!; return value }
    static var snapshot: AppSnapshot {
        var value = AppSnapshot()
        value.tasks = [AssistantTask(title: "Alex will review the release checklist by Friday.")]
        value.calendarEvents = [CalendarEvent(id: "review", title: "UI test review", start: "2026-10-30T14:00:00+05:30", end: "2026-10-30T14:30:00+05:30")]
        return value
    }
    static var context: String { snapshot.executiveContext(now: now, mailConnected: false, calendarConnected: false, calendar: calendar) }
}

final class BriefingAnswerTests: XCTestCase {
    func testNativeCountdownRegressionUsesActualInstantsInsteadOfModelArithmetic() throws {
        let answer = try BriefingAnswer(toolResult: BriefingRegressionFixture.context)
            .render(modelResponse: "The 14:00 review is coming up in ~3h 17m.")
        XCTAssertTrue(answer.contains("Starts in 1h 17m"), answer)
        XCTAssertFalse(answer.contains("3h 17m"), answer)
        XCTAssertTrue(answer.contains("Friday, 2026-10-30 12:43"))
    }

    func testUndatedTaskTitleCannotBecomeAScheduledDeadline() throws {
        let answer = try BriefingAnswer(toolResult: BriefingRegressionFixture.context)
            .render(modelResponse: "Alex's release checklist is due today, Friday.")
        XCTAssertTrue(answer.contains("“Alex will review the release checklist by Friday.”"))
        XCTAssertTrue(answer.contains("No scheduled due date"), answer)
        XCTAssertTrue(answer.contains("Due later today: 0"), answer)
        XCTAssertFalse(answer.contains("is due today")); XCTAssertFalse(answer.contains("· Due today"))
        XCTAssertNil(BriefingRegressionFixture.snapshot.tasks.first?.dueAt)
    }

    func testRealDueTimestampControlsDeadlineEvenWhenTitleMentionsAnotherDay() throws {
        var state = BriefingRegressionFixture.snapshot
        state.tasks[0].dueAt = BriefingRegressionFixture.now.addingTimeInterval(3600)
        let answer = try BriefingAnswer(toolResult: state.executiveContext(now: BriefingRegressionFixture.now, mailConnected: false, calendarConnected: false, calendar: BriefingRegressionFixture.calendar))
            .render(modelResponse: #"{"next_steps":[]}"#)
        XCTAssertTrue(answer.contains("· Due today · Friday, 2026-10-30 13:43"), answer)
        XCTAssertTrue(answer.contains("Due later today: 1")); XCTAssertFalse(answer.contains("No scheduled due date"))
    }

    func testCountdownUsesElapsedTimeAcrossBothDSTTransitions() throws {
        let cases = [("2027-03-14T01:30:00-05:00", "2027-03-14T03:30:00-04:00"),
                     ("2027-11-07T01:30:00-04:00", "2027-11-07T01:30:00-05:00")]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        for (instant, start) in cases {
            let now = AssistantDates.parse(instant)!
            var state = AppSnapshot(); state.calendarEvents = [CalendarEvent(id: "dst", title: "DST event", start: start)]
            let answer = try BriefingAnswer(toolResult: state.executiveContext(now: now, mailConnected: false, calendarConnected: false, calendar: calendar))
                .render(modelResponse: #"{"next_steps":[]}"#)
            XCTAssertTrue(answer.contains("Starts in 1h"), answer)
            XCTAssertFalse(answer.contains("Starts in 2h"))
        }
    }

    func testAllDayOngoingEndedAndUnknownEndNeverReceiveAnInventedCountdown() throws {
        var state = AppSnapshot()
        state.calendarEvents = [
            CalendarEvent(id: "all", title: "All day", start: "2026-10-30", end: "2026-10-31"),
            CalendarEvent(id: "active", title: "Active", start: "2026-10-30T12:00:00+05:30", end: "2026-10-30T13:00:00+05:30"),
            CalendarEvent(id: "past", title: "Past", start: "2026-10-30T10:00:00+05:30", end: "2026-10-30T11:00:00+05:30"),
            CalendarEvent(id: "unknown", title: "Unknown", start: "2026-10-30T10:00:00+05:30")]
        let answer = try BriefingAnswer(toolResult: state.executiveContext(now: BriefingRegressionFixture.now, mailConnected: false, calendarConnected: false, calendar: BriefingRegressionFixture.calendar))
            .render(modelResponse: #"{"next_steps":[]}"#)
        XCTAssertTrue(answer.contains("· All day")); XCTAssertTrue(answer.contains("· In progress"))
        XCTAssertTrue(answer.contains("· Ended")); XCTAssertTrue(answer.contains("Started · End time unknown"))
        XCTAssertFalse(answer.contains("Starts in"))
    }

    func testOnlyValidatedSelectionIDsAffectNextStepsAndProseNeverAppears() throws {
        let state = BriefingRegressionFixture.snapshot
        let brief = try BriefingAnswer(toolResult: state.executiveContext(now: BriefingRegressionFixture.now, mailConnected: false, calendarConnected: false, calendar: BriefingRegressionFixture.calendar))
        let selection = "{\"next_steps\":[{\"kind\":\"review_task\",\"source_id\":\"\(state.tasks[0].id)\"}]}"
        let valid = brief.render(modelResponse: selection)
        XCTAssertTrue(valid.contains("Suggested next steps\n- Review"))
        for invalid in [#"{"next_steps":[{"kind":"review_task","source_id":"invented"}]}"#,
                        #"{"next_steps":[],"prose":"The task is due today."}"#,
                        #"{"next_steps":[{"kind":"prepare_event","source_id":"review","countdown":"3h 17m"}]}"#,
                        "The task is due today."] {
            let safe = brief.render(modelResponse: invalid)
            XCTAssertTrue(safe.contains("Suggested next steps from saved work"))
            XCTAssertFalse(safe.contains("The task is due today.")); XCTAssertFalse(safe.contains("3h 17m"))
        }
        XCTAssertThrowsError(try BriefingAnswer(toolResult: "Tool failed: disconnected"))
    }

    func testFutureSubminuteEventDoesNotShowZeroOrNegativeCountdown() throws {
        var state = BriefingRegressionFixture.snapshot
        state.calendarEvents = [CalendarEvent(id: "soon", title: "Soon", start: BriefingRegressionFixture.now.addingTimeInterval(30).ISO8601Format())]
        let answer = try BriefingAnswer(toolResult: state.executiveContext(now: BriefingRegressionFixture.now, mailConnected: false, calendarConnected: false, calendar: BriefingRegressionFixture.calendar))
            .render(modelResponse: #"{"next_steps":[]}"#)
        XCTAssertTrue(answer.contains("Starts in less than 1 min"), answer)
        XCTAssertFalse(answer.contains("Starts in 0"))
    }

    func testEndOfDaySelectionAsksAboutProgressInsteadOfAssumingCompletion() throws {
        let answer = try BriefingAnswer(toolResult: BriefingRegressionFixture.context)
            .render(modelResponse: #"{"next_steps":[{"kind":"ask_progress","source_id":""}]}"#)
        XCTAssertTrue(answer.contains("Which commitments did you complete"))
        XCTAssertTrue(answer.contains("No scheduled due date"))
        XCTAssertFalse(answer.contains("You completed"))
    }
}
