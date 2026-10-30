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
}
