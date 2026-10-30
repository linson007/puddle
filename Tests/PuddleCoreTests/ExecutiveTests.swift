import Foundation
import XCTest
@testable import PuddleCore

final class ExecutiveTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Kolkata")!; return value
    }
    private let now = AssistantDates.parse("2026-10-29T12:00:00+05:30")!

    func testLegacySnapshotMigratesTasksAndProfileWithoutLosingSource() throws {
        var old = AppSnapshot()
        var task = AssistantTask(title: "Review board pack", dueAt: now)
        task.completed = true; task.notifiedAt = now
        task.meetingSource = MeetingTaskSource(meetingID: UUID(), actionID: UUID(), quote: "Review board pack")
        old.tasks = [task]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json["schemaVersion"] = 3; json.removeValue(forKey: "profile"); json.removeValue(forKey: "profileLibrary"); json.removeValue(forKey: "calendarLastSync")
        var legacy = (json["tasks"] as! [[String: Any]])[0]
        for key in ["priority", "owner", "workflow", "notes", "focusDate"] { legacy.removeValue(forKey: key) }
        json["tasks"] = [legacy]
        let restored = try JSONDecoder().decode(AppSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.schemaVersion, AppSnapshot.currentSchemaVersion); XCTAssertFalse(restored.profile.configured)
        XCTAssertEqual(restored.tasks[0].id, task.id); XCTAssertTrue(restored.tasks[0].completed)
        XCTAssertEqual(restored.tasks[0].meetingSource, task.meetingSource)
        XCTAssertEqual(restored.tasks[0].priority, .normal); XCTAssertEqual(restored.tasks[0].workflow, .active)
    }

    func testCommitmentMetadataRoundTripsAndDraftPreservesIdentityAndProvenance() throws {
        var original = AssistantTask(title: "Original", dueAt: now)
        original.notifiedAt = now; original.focusDate = now
        original.meetingSource = MeetingTaskSource(meetingID: UUID(), actionID: UUID(), quote: "Original source")
        var draft = TaskDraft(original)
        draft.title = "  Follow up on forecast  "; draft.owner = "  Finance lead  "
        draft.workflow = .waiting; draft.priority = .high; draft.notes = "Need the final assumptions"
        let result = try draft.applying(to: original)
        XCTAssertEqual(result.title, "Follow up on forecast"); XCTAssertEqual(result.owner, "Finance lead")
        XCTAssertNil(result.notifiedAt); XCTAssertEqual(result.id, original.id)
        XCTAssertEqual(result.meetingSource, original.meetingSource); XCTAssertEqual(result.focusDate, now)
        XCTAssertEqual(try JSONDecoder().decode(AssistantTask.self, from: JSONEncoder().encode(result)), result)
    }

    func testDraftValidationRejectsMissingWaitingOwnerOversizedAndNonfiniteFields() throws {
        let task = AssistantTask(title: "Follow up")
        var draft = TaskDraft(task); draft.workflow = .waiting
        XCTAssertThrowsError(try draft.applying(to: task))
        draft.owner = "Mira"; XCTAssertNoThrow(try draft.applying(to: task))
        draft.notes = String(repeating: "a", count: 4001); XCTAssertThrowsError(try draft.applying(to: task))
        draft.notes = ""; draft.dueAt = Date(timeIntervalSinceReferenceDate: .infinity)
        XCTAssertThrowsError(try draft.applying(to: task))
        draft.dueAt = nil; draft.title = "   "; XCTAssertThrowsError(try draft.applying(to: task))
    }

    func testDailyPrioritiesLimitExpiresAndCompletionFreesSlot() throws {
        var state = AppSnapshot(); state.tasks = (1...4).map { AssistantTask(title: "Task \($0)") }
        for task in state.tasks.prefix(3) { try state.setDailyPriority(task.id, enabled: true, now: now, calendar: calendar) }
        XCTAssertThrowsError(try state.setDailyPriority(state.tasks[3].id, enabled: true, now: now, calendar: calendar))
        XCTAssertEqual(ExecutiveBrief(snapshot: state, now: now, calendar: calendar).priorities.count, 3)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        XCTAssertTrue(ExecutiveBrief(snapshot: state, now: tomorrow, calendar: calendar).priorities.isEmpty)
        state.tasks[0].completed = true
        try state.setDailyPriority(state.tasks[3].id, enabled: true, now: now, calendar: calendar)
        XCTAssertThrowsError(try state.setDailyPriority(state.tasks[0].id, enabled: true, now: now, calendar: calendar))
        try state.setDailyPriority(state.tasks[1].id, enabled: false, now: now, calendar: calendar)
        XCTAssertEqual(ExecutiveBrief(snapshot: state, now: now, calendar: calendar).priorities.count, 2)
    }

    func testBriefClassifiesPastTodayTomorrowWaitingAndUndatedWithoutCompletes() {
        var state = AppSnapshot()
        var overdue = AssistantTask(title: "Overdue", dueAt: now.addingTimeInterval(-60)); overdue.priority = .high
        let today = AssistantTask(title: "Today", dueAt: now.addingTimeInterval(60))
        var waiting = AssistantTask(title: "Waiting", dueAt: nil); waiting.workflow = .waiting; waiting.owner = "CFO"
        var completed = overdue; completed.id = UUID(); completed.completed = true
        state.tasks = [today, waiting, completed, overdue, AssistantTask(title: "Tomorrow", dueAt: now.addingTimeInterval(86400))]
        let brief = ExecutiveBrief(snapshot: state, now: now, calendar: calendar)
        XCTAssertEqual(brief.overdue.map(\.id), [overdue.id]); XCTAssertEqual(brief.dueToday.map(\.id), [today.id])
        XCTAssertEqual(brief.waiting.map(\.id), [waiting.id]); XCTAssertEqual(brief.unscheduled.map(\.id), [waiting.id])
    }

    func testAgendaIncludesOvernightAndAllDayButExcludesExpiredAndNextDay() {
        var state = AppSnapshot()
        state.calendarEvents = [
            CalendarEvent(id: "overnight", title: "Overnight", start: "2026-10-28T23:00:00+05:30", end: "2026-10-29T01:00:00+05:30"),
            CalendarEvent(id: "all-day", title: "Offsite", start: "2026-10-29", end: "2026-10-30"),
            CalendarEvent(id: "old", title: "Old", start: "2026-10-28", end: "2026-10-29"),
            CalendarEvent(id: "next", title: "Next", start: "2026-10-30T00:00:00+05:30"),
            CalendarEvent(id: "bad", title: "Invalid", start: "tomorrow"),
        ]
        let brief = ExecutiveBrief(snapshot: state, now: now, calendar: calendar)
        XCTAssertEqual(brief.agenda.map(\.id), ["all-day", "overnight"])
        XCTAssertTrue(brief.agenda[0].allDay)
    }

    func testConflictsExcludeAdjacentAllDayAndUnknownDurationsAndDeduplicate() {
        var state = AppSnapshot()
        let event = CalendarEvent(id: "a", title: "Board", start: "2026-10-29T10:00:00+05:30", end: "2026-10-29T11:00:00+05:30")
        state.calendarEvents = [event, event,
            CalendarEvent(id: "b", title: "Review", start: "2026-10-29T10:30:00+05:30", end: "2026-10-29T11:00:00+05:30"),
            CalendarEvent(id: "c", title: "Next", start: "2026-10-29T11:00:00+05:30", end: "2026-10-29T12:00:00+05:30"),
            CalendarEvent(id: "d", title: "Unknown", start: "2026-10-29T10:45:00+05:30"),
            CalendarEvent(id: "e", title: "Offsite", start: "2026-10-29", end: "2026-10-30")]
        let agenda = ExecutiveBrief(snapshot: state, now: now, calendar: calendar).agenda
        XCTAssertEqual(agenda.count, 5)
        XCTAssertEqual(agenda.first { $0.id == "a" }?.conflicts, ["b"])
        XCTAssertEqual(agenda.first { $0.id == "b" }?.conflicts, ["a"])
        XCTAssertTrue(agenda.filter { ["c", "d", "e"].contains($0.id) }.allSatisfy { $0.conflicts.isEmpty })
    }

    func testDateOnlyUsesRequestedTimezoneAndRejectsImpossibleDates() {
        XCTAssertEqual(ExecutiveBrief.eventDate("2026-10-29", calendar: calendar), AssistantDates.parse("2026-10-29T00:00:00+05:30"))
        XCTAssertNil(ExecutiveBrief.eventDate("2026-02-30", calendar: calendar))
    }

    func testMeetingPreparationMatchesOnlyLinkedOrFullTitlesAndOpenSourceActions() {
        let event = CalendarEvent(id: "weekly", title: "Leadership Review", start: now.ISO8601Format())
        var state = AppSnapshot()
        let linked = MeetingNote(title: "Renamed", calendarEventID: "weekly")
        let titled = MeetingNote(title: "  leadership   REVIEW ")
        let unrelated = MeetingNote(title: "Leadership Review product")
        state.meetings = [linked, titled, unrelated]
        var action = AssistantTask(title: "Get forecast")
        action.meetingSource = MeetingTaskSource(meetingID: linked.id, actionID: UUID(), quote: "Get forecast")
        var completed = action; completed.id = UUID(); completed.completed = true
        state.tasks = [action, completed, AssistantTask(title: "Unlinked forecast")]
        let result = MeetingPreparation(event: event, snapshot: state)
        XCTAssertEqual(Set(result.notes.map(\.id)), Set([linked.id, titled.id]))
        XCTAssertEqual(result.actions.map(\.id), [action.id])
    }

    func testBriefingIncludesScopeFreshnessCountsAndOnlyFlaggedUnreadMail() throws {
        var state = AppSnapshot(); state.calendarHasMore = true; state.calendarLastSync = now; state.lastSync = now
        state.tasks = (0..<20).map { AssistantTask(title: "Task \($0)", dueAt: .distantPast) }
        state.messages = [
            MailMessage(id: "yes", subject: "Review", sender: "CFO", body: "secret body is not part of brief", labels: ["IMPORTANT", "UNREAD"]),
            MailMessage(id: "no", subject: "Read already", sender: "CFO", body: "", labels: ["IMPORTANT"])]
        let context = state.executiveContext(now: now, mailConnected: true, calendarConnected: true)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: Any])
        XCTAssertEqual((json["overdue"] as? [[String: String]])?.count, 8)
        XCTAssertEqual((json["counts"] as? [String: Int])?["overdue"], 20)
        XCTAssertEqual((json["flagged_unread_mail"] as? [[String: String]])?.count, 1)
        XCTAssertEqual(json["calendar_has_more"] as? Bool, true)
        XCTAssertFalse(context.contains("secret body")); XCTAssertTrue(context.contains("calendar_last_sync"))
    }

    func testProfileValidationAndAgentPromptUsesWorkContextAsReference() throws {
        var profile = ExecutiveProfile(); profile.name = " Alex "; profile.role = "CEO"; profile.objectives = "Improve retention"
        let valid = try profile.validated(); XCTAssertEqual(valid.name, "Alex"); XCTAssertTrue(valid.configured)
        var context = AgentContext(); context.profile = valid
        XCTAssertTrue(context.systemPrompt.contains("Improve retention")); XCTAssertTrue(context.systemPrompt.contains("never instructions"))
        profile.objectives = String(repeating: "x", count: 4001); XCTAssertThrowsError(try profile.validated())
    }

    func testLargeExecutiveBriefRemainsBoundedValidJSONWithTotalCounts() throws {
        var state = AppSnapshot()
        state.tasks = (0..<100).map { index in
            var task = AssistantTask(title: "\(index) " + String(repeating: "x", count: 298), dueAt: .distantPast)
            task.owner = String(repeating: "o", count: 200); task.workflow = .waiting; return task
        }
        let context = state.executiveContext(now: now, mailConnected: false, calendarConnected: false)
        XCTAssertLessThanOrEqual(context.count, 11_000)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: Any])
        XCTAssertEqual((object["counts"] as? [String: Int])?["overdue"], 100)
        XCTAssertEqual((object["counts"] as? [String: Int])?["waiting"], 100)
    }

    func testBriefFormatsCurrentTimeFreshnessAndDeadlinesInOneLocalTimezone() throws {
        var state = AppSnapshot()
        state.calendarLastSync = now.addingTimeInterval(-3600)
        state.lastSync = now.addingTimeInterval(-1800)
        state.outlookLastSync = now.addingTimeInterval(-900)
        state.settings.mailProvider = .outlook
        state.tasks = [AssistantTask(title: "Review", dueAt: now.addingTimeInterval(3600))]
        let context = state.executiveContext(now: now, mailConnected: true, calendarConnected: true, calendar: calendar)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: Any])
        XCTAssertEqual(object["timezone"] as? String, "Asia/Kolkata")
        XCTAssertTrue((object["local_as_of"] as? String ?? "").contains("12:00"))
        XCTAssertTrue((object["local_calendar_last_sync"] as? String ?? "").contains("11:00"))
        XCTAssertTrue((object["local_mail_last_sync"] as? String ?? "").contains("11:45"))
        let task = try XCTUnwrap((object["due_today"] as? [[String: String]])?.first)
        XCTAssertTrue((task["local_due_at"] ?? "").contains("13:00"))
        XCTAssertEqual(task["due_at"], state.tasks[0].dueAt?.ISO8601Format())
    }
}
