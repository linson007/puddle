import Foundation
import XCTest
@testable import PuddleCore

final class CalendarPlanningTests: XCTestCase {
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }
    private func date(_ value: String) -> Date { AssistantDates.parse(value)! }
    func testAvailabilityBuffersEventsAndBlocksUnknownDurations() {
        let day = date("2026-11-02T00:00:00Z")
        let event = CalendarEvent(id: "busy", title: "Busy", start: "2026-11-02T09:00:00Z", end: "2026-11-02T10:00:00Z")
        let slots = CalendarAvailability.slots(events: [event], from: day, days: 1, now: day, calendar: calendar)
        XCTAssertEqual(slots.first?.start, date("2026-11-02T10:15:00Z"))
        let unknown = CalendarEvent(id: "unknown", title: "Unknown", start: "2026-11-02T12:00:00Z")
        XCTAssertTrue(CalendarAvailability.slots(events: [unknown], from: day, days: 1, now: day, calendar: calendar).isEmpty)
    }
    func testAllDayEndIsExclusiveAndPastSlotsAreExcluded() {
        let day = date("2026-11-02T00:00:00Z")
        let event = CalendarEvent(id: "all", title: "Away", start: "2026-11-02", end: "2026-11-03")
        let slots = CalendarAvailability.slots(events: [event], from: day, days: 2, now: day, calendar: calendar)
        XCTAssertEqual(slots.first?.start, date("2026-11-03T09:00:00Z"))
    }
    func testTimelineSeparatesOverlapsAndClipsOvernightEvents() {
        let events = [CalendarEvent(id: "overnight", title: "Night", start: "2026-11-01T23:00:00Z", end: "2026-11-02T01:00:00Z"),
            CalendarEvent(id: "overlap", title: "Overlap", start: "2026-11-02T00:30:00Z", end: "2026-11-02T02:00:00Z"),
            CalendarEvent(id: "later", title: "Later", start: "2026-11-02T09:00:00Z", end: "2026-11-02T10:00:00Z")]
        let layout = CalendarTimeline.placements(events: events, day: date("2026-11-02T00:00:00Z"), calendar: calendar)
        XCTAssertEqual(layout[0].startMinute, 0); XCTAssertEqual(layout[0].durationMinutes, 60)
        XCTAssertEqual(layout[0].columns, 2); XCTAssertEqual(layout[1].columns, 2)
        XCTAssertNotEqual(layout[0].column, layout[1].column); XCTAssertEqual(layout[2].columns, 1)
    }
    func testAllDayBusyDatesUseTheRequestedCalendarTimezone() {
        // A date-only event has no UTC offset. Interpret it in the calendar being
        // planned, even when this Mac uses another timezone.
        for zone in ["Pacific/Honolulu", "Pacific/Kiritimati"] {
            var local = Calendar(identifier: .gregorian); local.timeZone = TimeZone(identifier: zone)!
            let day = local.date(from: DateComponents(year: 2026, month: 11, day: 2))!
            let event = CalendarEvent(id: "away", title: "Away", start: "2026-11-02", end: "2026-11-03")
            let slots = CalendarAvailability.slots(events: [event], from: day, days: 2, now: day, calendar: local)
            XCTAssertFalse(slots.isEmpty)
            XCTAssertTrue(slots.allSatisfy { local.component(.day, from: $0.start) == 3 }, zone)
            XCTAssertEqual(local.component(.hour, from: slots[0].start), 9, zone)
        }
    }
    func testWorkHoursRemainWallClockHoursOnAWeekdayDSTTransition() {
        // Cairo advances at midnight on Friday, which is a workday in this
        // calendar. Adding nine elapsed hours to midnight would produce 10:00.
        var local = Calendar(identifier: .gregorian); local.timeZone = TimeZone(identifier: "Africa/Cairo")!
        let day = local.date(from: DateComponents(year: 2027, month: 4, day: 30))!
        let slots = CalendarAvailability.slots(events: [], from: day, days: 1, startHour: 9, endHour: 10, durationMinutes: 60, bufferMinutes: 0, now: day, calendar: local)
        XCTAssertEqual(slots.count, 1)
        if let slot = slots.first {
            XCTAssertEqual(local.component(.hour, from: slot.start), 9)
            XCTAssertEqual(local.component(.hour, from: slot.end), 10)
        }
    }
}
