import Foundation

public enum WorkService: String, Codable, CaseIterable, Identifiable, Sendable {
    case github, jira, confluence
    public var id: String { rawValue }
    public var title: String { switch self { case .github: "GitHub"; case .jira: "Jira"; case .confluence: "Confluence" } }
    public var icon: String { switch self { case .github: "chevron.left.forwardslash.chevron.right"; case .jira: "checklist"; case .confluence: "books.vertical" } }
}
public struct WorkItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String { service.rawValue + ":" + locator }
    public let service: WorkService
    public let locator: String
    public let title: String
    public let detail: String
    public let excerpt: String
    public let url: URL
    public init(service: WorkService, locator: String, title: String, detail: String = "", excerpt: String = "", url: URL) {
        self.service = service; self.locator = locator; self.title = String(title.prefix(500))
        self.detail = String(detail.prefix(500)); self.excerpt = String(excerpt.prefix(1000)); self.url = url
    }
}
public struct WorkReadResult: Codable, Sendable {
    public let service: WorkService
    public let title: String
    public let text: String
    public let items: [WorkItem]
    public let hasMore: Bool
    public let scope: String
    public let fetchedAt: Date
    public let references: [SourceReference]
    public init(service: WorkService, title: String, text: String = "", items: [WorkItem] = [], hasMore: Bool = false, scope: String, references: [SourceReference] = []) {
        self.service = service; self.title = String(title.prefix(500)); self.text = String(text.prefix(12_000)); self.items = items
        self.hasMore = hasMore || text.count > 12_000; self.scope = scope; fetchedAt = Date()
        self.references = references.isEmpty ? items.map { SourceReference(title: $0.title, url: $0.url) } : references
    }
    public var encoded: String {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return String(decoding: (try? encoder.encode(self)) ?? Data("{}".utf8), as: UTF8.self)
    }
}
public struct GitHubConnectionInfo: Equatable, Sendable {
    public let login: String
    public let repositories: [String]
    public let verifiedAt: Date
}
public struct AtlassianSite: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let url: URL
    public init(id: String, name: String, url: URL) { self.id = id; self.name = name; self.url = url }
}
public struct AtlassianConnectionInfo: Equatable, Sendable {
    public let sites: [AtlassianSite]
    public let selectedSiteID: String?
    public let services: Set<WorkService>
    public let verifiedAt: Date
    public var selectedSite: AtlassianSite? { sites.first { $0.id == selectedSiteID } }
}

/// Immutable wire values keep untrusted JSON and tool arguments Sendable across connector actors.
public indirect enum ConnectorJSON: Codable, Sendable {
    case object([String: ConnectorJSON]), array([ConnectorJSON]), string(String), number(Double), bool(Bool), null
    public subscript(_ key: String) -> Self? { if case .object(let value) = self { return value[key] }; return nil }
    public var array: [Self]? { if case .array(let value) = self { return value }; return nil }
    public var string: String? {
        switch self { case .string(let value): value; case .number(let value): value.rounded() == value ? String(format: "%.0f", value) : String(value); default: nil }
    }
    public var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var number: Double? { if case .number(let value) = self { return value }; return nil }
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode([String: Self].self) { self = .object(item) }
        else { self = .array(try value.decode([Self].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }
    public var data: Data { (try? JSONEncoder().encode(self)) ?? Data("null".utf8) }
    public var text: String { String(decoding: data, as: UTF8.self) }
    public static func strings(_ values: [String]) -> Self { .array(values.map(Self.string)) }
}

enum WorkConnectorHTTP {
    static func valid(_ url: URL, hosts: Set<String>) -> Bool {
        url.scheme == "https" && url.host.map(hosts.contains) == true && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil && url.fragment == nil
    }
    static func send(_ request: URLRequest, transport: any HTTPTransport, service: String, hosts: Set<String>, until: (@Sendable (Data, HTTPURLResponse) -> Bool)? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, valid(url, hosts: hosts) else { throw PuddleError("The \(service) request has an untrusted destination.") }
        try Task.checkCancellation()
        let (data, response) = try await transport.sendBounded(request, maximumBytes: 2 * 1024 * 1024, until: until)
        try Task.checkCancellation()
        guard response.url == request.url else { throw PuddleError("\(service) redirected the request. Reconnect through the official service.") }
        guard data.count <= 2 * 1024 * 1024 else { throw PuddleError("\(service) returned too much data. Narrow the request.") }
        guard (200..<300).contains(response.statusCode) else {
            let message: String
            switch response.statusCode {
            case 401: message = "\(service) authorization expired or was revoked. Reconnect in Connections."
            case 403: message = "\(service) denied access. Check account permissions, token scopes and organization approval."
            case 404: message = "\(service) could not find that resource, or your account cannot view it."
            case 429: message = "\(service) is rate limiting requests. Try again later."
            default: message = "\(service) returned HTTP \(response.statusCode). Check the connection or narrow your query."
            }
            throw HTTPServiceError(statusCode: response.statusCode, retryAfter: retryDelay(response), message: message)
        }
        return (data, response)
    }
    static func decode(_ data: Data) throws -> ConnectorJSON { try JSONDecoder().decode(ConnectorJSON.self, from: data) }
    static func credential(_ text: String) -> Bool { !text.isEmpty && text.utf8.count <= 32_000 && !text.contains(where: \.isWhitespace) }
}
