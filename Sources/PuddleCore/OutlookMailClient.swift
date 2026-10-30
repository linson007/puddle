import Foundation

public struct OutlookMailClient: Sendable {
    private let session: MicrosoftMailSession
    private let transport: any HTTPTransport
    public init(session: MicrosoftMailSession, transport: any HTTPTransport = URLSessionTransport()) { self.session = session; self.transport = transport }
    public func inbox() async throws -> [MailMessage] {
        try await messages(path: "mailFolders/inbox/messages", query: [URLQueryItem(name: "$top", value: "50"), URLQueryItem(name: "$orderby", value: "receivedDateTime desc")])
    }
    public func search(_ query: String) async throws -> [MailMessage] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Array(try await inbox().prefix(10)) }
        let escaped = String(query.prefix(500)).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return try await messages(path: "messages", query: [URLQueryItem(name: "$top", value: "10"), URLQueryItem(name: "$search", value: "\"\(escaped)\"")])
    }
    public func thread(_ conversationID: String) async throws -> MailThreadPage {
        let escaped = conversationID.replacingOccurrences(of: "'", with: "''")
        let account = try await session.account()
        guard let account else { throw PuddleError("Connect Outlook before loading a conversation.") }
        var next: URL? = messageURL(path: "messages", query: [URLQueryItem(name: "$top", value: "100"), URLQueryItem(name: "$filter", value: "conversationId eq '\(escaped)'")])
        var result: [MailMessage] = [], seen = Set<String>(), pages = 0, characters = 0
        while let url = next, pages < 10, result.count < 500, characters < 10_000_000 {
            try Task.checkCancellation()
            guard url.scheme == "https", url.host == "graph.microsoft.com", url.port == nil || url.port == 443, url.user == nil, url.password == nil,
                  url.path == "/v1.0/me/messages" else { throw PuddleError("Outlook returned an unexpected conversation page URL.") }
            let (messages, following) = try await messagePage(url, expectedAccountID: account.id)
            for message in messages where seen.insert(message.id).inserted {
                result.append(message); characters += message.body.count
            }
            next = following; pages += 1
        }
        return MailThreadPage(messages: Array(result.prefix(500)).sorted { $0.date < $1.date }, hasMore: next != nil || result.count > 500)
    }
    public func attachments(messageID: String) async throws -> [MailAttachment] {
        struct Page: Decodable {
            struct Part: Decodable { let id: String; let name: String?; let contentType: String?; let size: Int? }
            let value: [Part]
        }
        let data = try await read("messages/\(Self.component(messageID))/attachments?$select=id,name,contentType,size")
        return try JSONDecoder().decode(Page.self, from: data).value.prefix(100).map { MailAttachment(id: $0.id, name: $0.name ?? "Attachment", mimeType: $0.contentType ?? "application/octet-stream", bytes: $0.size ?? 0) }
    }
    public func attachment(_ attachment: MailAttachment, messageID: String) async throws -> Data {
        guard attachment.bytes <= 10 * 1024 * 1024 else { throw PuddleError("Preview files up to 10 MB. Open larger files in Outlook.") }
        struct File: Decodable { let contentBytes: String? }
        let data = try await read("messages/\(Self.component(messageID))/attachments/\(Self.component(attachment.id))")
        guard let text = try JSONDecoder().decode(File.self, from: data).contentBytes, let bytes = Data(base64Encoded: text), bytes.count <= 10 * 1024 * 1024 else { throw PuddleError("This attachment cannot be previewed locally. Open it in Outlook.") }
        return bytes
    }
    private static func component(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
    private func read(_ path: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/\(path)")!)
        request.setValue("Bearer \(try await session.accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.sendBounded(request, maximumBytes: 16 * 1024 * 1024, until: nil)
        try checkHTTP(response, data: data, service: "Outlook"); return data
    }
    private func messages(path: String, query: [URLQueryItem]) async throws -> [MailMessage] {
        try await messagePage(messageURL(path: path, query: query)).0
    }
    private func messageURL(path: String, query: [URLQueryItem]) -> URL {
        var parts = URLComponents(string: "https://graph.microsoft.com/v1.0/me/\(path)")!
        parts.queryItems = query + [URLQueryItem(name: "$select", value: "id,conversationId,subject,from,toRecipients,receivedDateTime,isRead,importance,bodyPreview,body,webLink,internetMessageId,internetMessageHeaders")]
        return parts.url!
    }
    private func messagePage(_ url: URL, expectedAccountID: String? = nil) async throws -> ([MailMessage], URL?) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await session.accessToken(expectedAccountID: expectedAccountID))", forHTTPHeaderField: "Authorization")
        request.setValue("outlook.body-content-type=\"text\"", forHTTPHeaderField: "Prefer")
        let (data, response) = try await RetryingTransport(base: transport).sendBounded(request, maximumBytes: 16 * 1024 * 1024, until: nil)
        try checkHTTP(response, data: data, service: "Outlook")
        struct Page: Decodable {
            let value: [Message]; let nextLink: URL?
            enum CodingKeys: String, CodingKey { case value; case nextLink = "@odata.nextLink" }
        }
        let page = try JSONDecoder().decode(Page.self, from: data)
        let messages = page.value.map { message in
            let labels = (message.isRead == true ? [] : ["UNREAD"]) + (message.importance == "high" ? ["IMPORTANT"] : [])
            let body = message.body?.contentType?.lowercased() == "html" ? MailText.fromHTML(message.body?.content ?? "") : message.body?.content ?? message.bodyPreview ?? ""
            let webLink = message.webLink.flatMap { url in url.scheme == "https" && ["outlook.office.com", "outlook.office365.com", "outlook.live.com"].contains(url.host ?? "") ? url : nil }
            return MailMessage(id: message.id, threadID: message.conversationId ?? message.id, subject: message.subject ?? "(No subject)",
                sender: message.from?.emailAddress?.address ?? "Unknown sender", recipient: (message.toRecipients ?? []).compactMap { $0.emailAddress?.address }.joined(separator: ", "),
                date: message.receivedDateTime.flatMap(AssistantDates.parse) ?? .distantPast, snippet: message.bodyPreview ?? "", body: String(body.prefix(100_000)), labels: labels,
                internetMessageID: message.internetMessageId, provider: .outlook, providerURL: webLink,
                newsletter: NewsletterTarget.from(sender: message.from?.emailAddress?.address ?? "", unsubscribe: message.internetMessageHeaders?.first { $0.name.lowercased() == "list-unsubscribe" }?.value ?? "", post: message.internetMessageHeaders?.first { $0.name.lowercased() == "list-unsubscribe-post" }?.value ?? ""))
        }
        return (messages, page.nextLink)
    }
    private struct Message: Decodable {
        struct Address: Decodable { struct Email: Decodable { let address: String? }; let emailAddress: Email? }
        struct Body: Decodable { let content: String?; let contentType: String? }
        let id: String; let conversationId: String?; let subject: String?; let from: Address?; let toRecipients: [Address]?
        let receivedDateTime: String?; let isRead: Bool?; let importance: String?; let bodyPreview: String?; let body: Body?
        let webLink: URL?; let internetMessageId: String?
        struct Header: Decodable { let name: String; let value: String }
        let internetMessageHeaders: [Header]?
    }
    public func execute(_ action: ActionProposal) async throws -> ActionResult {
        guard action.provider == .outlook, action.status == .dispatching, action.authorizedDigest == action.digest,
              let account = try await session.account(), account.email == action.account else { throw PuddleError("The reviewed Outlook account or payload changed.") }
        let path: String, method: String, contentType: String, body: Data
        switch action.payload {
        case .email(let draft):
            guard account.scopes.contains("Mail.Send") else { throw PuddleError("Allow Outlook sending first.") }
            path = "sendMail"; method = "POST"; contentType = "text/plain"
            body = Data(try draft.mime(from: account.email, actionID: action.id).base64EncodedString().utf8)
        case .mailLabels(let id, let add, let remove):
            guard account.scopes.contains("Mail.ReadWrite") else { throw PuddleError("Allow Outlook organization first.") }
            let id = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            contentType = "application/json"
            if remove == ["INBOX"], add.isEmpty {
                path = "messages/\(id)/move"; method = "POST"; body = try JSONSerialization.data(withJSONObject: ["destinationId": "archive"])
            } else {
                var fields: [String: Any] = [:]
                if remove.contains("UNREAD") { fields["isRead"] = true }; if add.contains("UNREAD") { fields["isRead"] = false }
                if add.contains("STARRED") { fields["flag"] = ["flagStatus": "flagged"] }
                if add.contains("IMPORTANT") { fields["importance"] = "high" }
                guard !fields.isEmpty else { throw PuddleError("These labels are unsupported in Outlook.") }
                path = "messages/\(id)"; method = "PATCH"; body = try JSONSerialization.data(withJSONObject: fields)
            }
        case .calendar, .calendarRemoval: throw PuddleError("Calendar proposals use your Google Calendar account.")
        case .unsubscribe: throw PuddleError("Use the reviewed newsletter client for unsubscribe requests.")
        }
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/\(path)")!, timeoutInterval: 60)
        request.httpMethod = method; request.httpBody = body; request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await session.accessToken(expectedAccountID: account.id))", forHTTPHeaderField: "Authorization")
        try Task.checkCancellation()
        let (data, response) = try await transport.send(request); try checkHTTP(response, data: data, service: "Outlook")
        return ActionResult(id: action.id.uuidString, url: URL(string: "https://outlook.office.com/mail/sentitems"))
    }
}
