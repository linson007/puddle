import Foundation
import XCTest
@testable import PuddleCore

final class TaskRepetitionTests: XCTestCase {
    private func date(_ text: String) -> Date { AssistantDates.parse(text)! }
    func testMonthlyScheduleClampsFebruaryAndReturnsToOriginalDayInMarch() throws {
        let january = date("2027-01-31T09:00:00Z"), zone = TimeZone(secondsFromGMT: 0)!
        let repetition = TaskRepetition(frequency: .monthly, dueAt: january, timezone: zone)
        let february = try repetition.next(after: january, now: january)
        XCTAssertEqual(february, date("2027-02-28T09:00:00Z"))
        XCTAssertEqual(try repetition.next(after: february, now: february), date("2027-03-31T09:00:00Z"))
    }
    func testDailyScheduleKeepsLocalTimeAcrossDSTAndSkipsMissedDates() throws {
        let due = date("2027-03-13T09:00:00-05:00")
        let repetition = TaskRepetition(frequency: .daily, dueAt: due, timezone: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(try repetition.next(after: due, now: due), date("2027-03-14T09:00:00-04:00"))
        XCTAssertEqual(try repetition.next(after: due, now: date("2027-03-16T10:00:00-04:00")), date("2027-03-17T09:00:00-04:00"))
    }
    func testCompletionIsAtomicAndReopeningCannotCreateDuplicateSuccessors() throws {
        let due = date("2027-01-01T09:00:00Z")
        var task = AssistantTask(title: "Weekly review", dueAt: due)
        task.repetition = TaskRepetition(frequency: .weekly, dueAt: due, timezone: TimeZone(secondsFromGMT: 0)!)
        task.projectID = UUID(); task.owner = "Alex"; task.focusDate = due
        var snapshot = AppSnapshot(); snapshot.tasks = [task]
        try snapshot.setTaskCompleted(task.id, completed: true, now: due)
        XCTAssertEqual(snapshot.tasks.count, 2); XCTAssertEqual(snapshot.tasks[0].nextOccurrenceID, snapshot.tasks[1].id)
        XCTAssertEqual(snapshot.tasks[1].projectID, task.projectID); XCTAssertEqual(snapshot.tasks[1].owner, "Alex")
        XCTAssertNil(snapshot.tasks[1].focusDate); XCTAssertEqual(snapshot.tasks[1].dueAt, date("2027-01-08T09:00:00Z"))
        snapshot = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(snapshot))
        try snapshot.setTaskCompleted(task.id, completed: false, now: due)
        try snapshot.setTaskCompleted(task.id, completed: true, now: due)
        XCTAssertEqual(snapshot.tasks.count, 2)
    }
    func testRepeatingTaskRequiresDueDateAndEditingPreservesMonthlyAnchor() throws {
        let due = date("2027-01-31T09:00:00Z")
        var task = AssistantTask(title: "Review", dueAt: due)
        task.repetition = TaskRepetition(frequency: .monthly, dueAt: due, timezone: TimeZone(secondsFromGMT: 0)!)
        var draft = TaskDraft(task); draft.title = "Updated review"
        XCTAssertEqual(try draft.applying(to: task).repetition, task.repetition)
        draft.dueAt = nil; XCTAssertThrowsError(try draft.applying(to: task))
    }
}
