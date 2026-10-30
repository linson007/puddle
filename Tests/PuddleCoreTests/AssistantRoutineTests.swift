import Foundation
import XCTest
@testable import PuddleCore

final class AssistantRoutineTests: XCTestCase {
    func testNextFireRespectsWeekdaysAndTimezoneAndIsStrictlyFuture() throws {
        var routine = AssistantRoutine(); routine.timezone = "UTC"; routine.hour = 9; routine.weekdays = [2, 3, 4, 5, 6]
        let friday = AssistantDates.parse("2026-10-30T09:00:00Z")!
        XCTAssertEqual(routine.nextFire(after: friday), AssistantDates.parse("2026-11-02T09:00:00Z"))
        routine.weekdays = []; XCTAssertThrowsError(try routine.validated())
    }
    func testRestoredSchedulesAndInterruptedBrowserTasksNeverAutoRun() throws {
        var state = AppSnapshot(), routine = AssistantRoutine(); routine.enabled = true; routine.nextRunAt = .distantPast
        var job = BrowserErrand(goal: "Find a restaurant"); job.status = .running
        state.routines = [routine]; state.browserErrands = [job]
        state.routineRuns = [RoutineRun(routineID: routine.id, scheduledAt: .distantPast, status: .running)]
        let preview = try WorkspaceBackup.inspect(WorkspaceBackup.encode(state))
        let restored = WorkspaceBackup.merging(preview, into: AppSnapshot()).0
        XCTAssertFalse(restored.routines[0].enabled); XCTAssertNil(restored.routines[0].nextRunAt)
        XCTAssertEqual(restored.browserErrands[0].status, .paused); XCTAssertEqual(restored.routineRuns[0].status, .interrupted)
    }
}
