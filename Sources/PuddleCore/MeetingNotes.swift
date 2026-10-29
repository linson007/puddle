import Foundation

public struct MeetingNote: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public var title: String
    public var meetingDate: Date
    public var participants: String
    public var agenda: String
    public var notes: String
    public var transcript: String
    public var calendarEventID: String?
    public var joinLink: MeetingJoinLink?
    public var summary: MeetingSummary?

    public init(id: UUID = UUID(), title: String, meetingDate: Date = Date(), calendarEventID: String? = nil, joinLink: MeetingJoinLink? = nil) {
        self.id = id; self.title = title; self.meetingDate = meetingDate; self.calendarEventID = calendarEventID; self.joinLink = joinLink
        createdAt = Date(); updatedAt = createdAt; participants = ""; agenda = ""; notes = ""; transcript = ""
    }
}

public struct MeetingDraft: Equatable, Sendable {
    public var title: String
    public var meetingDate: Date
    public var participants: String
    public var agenda: String
    public var notes: String
    public var transcript: String
    public init(_ note: MeetingNote) {
        title = note.title; meetingDate = note.meetingDate; participants = note.participants
        agenda = note.agenda; notes = note.notes; transcript = note.transcript
    }

    public func applying(to original: MeetingNote, now: Date = Date()) throws -> MeetingNote {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200, meetingDate.timeIntervalSinceReferenceDate.isFinite else {
            throw PuddleError("Meeting notes need a title up to 200 characters and a valid date.")
        }
        for (name, value, limit) in [("Participants", participants, 4000), ("Agenda", agenda, 12_000), ("Notes", notes, 100_000), ("Transcript", transcript, 200_000)] {
            guard value.count <= limit else { throw PuddleError("\(name) exceeds the \(limit)-character limit. Your draft has been retained.") }
        }
        var next = original
        next.title = title; next.meetingDate = meetingDate; next.participants = participants
        next.agenda = agenda; next.notes = notes; next.transcript = transcript; next.updatedAt = now
        return next
    }
}
