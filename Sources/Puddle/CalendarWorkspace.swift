import Foundation
import PuddleCore

enum CalendarRange: String, CaseIterable {
    case today = "Today", week = "Next 7 days"
}

struct CalendarAgendaDay: Identifiable {
    var id: Date { date }
    let date: Date
    let events: [CalendarEvent]
}

struct CalendarAgenda {
    private struct Entry {
        let event: CalendarEvent
        let start: Date
        let end: Date?
        var allDay: Bool { event.start.count == 10 }
    }

    let days: [CalendarAgendaDay]
    let undated: [CalendarEvent]
    var events: [CalendarEvent] {
        var seen = Set<String>()
        return (days.flatMap(\.events) + undated).filter { seen.insert($0.id).inserted }
    }

    init(events: [CalendarEvent], range: CalendarRange, query: String, now: Date, calendar: Calendar = .current) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = events.filter {
            query.isEmpty || [$0.title, $0.location, $0.description].joined(separator: "\n").localizedCaseInsensitiveContains(query)
        }
        var undated: [CalendarEvent] = []
        let entries = matching.compactMap { event -> Entry? in
            guard let start = ExecutiveBrief.eventDate(event.start, calendar: calendar) else {
                undated.append(event); return nil
            }
            // Google date-only end dates are exclusive. Missing end times do not imply an all-day event.
            let end = ExecutiveBrief.eventDate(event.end, calendar: calendar)
                ?? (event.start.count == 10 ? calendar.date(byAdding: .day, value: 1, to: start) : nil)
            return Entry(event: event, start: start, end: end)
        }.sorted { left, right in
            if left.allDay != right.allDay { return left.allDay }
            return left.start == right.start ? left.event.id < right.event.id : left.start < right.start
        }
        self.undated = undated
        let today = calendar.startOfDay(for: now)
        days = (0..<(range == .today ? 1 : 7)).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today),
                  let next = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
            let events = entries.filter { entry in
                if let end = entry.end, end > entry.start { return entry.start < next && end > date }
                return entry.start >= date && entry.start < next
            }.map(\.event)
            return events.isEmpty ? nil : CalendarAgendaDay(date: date, events: events)
        }
    }

    static func timeLabel(_ event: CalendarEvent) -> String {
        if event.start.count == 10, AssistantDates.calendarDate(event.start) != nil { return "All day" }
        guard let start = AssistantDates.parse(event.start) else { return "Time unavailable" }
        guard let end = AssistantDates.parse(event.end), end > start else { return start.formatted(date: .omitted, time: .shortened) }
        return "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}
