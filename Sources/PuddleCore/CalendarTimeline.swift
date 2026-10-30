import Foundation

public struct CalendarTimelinePlacement: Identifiable, Sendable {
    public var id: String { event.id }
    public let event: CalendarEvent
    public let startMinute: Double
    public let durationMinutes: Double
    public var column: Int
    public var columns: Int
}
public enum CalendarTimeline {
    public static func placements(events: [CalendarEvent], day: Date, calendar: Calendar = .current) -> [CalendarTimelinePlacement] {
        let day = calendar.startOfDay(for: day)
        guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return [] }
        func minute(_ date: Date) -> Double {
            if date <= day { return 0 }; if date >= next { return 1440 }
            return Double(calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date))
        }
        var values = events.compactMap { event -> CalendarTimelinePlacement? in
            guard event.start.count != 10, let start = AssistantDates.parse(event.start) else { return nil }
            let end = AssistantDates.parse(event.end) ?? start.addingTimeInterval(1800)
            guard start < next, end > day else { return nil }
            return CalendarTimelinePlacement(event: event, startMinute: minute(start), durationMinutes: max(15, minute(end) - minute(start)), column: 0, columns: 1)
        }.sorted { $0.startMinute == $1.startMinute ? $0.id < $1.id : $0.startMinute < $1.startMinute }
        var columnEnds: [Double] = [], group: [Int] = [], groupEnd = -Double.infinity
        func finishGroup() { for index in group { values[index].columns = max(1, columnEnds.count) } }
        for index in values.indices {
            let start = values[index].startMinute
            if start >= groupEnd { finishGroup(); group = []; columnEnds = [] }
            let column = columnEnds.firstIndex(where: { $0 <= start }) ?? columnEnds.count
            let end = start + values[index].durationMinutes
            if column == columnEnds.count { columnEnds.append(end) } else { columnEnds[column] = end }
            values[index].column = column; group.append(index); groupEnd = max(group.isEmpty ? end : groupEnd, end)
        }
        finishGroup(); return values
    }
}
