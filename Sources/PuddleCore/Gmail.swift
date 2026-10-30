import Foundation

public protocol InboxSource: Sendable {
    func accountEmail() async throws -> String
    func inbox(limit: Int) async throws -> [MailMessage]
}

public struct GmailSyncResult: Sendable {
    public let account: String
    public let messages: [MailMessage]
    public let historyID: String?
    public let newMessageIDs: Set<String>
    public let usedHistory: Bool
}

public struct GmailClient: InboxSource, Sendable {
    private let session: GoogleSession
    private let transport: any HTTPTransport
    public init(session: GoogleSession, transport: any HTTPTransport = URLSessionTransport()) {
        self.session = session; self.transport = RetryingTransport(base: transport)
    }

    public func accountEmail() async throws -> String {
        struct Profile: Decodable { let emailAddress: String }
        return try JSONDecoder().decode(Profile.self, from: await get("profile")).emailAddress
    }

    public func inbox(limit: Int = 50) async throws -> [MailMessage] {
        try await fetchMessages(query: [URLQueryItem(name: "labelIds", value: "INBOX"),
                                        URLQueryItem(name: "maxResults", value: String(max(1, min(limit, 100))))])
    }

    public func search(query: String, limit: Int = 10) async throws -> [MailMessage] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return try await inbox(limit: limit) }
        return try await fetchMessages(query: [URLQueryItem(name: "q", value: String(query.prefix(500))),
                                              URLQueryItem(name: "maxResults", value: String(max(1, min(limit, 10))))])
    }
    public func thread(_ id: String) async throws -> MailThreadPage {
        let data = try await get("threads/" + (id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""), query: [URLQueryItem(name: "format", value: "full")])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let values = object?["messages"] as? [[String: Any]] ?? []
        let messages = try values.prefix(250).map { try GmailMessageDecoder.decode(JSONSerialization.data(withJSONObject: $0)) }.sorted { $0.date < $1.date }
        return MailThreadPage(messages: messages, hasMore: values.count > 250)
    }
    public func attachment(_ attachment: MailAttachment, messageID: String) async throws -> Data {
        guard attachment.bytes <= 10 * 1024 * 1024 else { throw PuddleError("Preview attachments up to 10 MB. Open larger files in Gmail.") }
        let message = messageID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let id = attachment.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let data = try await get("messages/\(message)/attachments/\(id)")
        struct Body: Decodable { let data: String }
        guard let decoded = Data(base64URL: try JSONDecoder().decode(Body.self, from: data).data), decoded.count <= 10 * 1024 * 1024 else { throw PuddleError("The attachment is unreadable or exceeds the 10 MB preview limit.") }
        return decoded
    }

    public func synchronize(cached: [MailMessage], historyID: String?, limit: Int = 50) async throws -> GmailSyncResult {
        struct Profile: Decodable { let emailAddress: String; let historyId: String? }
        let profile = try JSONDecoder().decode(Profile.self, from: await get("profile"))
        var changed = Set<String>(), added = Set<String>(), cursor = profile.historyId
        var usedHistory = false
        if let historyID {
            do {
                let changes = try await history(since: historyID)
                changed = changes.changed; added = changes.added; cursor = changes.cursor
                usedHistory = true
            } catch is GmailHistoryExpired {} // Rebuild a baseline without duplicate arrival notifications.
        }
        let messages = try await fetchMessages(query: [URLQueryItem(name: "labelIds", value: "INBOX"),
            URLQueryItem(name: "maxResults", value: String(max(1, min(limit, 100))))],
            cached: usedHistory ? Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) : [:], refresh: changed)
        return GmailSyncResult(account: profile.emailAddress, messages: messages, historyID: cursor,
                               newMessageIDs: added, usedHistory: usedHistory)
    }

    private func history(since cursor: String) async throws -> (changed: Set<String>, added: Set<String>, cursor: String) {
        struct Page: Decodable {
            struct Entry: Decodable {
                struct Message: Decodable { let id: String }
                struct Change: Decodable { let message: Message }
                let messages: [Message]?
                let messagesAdded: [Change]?; let messagesDeleted: [Change]?
                let labelsAdded: [Change]?; let labelsRemoved: [Change]?
            }
            let history: [Entry]?; let nextPageToken: String?; let historyId: String
        }
        var changed = Set<String>(), added = Set<String>(), next: String?
        for _ in 0..<20 {
            var query = [URLQueryItem(name: "startHistoryId", value: cursor), URLQueryItem(name: "maxResults", value: "500")]
            if let next { query.append(URLQueryItem(name: "pageToken", value: next)) }
            let page = try JSONDecoder().decode(Page.self, from: await get("history", query: query))
            for entry in page.history ?? [] {
                changed.formUnion((entry.messages ?? []).map(\.id))
                for changes in [entry.messagesAdded, entry.messagesDeleted, entry.labelsAdded, entry.labelsRemoved] {
                    changed.formUnion((changes ?? []).map { $0.message.id })
                }
                added.formUnion((entry.messagesAdded ?? []).map { $0.message.id })
            }
            guard let token = page.nextPageToken else { return (changed, added, page.historyId) }
            guard token != next else { throw PuddleError("Gmail returned a repeated history page. The sync cursor was not advanced.") }
            next = token
        }
        throw GmailHistoryExpired() // A large backlog gets a fresh bounded baseline.
    }

    private func fetchMessages(query: [URLQueryItem], cached: [String: MailMessage] = [:], refresh: Set<String> = []) async throws -> [MailMessage] {
        struct MessageList: Decodable {
            struct Reference: Decodable { let id: String }
            let messages: [Reference]?
        }
        let data = try await get("messages", query: query)
        let ids = try JSONDecoder().decode(MessageList.self, from: data).messages?.map(\.id) ?? []
        var messages: [MailMessage] = []
        // Bound concurrency rather than opening a connection for every message.
        for start in stride(from: 0, to: ids.count, by: 5) {
            try Task.checkCancellation()
            let batch = ids[start..<min(start + 5, ids.count)]
            let fetched = try await withThrowingTaskGroup(of: MailMessage?.self) { group in
                for id in batch {
                    group.addTask {
                        if let message = cached[id], !refresh.contains(id) { return message }
                        do {
                            let data = try await get("messages/\(id)", query: [URLQueryItem(name: "format", value: "full")])
                            return try GmailMessageDecoder.decode(data)
                        } catch let error as GmailMessageGone {
                            _ = error
                            return nil // It may have been deleted while the inbox was syncing.
                        }
                    }
                }
                var results: [MailMessage] = []
                for try await message in group { if let message { results.append(message) } }
                return results
            }
            messages.append(contentsOf: fetched)
        }
        return messages.sorted { $0.date > $1.date }
    }

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        var parts = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)")!
        if !query.isEmpty { parts.queryItems = query }
        var token = try await session.accessToken()
        for attempt in 0...1 {
            var request = URLRequest(url: parts.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // Includes base64 attachment envelopes (decoded preview limit: 10 MiB).
            let (data, response) = try await transport.sendBounded(request, maximumBytes: 16 * 1024 * 1024, until: nil)
            if response.statusCode == 401, attempt == 0 {
                token = try await session.accessToken(rejected: token)
                continue
            }
            if response.statusCode == 404, path.hasPrefix("messages/") { throw GmailMessageGone() }
            if response.statusCode == 404, path == "history" { throw GmailHistoryExpired() }
            try checkHTTP(response, data: data, service: "Gmail")
            return data
        }
        throw PuddleError("Gmail sign-in expired. Reconnect in Settings.")
    }
}

private struct GmailMessageGone: Error {}
private struct GmailHistoryExpired: Error {}

public enum GmailMessageDecoder {
    private struct Message: Decodable {
        let id: String
        let threadId: String?
        let labelIds: [String]?
        let snippet: String?
        let internalDate: String?
        let payload: Part?
    }
    private struct Part: Decodable {
        struct Header: Decodable { let name: String; let value: String }
        struct Body: Decodable { let data: String?; let attachmentId: String?; let size: Int? }
        let mimeType: String?
        let filename: String?
        let headers: [Header]?
        let body: Body?
        let parts: [Part]?

        var text: String {
            if !(filename ?? "").isEmpty { return "" }
            if let children = parts, !children.isEmpty {
                if mimeType?.lowercased() == "multipart/alternative" {
                    let plain = children.filter { $0.mimeType?.lowercased() == "text/plain" }.map(\.text).filter { !$0.isEmpty }
                    if !plain.isEmpty { return plain.joined(separator: "\n\n") }
                }
                return children.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
            guard let encoded = body?.data, let data = Data(base64URL: encoded) else { return "" }
            let charset = headers?.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value.lowercased() ?? ""
            let encoding: String.Encoding = charset.contains("iso-8859-1") ? .isoLatin1 : .utf8
            let decoded = String(data: data, encoding: encoding) ?? String(data: data, encoding: .windowsCP1252) ?? ""
            switch mimeType?.lowercased() {
            case "text/plain": return decoded
            case "text/html": return MailText.fromHTML(decoded)
            default: return ""
            }
        }
        var attachments: [String] {
            let own = (filename ?? "").isEmpty ? [] : [filename!]
            return own + (parts ?? []).flatMap(\.attachments)
        }
        var attachmentParts: [MailAttachment] {
            let own: [MailAttachment]
            if let id = body?.attachmentId, let name = filename, !name.isEmpty { own = [MailAttachment(id: id, name: name, mimeType: mimeType ?? "application/octet-stream", bytes: body?.size ?? 0)] }
            else { own = [] }
            return own + (parts ?? []).flatMap(\.attachmentParts)
        }
    }

    public static func decode(_ data: Data) throws -> MailMessage {
        let raw = try JSONDecoder().decode(Message.self, from: data)
        let headers = raw.payload?.headers ?? []
        func header(_ name: String) -> String {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }
        let text = (raw.payload?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = MailText.decodeEntities(raw.snippet ?? "")
        let body = text.isEmpty ? "[Email preview; full body unavailable]\n\(snippet)" : String(text.prefix(100_000))
        return MailMessage(id: raw.id, threadID: raw.threadId ?? raw.id,
                           subject: header("Subject").isEmpty ? "(No subject)" : header("Subject"),
                           sender: header("From"), recipient: header("To"),
                           date: Date(timeIntervalSince1970: (Double(raw.internalDate ?? "") ?? 0) / 1000),
                           snippet: snippet, body: body + (text.count > 100_000 ? "\n[Body shortened for local storage]" : ""),
                           labels: raw.labelIds ?? [], attachments: raw.payload?.attachments ?? [], internetMessageID: header("Message-ID").isEmpty ? nil : header("Message-ID"), attachmentParts: raw.payload?.attachmentParts,
                           newsletter: NewsletterTarget.from(sender: header("From"), unsubscribe: header("List-Unsubscribe"), post: header("List-Unsubscribe-Post")))
    }
}

public enum MailText {
    public static func fromHTML(_ html: String) -> String {
        var text = html
        for pattern in ["(?is)<(script|style|head)\\b[^>]*>.*?</\\1\\s*>", "(?s)<!--.*?-->"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "(?i)<(?:br\\s*/?|/p|/div|/li|/tr|/h[1-6])\\s*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
        return text.replacingOccurrences(of: "\\n[ \\n]+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func decodeEntities(_ input: String) -> String {
        var text = input
        let entities = ["&nbsp;": " ", "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let range = Range(match.range, in: text), let digitsRange = Range(match.range(at: 1), in: text) else { continue }
                let digits = String(text[digitsRange])
                let code = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                if let code, let scalar = UnicodeScalar(code) { text.replaceSubrange(range, with: String(scalar)) }
            }
        }
        return text.replacingOccurrences(of: "&amp;", with: "&")
    }
}
