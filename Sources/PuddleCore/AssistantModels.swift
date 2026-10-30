import Foundation

public struct MemoryNote: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var title: String
    public var content: String
    public var updatedAt = Date()
    public var source: String?
    public var sourceMessageID: UUID?
    public init(title: String, content: String, source: String? = nil, sourceMessageID: UUID? = nil) {
        self.title = title; self.content = content; self.source = source; self.sourceMessageID = sourceMessageID
    }
}

/// Recognize a direct user introduction without depending on a model tool call.
public struct NameMemoryProposal: Equatable, Sendable {
    public static let title = "Your name"
    public let name: String
    public let source: String

    public static func from(_ message: String, memories: [MemoryNote] = []) -> Self? {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MemoryLearning.allows(message), !MemoryLearning.containsSensitiveData(message) else { return nil }
        // A following sentence is never part of a person's name.
        let boundary = message.range(of: #"[.!]\s+(?=\p{L})"#, options: .regularExpression)
        let text = boundary.map { String(message[..<$0.lowerBound]) } ?? message
        if boundary != nil, let last = text.split(separator: " ").last {
            let abbreviation = last.lowercased()
            guard last.count != 1, !["dr", "mr", "mrs", "ms", "prof", "st"].contains(abbreviation) else { return nil }
        }
        guard text.count <= 300 else { return nil }
        let pattern = #"^(?:(?:hi|hello|hey)[!,.\s]+)?(?:(?:please\s+)?remember(?:\s+that)?[,:]?\s+)?(?:my\s+(?:(?:full|preferred)\s+)?name\s*(?:is\b|:)|(?:please\s+)?call\s+me\b)\s*(?:actually\s+)?(.+?)(?:[,!.]\s*(?:please\s+)?remember(?:\s+(?:it|that|this|my name))?)?[!.]?\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let name = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
        let words = name.split(whereSeparator: \.isWhitespace)
        let excluded: Set<String> = ["not", "a", "secret", "unknown", "and", "but", "because", "please", "remember", "name", "is", "from", "in", "later", "tomorrow", "today", "soon", "back", "when", "after", "at", "on", "i", "we", "you", "he", "she", "they", "like", "prefer", "work", "live", "want", "use"]
        let punctuation = CharacterSet(charactersIn: " .'-’‐")
        guard !name.isEmpty, name.count <= 80, words.count <= 6,
              name.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }),
              name.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || CharacterSet.nonBaseCharacters.contains($0) || punctuation.contains($0) }),
              !words.contains(where: { excluded.contains($0.lowercased()) }) else { return nil }
        let normalized = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !memories.contains(where: {
            $0.title.caseInsensitiveCompare(title) == .orderedSame &&
            $0.content.caseInsensitiveCompare(normalized) == .orderedSame
        }) else { return nil }
        return Self(name: normalized, source: text)
    }
}

public struct MeetingTaskSource: Codable, Equatable, Sendable {
    public let meetingID: UUID
    public let actionID: UUID
    public let quote: String
    public init(meetingID: UUID, actionID: UUID, quote: String) { self.meetingID = meetingID; self.actionID = actionID; self.quote = quote }
}

public struct AssistantTask: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var title: String
    public var createdAt = Date()
    public var dueAt: Date?
    public var completed = false
    public var notifiedAt: Date?
    public var meetingSource: MeetingTaskSource?
    public var priority: TaskPriority = .normal
    /// Empty means the user owns the next step. A named owner is local tracking, not delegation.
    public var owner = ""
    public var workflow: TaskWorkflow = .active
    public var notes = ""
    public var focusDate: Date?
    public var projectID: UUID?
    public var repetition: TaskRepetition?
    public var nextOccurrenceID: UUID?
    public init(title: String, dueAt: Date? = nil) { self.title = title; self.dueAt = dueAt }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, dueAt, completed, notifiedAt, meetingSource, priority, owner, workflow, notes, focusDate, projectID, repetition, nextOccurrenceID
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        dueAt = try values.decodeIfPresent(Date.self, forKey: .dueAt)
        completed = try values.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        notifiedAt = try values.decodeIfPresent(Date.self, forKey: .notifiedAt)
        meetingSource = try values.decodeIfPresent(MeetingTaskSource.self, forKey: .meetingSource)
        priority = try values.decodeIfPresent(TaskPriority.self, forKey: .priority) ?? .normal
        owner = try values.decodeIfPresent(String.self, forKey: .owner) ?? ""
        workflow = try values.decodeIfPresent(TaskWorkflow.self, forKey: .workflow) ?? .active
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        focusDate = try values.decodeIfPresent(Date.self, forKey: .focusDate)
        projectID = try values.decodeIfPresent(UUID.self, forKey: .projectID)
        repetition = try values.decodeIfPresent(TaskRepetition.self, forKey: .repetition)
        nextOccurrenceID = try values.decodeIfPresent(UUID.self, forKey: .nextOccurrenceID)
    }
}

public struct CalendarEvent: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let start: String
    public let end: String
    public let location: String
    public let description: String
    public let sourceURL: URL?
    public let meetingLinks: [MeetingJoinLink]?
    public let etag: String?
    public let calendarID: String?
    public let attendeeEmails: [String]?
    public let providerEventID: String?
    public let seriesID: String?
    public var joinLinks: [MeetingJoinLink] {
        if let meetingLinks, !meetingLinks.isEmpty { return meetingLinks }
        return MeetingJoinLink.discover(in: [location, description])
    }
    public init(id: String, title: String, start: String, end: String = "", location: String = "", description: String = "", sourceURL: URL? = nil,
                meetingLinks: [MeetingJoinLink] = [], etag: String? = nil, calendarID: String? = nil, attendeeEmails: [String]? = nil, providerEventID: String? = nil, seriesID: String? = nil) {
        self.id = id; self.title = title; self.start = start; self.end = end
        self.location = location; self.description = description
        self.sourceURL = sourceURL
        self.meetingLinks = meetingLinks
        self.etag = etag; self.calendarID = calendarID; self.attendeeEmails = attendeeEmails
        self.providerEventID = providerEventID
        self.seriesID = seriesID
    }
}

public enum AssistantDates {
    public static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    public static func calendarDate(_ value: String, timezone: TimeZone = .current) -> Date? {
        if let date = parse(value) { return date }
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }
}
