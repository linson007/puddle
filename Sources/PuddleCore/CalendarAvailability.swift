import Foundation

public struct AvailableTimeSlot: Identifiable, Sendable {
    public var id: Date { start }
    public let start: Date
    public let end: Date
}
public enum CalendarAvailability {
    /// Candidates within the supplied calendar scope. An event without an end blocks its entire day.
    public static func slots(events: [CalendarEvent], from date: Date, days: Int = 7, startHour: Int = 9, endHour: Int = 17,
                             durationMinutes: Int = 30, bufferMinutes: Int = 15, now: Date = Date(), calendar: Calendar = .current) -> [AvailableTimeSlot] {
        guard startHour >= 0, endHour <= 24, endHour > startHour, (15...480).contains(durationMinutes) else { return [] }
        var results: [AvailableTimeSlot] = []
        for offset in 0..<max(1, min(days, 42)) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: date)),
                  !calendar.isDateInWeekend(day),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
                  let begin = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: day),
                  let finish = endHour == 24 ? nextDay : calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: day) else { continue }
            let busy: [(Date, Date)] = events.compactMap { event in
                guard let start = AssistantDates.calendarDate(event.start, timezone: calendar.timeZone) else { return nil }
                let end = AssistantDates.calendarDate(event.end, timezone: calendar.timeZone)
                if end == nil || end! <= start {
                    return start >= day && start < nextDay ? (day, nextDay) : nil
                }
                let buffer = event.start.count == 10 ? 0 : Double(max(0, bufferMinutes)) * 60
                return (start.addingTimeInterval(-buffer), end!.addingTimeInterval(buffer))
            }
            var cursor = begin
            while cursor.addingTimeInterval(Double(durationMinutes) * 60) <= finish {
                let end = cursor.addingTimeInterval(Double(durationMinutes) * 60)
                if cursor >= now, !busy.contains(where: { $0.0 < end && $0.1 > cursor }) {
                    results.append(AvailableTimeSlot(start: cursor, end: end))
                    if results.count >= 12 { return results }
                }
                cursor = cursor.addingTimeInterval(15 * 60)
            }
        }
        return results
    }
}
