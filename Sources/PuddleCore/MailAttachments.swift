import Foundation

public struct MailAttachment: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let mimeType: String
    public let bytes: Int
    public init(id: String, name: String, mimeType: String, bytes: Int) { self.id = id; self.name = name; self.mimeType = mimeType; self.bytes = bytes }
}
public struct MailThreadPage: Sendable {
    public let messages: [MailMessage]
    public let hasMore: Bool
    public init(messages: [MailMessage], hasMore: Bool = false) { self.messages = messages; self.hasMore = hasMore }
}
