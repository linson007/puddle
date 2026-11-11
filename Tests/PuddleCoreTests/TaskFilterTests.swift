import Foundation
import XCTest
@testable import PuddleCore

final class TaskFilterTests: XCTestCase {
    func testTaskFiltersAgreeWithTodayAcrossTimezonesAndDeadlineBoundary() throws {
        let now = try XCTUnwrap(AssistantDates.parse("2026-11-11T23:30:00+05:30"))
        for zone in ["Asia/Kolkata", "America/New_York", "UTC"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            var waiting = AssistantTask(title: "Waiting", dueAt: now.addingTimeInterval(-1))
            waiting.workflow = .waiting; waiting.owner = "Alex"
            var completed = waiting; completed.id = UUID(); completed.completed = true
            var state = AppSnapshot()
            state.tasks = [waiting, completed, AssistantTask(title: "Exact deadline", dueAt: now),
                AssistantTask(title: "Next hour", dueAt: now.addingTimeInterval(3600)), AssistantTask(title: "Undated")]
            let brief = ExecutiveBrief(snapshot: state, now: now, calendar: calendar)
            func ids(_ filter: TaskFilter, at date: Date) -> Set<UUID> {
                Set(state.tasks.filter { filter.matches($0, now: date, calendar: calendar) }.map(\.id))
            }
            XCTAssertEqual(ids(.overdue, at: now), Set(brief.overdue.map(\.id)), zone)
            XCTAssertEqual(ids(.dueToday, at: now), Set(brief.dueToday.map(\.id)), zone)
            XCTAssertEqual(ids(.waiting, at: now), Set(brief.waiting.map(\.id)), zone)
            XCTAssertEqual(ids(.open, at: now).count, 4)
            XCTAssertEqual(ids(.completed, at: now), [completed.id])
            let deadline = state.tasks[2].id
            XCTAssertFalse(ids(.overdue, at: now).contains(deadline))
            XCTAssertTrue(ids(.overdue, at: now.addingTimeInterval(1)).contains(deadline))
        }
    }

    func testDueTodayMovesAcrossLocalMidnightAndDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let beforeMidnight = try XCTUnwrap(AssistantDates.parse("2026-10-31T23:59:59-04:00"))
        let due = try XCTUnwrap(AssistantDates.parse("2026-11-01T23:30:00-05:00"))
        let task = AssistantTask(title: "After the clock change", dueAt: due)
        XCTAssertFalse(TaskFilter.dueToday.matches(task, now: beforeMidnight, calendar: calendar))
        XCTAssertTrue(TaskFilter.dueToday.matches(task, now: beforeMidnight.addingTimeInterval(1), calendar: calendar))
        XCTAssertTrue(TaskFilter.overdue.matches(task, now: due.addingTimeInterval(1), calendar: calendar))
    }
}
