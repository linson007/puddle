import Foundation
import XCTest
@testable import PuddleCore

final class CalendarContextTests: XCTestCase {
    func testCalendarToolSuppliesPreformattedLocalTimesWithoutChangingRawDates() throws {
        let event = CalendarEvent(id: "fixture", title: "Planning", start: "2026-10-30T04:30:00Z", end: "2026-10-30T05:00:00Z")
        let text = try CalendarContext.encode(CalendarPage(events: [event]), timezone: TimeZone(identifier: "Asia/Kolkata")!)
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        let first = (object["events"] as! [[String: Any]])[0]
        XCTAssertEqual(first["start"] as? String, event.start)
        XCTAssertTrue((first["local_start"] as? String ?? "").contains("10:00"))
        XCTAssertTrue((first["local_end"] as? String ?? "").contains("10:30"))
        XCTAssertEqual(object["timezone"] as? String, "Asia/Kolkata")
        XCTAssertEqual(try JSONDecoder().decode(CalendarPage.self, from: Data(text.utf8)).events, [event])
    }
    func testAllDayAndUnknownTimesAreNotConvertedToGuessedClockTimes() {
        XCTAssertEqual(CalendarContext.localTime("2026-10-30"), "2026-10-30 (all day)")
        XCTAssertEqual(CalendarContext.localTime(""), "unknown")
    }
    func testLocalWeekdayIsExplicitAndFollowsTimezoneDateRollover() {
        let time = CalendarContext.localTime("2026-10-29T23:00:00Z", timezone: TimeZone(identifier: "Asia/Kolkata")!)
        XCTAssertTrue(time.hasPrefix("Friday, 2026-10-30 04:30"), time)
    }
}
