import Foundation

public struct MailSnooze: Codable, Identifiable, Sendable {
    public var id = UUID()
    public let messageID: String
    public let provider: MailProvider
    public let account: String
    public let until: Date
    public let reminderID: UUID
    public init(messageID: String, provider: MailProvider, account: String, until: Date, reminderID: UUID) {
        self.messageID = messageID; self.provider = provider; self.account = account; self.until = until; self.reminderID = reminderID
    }
}
