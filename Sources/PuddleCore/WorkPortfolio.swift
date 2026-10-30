import Foundation

public enum ProjectProgress: String, Codable, CaseIterable, Sendable { case active, paused, completed }
public struct WorkProject: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var title = ""
    public var objective = ""
    public var successCriteria = ""
    public var status = ProjectProgress.active
    public init() {}
    public func validated() throws -> Self {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200, objective.count <= 4000, successCriteria.count <= 4000 else { throw PuddleError("Name the project and keep its objective and success criteria under 4,000 characters each.") }
        return self
    }
}
public struct PersonContext: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var name = ""
    public var email = ""
    public var role = ""
    public var isVIP = false
    public var lastInteraction: Date?
    public var promises = ""
    public var talkingPoints = ""
    public var notes = ""
    public var sourceURL: URL?
    public init() {}
    public func validated() throws -> Self {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200,
              email.isEmpty || MailDraft.validAddress(email), role.count <= 300,
              [promises, talkingPoints, notes].allSatisfy({ $0.count <= 4000 }) else { throw PuddleError("Check this person’s name, email, role, and notes.") }
        if let url = sourceURL { guard ["https", "http", "file"].contains(url.scheme ?? "") else { throw PuddleError("Use a web or local file source link.") } }
        return self
    }
}
public enum DecisionProgress: String, Codable, CaseIterable, Sendable { case proposed, decided, reviewed }
public struct WorkDecision: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var title = ""
    public var projectID: UUID?
    public var owner = ""
    public var options = ""
    public var rationale = ""
    public var evidence: [SourceReference] = []
    public var reviewAt: Date?
    public var outcome = ""
    public var status = DecisionProgress.proposed
    public init() {}
    public func validated() throws -> Self {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 300, owner.count <= 200,
              [options, rationale, outcome].allSatisfy({ $0.count <= 4000 }), evidence.count <= 20,
              evidence.allSatisfy({ ["https", "http", "file"].contains($0.url.scheme ?? "") }) else { throw PuddleError("Check the decision title, owner, evidence links, and notes.") }
        guard status == .proposed || !rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PuddleError("Record the rationale before marking a decision decided or reviewed.") }
        return self
    }
}
public struct MailAttention: Sendable {
    public let reasons: [String]
    public let rank: Int
    public static func assess(_ message: MailMessage, people: [PersonContext]) -> Self {
        var reasons: [String] = [], rank = 0
        if let person = people.first(where: { $0.isVIP && !$0.email.isEmpty && $0.email.caseInsensitiveCompare(MailDraft.mailbox(message.sender)) == .orderedSame }) { reasons.append("VIP sender: \(person.name)"); rank += 4 }
        if message.labels.contains("IMPORTANT") { reasons.append("Provider marked Important"); rank += 2 }
        if message.isUnread { reasons.append("Unread"); rank += 1 }
        return Self(reasons: reasons, rank: rank)
    }
}
