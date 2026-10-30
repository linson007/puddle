import Foundation

public enum BrowserErrandStatus: String, Codable, Sendable { case ready, running, needsReview, paused, completed }
public struct BrowserErrand: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var createdAt = Date()
    public var updatedAt = Date()
    public var goal: String
    public var status = BrowserErrandStatus.ready
    public var latestProgress = "Read the current page, prepare the next steps, review actions, and verify the result."
    public var evidence: String?
    public var turnCount = 0
    public var conversationID: UUID?
    public init(goal: String) { self.goal = goal }
}
