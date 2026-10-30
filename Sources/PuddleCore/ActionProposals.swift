import Foundation
import CryptoKit

public struct MailDraft: Codable, Equatable, Sendable {
    public var to = ""
    public var cc = ""
    public var subject = ""
    public var body = ""
    public var threadID: String?
    public var inReplyTo: String?
    public var followUpAt: Date?
    public init(to: String = "", subject: String = "", body: String = "", threadID: String? = nil, inReplyTo: String? = nil) {
        self.to = to; self.subject = subject; self.body = body; self.threadID = threadID; self.inReplyTo = inReplyTo
    }
    public func validate() throws {
        guard !Self.addresses(to).isEmpty, Self.addresses(to + (cc.isEmpty ? "" : "," + cc)).allSatisfy(Self.validAddress),
              ![to, cc, subject, inReplyTo ?? ""].contains(where: { $0.unicodeScalars.contains(where: CharacterSet.newlines.contains) }),
              !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, subject.count <= 500,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.utf8.count <= 1_000_000 else {
            throw PuddleError("Enter valid comma-separated email addresses, a subject, and a message under 1 MB. Headers cannot contain line breaks.")
        }
        if let inReplyTo, !inReplyTo.isEmpty, !(inReplyTo.hasPrefix("<") && inReplyTo.hasSuffix(">")) { throw PuddleError("The reply’s Message-ID is invalid. Create a new message instead.") }
    }
    public static func addresses(_ text: String) -> [String] { text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    public static func validAddress(_ value: String) -> Bool {
        value.count <= 320 && value.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$"#, options: .regularExpression) == value.startIndex..<value.endIndex
    }
    public static func mailbox(_ header: String) -> String {
        if let start = header.lastIndex(of: "<"), let end = header.lastIndex(of: ">"), start < end { return String(header[header.index(after: start)..<end]) }
        return header.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public func mime(from: String, actionID: UUID) throws -> Data {
        try validate(); guard Self.validAddress(from) else { throw PuddleError("Reconnect a verified sending account.") }
        var headers = ["From: \(from)", "To: \(to)", "Subject: =?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?=", "Message-ID: <puddle-\(actionID.uuidString.lowercased())@puddle.local>", "MIME-Version: 1.0", "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64"]
        if !cc.isEmpty { headers.append("Cc: \(cc)") }
        if let inReplyTo, !inReplyTo.isEmpty { headers += ["In-Reply-To: \(inReplyTo)", "References: \(inReplyTo)"] }
        let encoded = Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + encoded).utf8)
    }
}

public struct CalendarPrevious: Codable, Equatable, Sendable {
    public let title: String; public let start: Date; public let end: Date; public let timezone: String
    public let attendees: String; public let location: String; public let notes: String
    public init(_ draft: CalendarDraft) { title = draft.title; start = draft.start; end = draft.end; timezone = draft.timezone; attendees = draft.attendees; location = draft.location; notes = draft.notes }
    public func draft() -> CalendarDraft {
        var value = CalendarDraft(); value.title = title; value.start = start; value.end = end; value.timezone = timezone
        value.attendees = attendees; value.location = location; value.notes = notes; return value
    }
}
public struct CalendarRemoval: Codable, Equatable, Sendable {
    public let title: String; public let calendarID: String; public let eventID: String; public let etag: String
    public let start: Date; public let end: Date
    public init(title: String, calendarID: String, eventID: String, etag: String, start: Date, end: Date) { self.title = title; self.calendarID = calendarID; self.eventID = eventID; self.etag = etag; self.start = start; self.end = end }
}
public struct CalendarDraft: Codable, Equatable, Sendable {
    public var title = ""
    public var start = Date().addingTimeInterval(3600)
    public var end = Date().addingTimeInterval(5400)
    public var timezone = TimeZone.current.identifier
    public var calendarID = "primary"
    public var attendees = ""
    public var location = ""
    public var notes = ""
    public var eventID: String?
    public var etag: String?
    public var previous: CalendarPrevious?
    public init() {}
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 500, end > start,
              end.timeIntervalSince(start) <= 31 * 86400, TimeZone(identifier: timezone) != nil,
              !calendarID.isEmpty, calendarID.count <= 1000,
              attendees.isEmpty || MailDraft.addresses(attendees).allSatisfy(MailDraft.validAddress),
              notes.count <= 20_000, location.count <= 2000 else { throw PuddleError("Check the event title, end time, timezone, calendar, and attendee email addresses. Events can span up to 31 days.") }
        if eventID != nil, etag == nil { throw PuddleError("Refresh this event before editing it so changes made elsewhere can be checked.") }
    }
    public func apiBody(actionID: UUID) throws -> [String: Any] {
        try validate()
        var body: [String: Any] = ["summary": title, "start": ["dateTime": start.ISO8601Format(), "timeZone": timezone],
            "end": ["dateTime": end.ISO8601Format(), "timeZone": timezone], "location": location, "description": notes,
            "attendees": MailDraft.addresses(attendees).map { ["email": $0] }]
        if eventID == nil { body["id"] = "puddle" + actionID.uuidString.lowercased().replacingOccurrences(of: "-", with: "") }
        return body
    }
}

public enum ActionPayload: Codable, Equatable, Sendable {
    case email(MailDraft)
    case calendar(CalendarDraft)
    case mailLabels(messageID: String, add: [String], remove: [String])
    case unsubscribe(NewsletterTarget)
    case calendarRemoval(CalendarRemoval)
}
public enum ActionStatus: String, Codable, Sendable { case draft, dispatching, completed, uncertain, declined }
public struct ActionProposal: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var createdAt = Date()
    public var account: String
    public var provider: MailProvider?
    public var payload: ActionPayload
    public var status = ActionStatus.draft
    public var sourceURL: URL?
    public var authorizedDigest: String?
    public var completedAt: Date?
    public var resultID: String?
    public var resultURL: URL?
    public var resultETag: String?
    public var undoOf: UUID?
    public var detail: String?
    public init(account: String, payload: ActionPayload, sourceURL: URL? = nil, provider: MailProvider = .google) { self.account = account; self.payload = payload; self.sourceURL = sourceURL; self.provider = provider }
    public var title: String {
        switch payload {
        case .email(let draft): return "Send email: \(draft.subject)"
        case .calendar(let draft): return "\(draft.eventID == nil ? "Create" : "Update") event: \(draft.title)"
        case .mailLabels: return "Update message labels"
        case .unsubscribe(let target): return "Unsubscribe: \(target.sender)"
        case .calendarRemoval(let value): return "Delete created event: \(value.title)"
        }
    }
    public var digest: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data()
        return SHA256.hash(data: Data(((provider ?? .google).rawValue + ":" + account).utf8) + data).map { String(format: "%02x", $0) }.joined()
    }
    public mutating func authorize(digest reviewedDigest: String) throws {
        guard status == .draft, reviewedDigest == digest else { throw PuddleError("This proposal changed or was already attempted. Review its current contents.") }
        switch payload {
        case .email(let draft): try draft.validate()
        case .calendar(let draft): try draft.validate()
        case .mailLabels(let id, let add, let remove):
            guard !id.isEmpty, !(add + remove).isEmpty,
                  (add + remove).allSatisfy({ ["INBOX", "UNREAD", "STARRED", "IMPORTANT"].contains($0) }) else { throw PuddleError("Choose supported message labels.") }
        case .unsubscribe(let target): try target.validate()
        case .calendarRemoval(let value):
            guard !value.eventID.isEmpty, !value.calendarID.isEmpty, !value.etag.isEmpty, value.title.count <= 500 else { throw PuddleError("Refresh the event before preparing an undo.") }
        }
        authorizedDigest = reviewedDigest; status = .dispatching
    }
}

extension AppSnapshot {
    public mutating func recoverInterruptedActions() {
        for index in actionProposals.indices where actionProposals[index].status == .dispatching {
            actionProposals[index].status = .uncertain
            actionProposals[index].detail = "Puddle restarted during execution. Check the provider before taking further action; this action will not replay automatically."
        }
    }
}
