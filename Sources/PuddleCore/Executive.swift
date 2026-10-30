import Foundation

public struct ExecutiveProfile: Codable, Equatable, Sendable {
    public var name = ""
    public var role = ""
    public var organization = ""
    public var objectives = ""
    public var configured = false
    public init() {}

    public func validated() throws -> Self {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.role = role.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.organization = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.objectives = objectives.trimmingCharacters(in: .whitespacesAndNewlines)
        guard copy.name.count <= 100, copy.role.count <= 200, copy.organization.count <= 200, copy.objectives.count <= 4000 else {
            throw PuddleError("Keep your name under 100 characters, role and organization under 200, and objectives under 4,000.")
        }
        copy.configured = true
        return copy
    }
}

public enum TaskPriority: String, Codable, CaseIterable, Sendable {
    case high, normal, low
    public var label: String { rawValue.capitalized }
    public var rank: Int { Self.allCases.firstIndex(of: self)! }
}

public enum TaskWorkflow: String, Codable, CaseIterable, Sendable {
    case active, waiting
    public var label: String { self == .active ? "My next action" : "Waiting on someone" }
}

/// One validation path for edits from every screen. A failed save can retain this draft.
public struct TaskDraft: Equatable, Sendable {
    public var title: String
    public var dueAt: Date?
    public var priority: TaskPriority
    public var owner: String
    public var workflow: TaskWorkflow
    public var notes: String
    public var projectID: UUID?
    public var frequency: TaskFrequency?

    public init(_ task: AssistantTask) {
        title = task.title; dueAt = task.dueAt; priority = task.priority
        owner = task.owner; workflow = task.workflow; notes = task.notes
        projectID = task.projectID
        frequency = task.repetition?.frequency
    }

    public func applying(to task: AssistantTask) throws -> AssistantTask {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 300, owner.count <= 200, notes.count <= 4000,
              dueAt?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw PuddleError("A commitment needs a title of 1–300 characters, owner up to 200, notes up to 4,000, and a valid date.")
        }
        guard workflow != .waiting || !owner.isEmpty else {
            throw PuddleError("Add who you are waiting on so you can follow up.")
        }
        var next = task
        next.title = title; next.dueAt = dueAt; next.priority = priority
        next.owner = owner; next.workflow = workflow; next.notes = notes
        next.projectID = projectID
        if let frequency {
            guard let dueAt else { throw PuddleError("Choose a due date for a repeating commitment.") }
            if task.repetition?.frequency == frequency, task.dueAt == dueAt { next.repetition = task.repetition }
            else { next.repetition = TaskRepetition(frequency: frequency, dueAt: dueAt) }
            _ = try next.repetition?.next(after: dueAt, now: dueAt)
        } else { next.repetition = nil }
        if task.dueAt != dueAt || task.workflow != workflow { next.notifiedAt = nil }
        return next
    }
}

public struct AgendaItem: Identifiable, Sendable {
    public var id: String { event.id }
    public let event: CalendarEvent
    public let start: Date
    public let end: Date?
    public let allDay: Bool
    public var conflicts: [String] = []

    public func isOngoing(at now: Date) -> Bool { !allDay && start <= now && (end.map { $0 > now } ?? false) }
}

/// Deterministic, local projection. It never fabricates priorities or infers commitments from mail.
public struct ExecutiveBrief: Sendable {
    public let date: Date
    public let priorities: [AssistantTask]
    public let overdue: [AssistantTask]
    public let dueToday: [AssistantTask]
    public let waiting: [AssistantTask]
    public let unscheduled: [AssistantTask]
    public let agenda: [AgendaItem]
    public let flaggedMail: [MailMessage]

    public init(snapshot: AppSnapshot, now: Date = Date(), calendar: Calendar = .current) {
        date = now
        let open = snapshot.tasks.filter { !$0.completed }.sorted(by: Self.taskOrder)
        priorities = open.filter { $0.focusDate.map { calendar.isDate($0, inSameDayAs: now) } ?? false }
        overdue = open.filter { $0.dueAt.map { $0 < now } ?? false }
        dueToday = open.filter { $0.dueAt.map { $0 >= now && calendar.isDate($0, inSameDayAs: now) } ?? false }
        waiting = open.filter { $0.workflow == .waiting }
        unscheduled = open.filter { $0.dueAt == nil }
        let inbox = snapshot.settings.mailProvider == .outlook ? snapshot.outlookMessages : snapshot.messages
        flaggedMail = inbox.filter { $0.isUnread && MailAttention.assess($0, people: snapshot.people).rank >= 3 }.sorted { $0.date > $1.date }
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay.addingTimeInterval(86400)
        var uniqueIDs = Set<String>()
        var items: [AgendaItem] = snapshot.calendarEvents.compactMap { event in
            guard uniqueIDs.insert(event.id).inserted,
                  let start = Self.eventDate(event.start, calendar: calendar), start < endOfDay else { return nil }
            let end = Self.eventDate(event.end, calendar: calendar).flatMap { $0 > start ? $0 : nil }
            guard end.map({ $0 > startOfDay }) ?? (start >= startOfDay) else { return nil }
            return AgendaItem(event: event, start: start, end: end, allDay: event.start.count == 10)
        }.sorted {
            if $0.allDay != $1.allDay { return $0.allDay }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
        for i in items.indices where !items[i].allDay {
            guard let end = items[i].end else { continue }
            for j in items.indices where j > i && !items[j].allDay {
                guard let otherEnd = items[j].end else { continue }
                if items[i].start < otherEnd && items[j].start < end {
                    items[i].conflicts.append(items[j].id); items[j].conflicts.append(items[i].id)
                }
            }
        }
        agenda = items
    }

    public static func taskOrder(_ a: AssistantTask, _ b: AssistantTask) -> Bool {
        if a.priority != b.priority { return a.priority.rank < b.priority.rank }
        if a.dueAt != b.dueAt { return (a.dueAt ?? .distantFuture) < (b.dueAt ?? .distantFuture) }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    public static func eventDate(_ value: String, calendar: Calendar = .current) -> Date? {
        if let date = AssistantDates.parse(value) { return date }
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }
}

public struct MeetingPreparation: Sendable {
    public let event: CalendarEvent
    public let notes: [MeetingNote]
    public let actions: [AssistantTask]
    public init(event: CalendarEvent, snapshot: AppSnapshot) {
        self.event = event
        // Explicit provider series links survive title changes. Legacy notes can use full-title matching.
        let title = Self.identity(event.title)
        notes = snapshot.meetings.filter {
            if $0.calendarEventID == event.id { return true }
            if let series = event.seriesID, let noteSeries = $0.calendarSeriesID { return series == noteSeries }
            return !title.isEmpty && Self.identity($0.title) == title
        }.sorted { $0.meetingDate > $1.meetingDate }
        let ids = Set(notes.map(\.id))
        actions = snapshot.tasks.filter { !$0.completed && $0.meetingSource.map { ids.contains($0.meetingID) } == true }
            .sorted(by: ExecutiveBrief.taskOrder)
    }
    private static func identity(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension AppSnapshot {
    /// A bounded read model for the assistant, with counts and freshness so omissions stay visible.
    public func executiveContext(now: Date = Date(), mailConnected: Bool, calendarConnected: Bool, calendar: Calendar = .current) -> String {
        let brief = ExecutiveBrief(snapshot: self, now: now, calendar: calendar)
        func local(_ date: Date) -> String { CalendarContext.localTime(date.ISO8601Format(), timezone: calendar.timeZone) }
        func tasks(_ items: [AssistantTask]) -> [[String: String]] {
            items.prefix(8).map { ["id": $0.id.uuidString, "title": String($0.title.prefix(300)),
                "owner": String($0.owner.prefix(200)), "workflow": $0.workflow.rawValue,
                "priority": $0.priority.rawValue, "due_at": $0.dueAt?.ISO8601Format() ?? "undated",
                "local_due_at": $0.dueAt.map(local) ?? "undated"] }
        }
        var data: [String: Any] = [
            "as_of": now.ISO8601Format(), "local_as_of": local(now), "timezone": calendar.timeZone.identifier,
            "time_display_rule": "Use local_as_of for the current clock time, local_due_at for deadlines, local_start/local_end for events, and local_*_last_sync for cache timestamps. Raw ISO timestamps may use UTC; never relabel them as local. A cache timestamp is not the current time. Do not guess a current time from the agenda.",
            "scope": "Saved local commitments and cached primary calendar/recent inbox only. Lists are bounded; counts include omitted items. Refresh connections for current data. Never claim mail was fully triaged.",
            "priorities": tasks(brief.priorities), "overdue": tasks(brief.overdue),
            "due_today": tasks(brief.dueToday), "waiting": tasks(brief.waiting),
            "unscheduled": tasks(brief.unscheduled),
            "counts": ["priorities": brief.priorities.count, "overdue": brief.overdue.count, "due_today": brief.dueToday.count,
                "waiting": brief.waiting.count, "unscheduled": brief.unscheduled.count, "agenda": brief.agenda.count, "flagged_unread_mail": brief.flaggedMail.count],
            "calendar_connected": calendarConnected, "calendar_last_sync": calendarLastSync?.ISO8601Format() ?? "never",
            "local_calendar_last_sync": calendarLastSync.map(local) ?? "never",
            "calendar_has_more": calendarHasMore,
            "agenda": brief.agenda.prefix(15).map { item -> [String: Any] in
                ["event_id": item.id, "title": String(item.event.title.prefix(200)), "start": item.event.start,
                 "local_start": CalendarContext.localTime(item.event.start, timezone: calendar.timeZone), "local_end": CalendarContext.localTime(item.event.end, timezone: calendar.timeZone),
                 "end": item.event.end, "all_day": item.allDay, "conflicts": item.conflicts]
            },
            "mail_connected": mailConnected, "mail_provider": settings.mailProvider.rawValue,
            "mail_last_sync": (settings.mailProvider == .outlook ? outlookLastSync : lastSync)?.ISO8601Format() ?? "never",
            "local_mail_last_sync": (settings.mailProvider == .outlook ? outlookLastSync : lastSync).map(local) ?? "never",
            "flagged_unread_mail": brief.flaggedMail.prefix(5).map {
                ["subject": String($0.subject.prefix(200)), "sender": String($0.sender.prefix(100)), "source": $0.sourceURL.absoluteString]
            },
        ]
        func encode() -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])) ?? Data("{}".utf8), as: UTF8.self)
        }
        var result = encode()
        let collections = ["overdue", "due_today", "waiting", "unscheduled", "agenda", "flagged_unread_mail", "priorities"]
        // Stay below the agent's normal result limit, retaining valid JSON and original total counts.
        while result.count > 11_000 {
            guard let key = collections.max(by: { (data[$0] as? [Any] ?? []).count < (data[$1] as? [Any] ?? []).count }),
                  var items = data[key] as? [Any], !items.isEmpty else { break }
            items.removeLast(); data[key] = items; result = encode()
        }
        return result
    }

    public mutating func setDailyPriority(_ id: UUID, enabled: Bool, now: Date = Date(), calendar: Calendar = .current) throws {
        guard let index = tasks.firstIndex(where: { $0.id == id }), !tasks[index].completed else {
            throw PuddleError("Choose an open commitment for today's priorities.")
        }
        if enabled {
            let others = tasks.filter { $0.id != id && !$0.completed && ($0.focusDate.map { calendar.isDate($0, inSameDayAs: now) } ?? false) }
            guard others.count < 3 else { throw PuddleError("Keep today focused on three priorities. Remove one before adding another.") }
        }
        tasks[index].focusDate = enabled ? now : nil
    }
}
