import Foundation

public struct ActionResult: Sendable {
    public let id: String
    public let url: URL?
    public let etag: String?
    public init(id: String, url: URL? = nil, etag: String? = nil) { self.id = id; self.url = url; self.etag = etag }
}

public struct GoogleActionClient: Sendable {
    private let session: GoogleSession
    private let transport: any HTTPTransport
    public init(session: GoogleSession, transport: any HTTPTransport = URLSessionTransport()) { self.session = session; self.transport = transport }
    public func execute(_ action: ActionProposal) async throws -> ActionResult {
        guard action.provider != .outlook, action.status == .dispatching, action.authorizedDigest == action.digest,
              try await session.account()?.email == action.account else { throw PuddleError("The reviewed action or connected account changed. Review a new proposal.") }
        let scopes = try await session.grantedScopes()
        let url: URL, method: String, body: [String: Any], etag: String?
        switch action.payload {
        case .email(let draft):
            guard scopes.contains(OAuthFlow.mailSendScope) else { throw PuddleError("Allow Gmail sending in Manage Google Permissions first.") }
            var value: [String: Any] = ["raw": try draft.mime(from: action.account, actionID: action.id).base64URL]
            if let thread = draft.threadID, draft.inReplyTo != nil { value["threadId"] = thread }
            body = value; url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!; method = "POST"; etag = nil
        case .unsubscribe: throw PuddleError("Use the reviewed newsletter client for unsubscribe requests.")
        case .calendarRemoval(let value):
            guard scopes.contains(OAuthFlow.calendarWriteScope) else { throw PuddleError("Allow calendar changes first.") }
            var parts = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(Self.component(value.calendarID))/events/\(Self.component(value.eventID))")!
            parts.queryItems = [URLQueryItem(name: "sendUpdates", value: "all")]
            url = parts.url!; method = "DELETE"; body = [:]; etag = value.etag
        case .mailLabels(let id, let add, let remove):
            guard scopes.contains(OAuthFlow.mailModifyScope) else { throw PuddleError("Allow Gmail organization in Manage Google Permissions first.") }
            url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(Self.component(id))/modify")!
            method = "POST"; body = ["addLabelIds": add, "removeLabelIds": remove]; etag = nil
        case .calendar(let draft):
            guard scopes.contains(OAuthFlow.calendarWriteScope) else { throw PuddleError("Allow calendar changes in Manage Google Permissions first.") }
            let base = "https://www.googleapis.com/calendar/v3/calendars/\(Self.component(draft.calendarID))/events"
            var parts = URLComponents(string: base + (draft.eventID.map { "/" + Self.component($0) } ?? ""))!
            parts.queryItems = [URLQueryItem(name: "sendUpdates", value: "all")]
            url = parts.url!; method = draft.eventID == nil ? "POST" : "PATCH"; body = try draft.apiBody(actionID: action.id); etag = draft.etag
        }
        let token = try await session.accessToken(expectedAccount: action.account)
        try Task.checkCancellation()
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = method; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-Match") }
        if method != "DELETE" { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        // Writes are dispatched exactly once. Transport failures require reconciliation, never automatic retry.
        let (data, response) = try await transport.send(request)
        if response.statusCode == 412 { throw PuddleError("The event changed elsewhere. Refresh it and review a new proposal.") }
        try checkHTTP(response, data: data, service: "Google")
        if case .calendarRemoval(let value) = action.payload { return ActionResult(id: value.eventID, url: action.sourceURL) }
        struct Result: Decodable { let id: String; let threadId: String?; let htmlLink: URL?; let etag: String? }
        let result = try JSONDecoder().decode(Result.self, from: data)
        let source: URL?
        switch action.payload {
        case .email, .mailLabels: source = URL(string: "https://mail.google.com/mail/u/0/#all/\(Self.component(result.threadId ?? result.id))")
        case .unsubscribe: source = nil
        case .calendarRemoval: source = nil
        case .calendar: source = result.htmlLink.flatMap { $0.scheme == "https" && ["calendar.google.com", "www.google.com"].contains($0.host ?? "") ? $0 : nil }
        }
        return ActionResult(id: result.id, url: source, etag: result.etag)
    }
    private static func component(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }

    /// Positive evidence only. Missing/changed records leave the action uncertain;
    /// this method never dispatches, resets or retries a provider write.
    public func reconcile(_ action: ActionProposal) async throws -> ActionResult? {
        guard action.status == .uncertain, action.provider != .outlook,
              action.authorizedDigest == action.digest, try await session.account()?.email == action.account else {
            throw PuddleError("Connect the reviewed account before checking this uncertain action.")
        }
        switch action.payload {
        case .email:
            let identity = "<puddle-\(action.id.uuidString.lowercased())@puddle.local>"
            var parts = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
            parts.queryItems = [URLQueryItem(name: "q", value: "in:sent rfc822msgid:\(identity)"), URLQueryItem(name: "maxResults", value: "2")]
            struct Matches: Decodable { struct Message: Decodable { let id: String }; let messages: [Message]?; let nextPageToken: String? }
            guard let data = try await reconciliationRead(parts.url!, account: action.account) else { return nil }
            let matches = try JSONDecoder().decode(Matches.self, from: data)
            guard let messages = matches.messages, messages.count == 1, matches.nextPageToken == nil else { return nil }
            let id = messages[0].id
            var messageURL = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(Self.component(id))")!
            messageURL.queryItems = [URLQueryItem(name: "format", value: "metadata"), URLQueryItem(name: "metadataHeaders", value: "Message-ID")]
            struct Message: Decodable {
                struct Payload: Decodable { struct Header: Decodable { let name: String; let value: String }; let headers: [Header]? }
                let id: String; let threadId: String?; let labelIds: [String]?; let payload: Payload?
            }
            guard let body = try await reconciliationRead(messageURL.url!, account: action.account) else { return nil }
            let record = try JSONDecoder().decode(Message.self, from: body)
            guard record.id == id, record.labelIds?.contains("SENT") == true,
                  record.payload?.headers?.contains(where: { $0.name.lowercased() == "message-id" && $0.value == identity }) == true else { return nil }
            return ActionResult(id: id, url: URL(string: "https://mail.google.com/mail/u/0/#sent/\(Self.component(record.threadId ?? id))"))
        case .calendar(let draft) where draft.eventID == nil:
            let id = "puddle" + action.id.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(Self.component(draft.calendarID))/events/\(id)")!
            guard let data = try await reconciliationRead(url, account: action.account) else { return nil }
            struct Event: Decodable {
                struct Time: Decodable { let dateTime: String? }
                struct Attendee: Decodable { let email: String? }
                let id: String; let summary: String?; let status: String?; let start: Time?; let end: Time?
                let description: String?; let location: String?; let attendees: [Attendee]?; let htmlLink: URL?; let etag: String?
            }
            let event = try JSONDecoder().decode(Event.self, from: data)
            guard event.id == id, ["confirmed", "tentative"].contains(event.status ?? ""), event.summary == draft.title,
                  event.start?.dateTime.flatMap(AssistantDates.parse)?.ISO8601Format() == draft.start.ISO8601Format(),
                  event.end?.dateTime.flatMap(AssistantDates.parse)?.ISO8601Format() == draft.end.ISO8601Format(),
                  (event.description ?? "") == draft.notes, (event.location ?? "") == draft.location,
                  Set((event.attendees ?? []).compactMap(\.email).map { $0.lowercased() }) == Set(MailDraft.addresses(draft.attendees).map { $0.lowercased() }) else { return nil }
            let source = event.htmlLink.flatMap { $0.scheme == "https" && ["calendar.google.com", "www.google.com"].contains($0.host ?? "") ? $0 : nil }
            return ActionResult(id: id, url: source, etag: event.etag)
        default: return nil
        }
    }
    private func reconciliationRead(_ url: URL, account: String) async throws -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(try await session.accessToken(expectedAccount: account))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await RetryingTransport(base: transport).sendBounded(request, maximumBytes: 1024 * 1024, until: nil)
        if response.statusCode == 404 { return nil }
        try checkHTTP(response, data: data, service: "Google")
        return data
    }
}
