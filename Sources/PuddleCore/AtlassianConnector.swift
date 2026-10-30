import Foundation

public actor AtlassianConnector {
    private let auth: AtlassianAuthorization
    private let transport: any HTTPTransport
    private var client: AtlassianMCP?
    private var revision = UUID()
    public init(secrets: any SecretStore = KeychainStore(), transport: any HTTPTransport = URLSessionTransport()) {
        auth = AtlassianAuthorization(secrets: secrets, transport: transport); self.transport = transport
    }
    public func info() async throws -> AtlassianConnectionInfo? { try await auth.load()?.info }
    public func prepare(redirect: URL, services: Set<WorkService>) async throws -> AtlassianOAuthAttempt { try await auth.prepare(redirect: redirect, services: services) }
    private func mcp() -> AtlassianMCP {
        if let client { return client }
        let auth = auth
        let next = AtlassianMCP(transport: transport, authorization: { try await auth.token() }); client = next; return next
    }
    public func finish(_ attempt: AtlassianOAuthAttempt, code: String) async throws -> AtlassianConnectionInfo {
        let expected = revision
        let authGeneration = await auth.generation()
        var credentials = try await auth.exchange(attempt, code: code)
        let token = credentials.accessToken
        let candidate = AtlassianMCP(transport: transport, authorization: { token })
        let sites = try await verify(candidate, services: attempt.services)
        credentials.sites = sites; credentials.selectedSiteID = sites.count == 1 ? sites[0].id : nil; credentials.verifiedAt = Date()
        try Task.checkCancellation(); guard revision == expected else { throw CancellationError() }
        try await auth.install(credentials, expected: authGeneration); client = nil; revision = UUID()
        return credentials.info
    }
    public func disconnect() async throws { try await auth.disconnect(); client = nil; revision = UUID() }
    public func selectSite(_ id: String?) async throws -> AtlassianConnectionInfo {
        let info = try await auth.selectSite(id); revision = UUID(); client = nil; return info
    }
    public func test() async throws -> AtlassianConnectionInfo {
        let authGeneration = await auth.generation()
        guard var value = try await auth.load() else { throw PuddleError("Connect Jira / Confluence first.") }
        let expected = revision, sites = try await verify(mcp(), services: value.services)
        guard revision == expected else { throw CancellationError() }
        value.sites = sites; value.verifiedAt = Date()
        if !sites.contains(where: { $0.id == value.selectedSiteID }) { value.selectedSiteID = sites.count == 1 ? sites[0].id : nil }
        // Preserve a rotated token if verification refreshed the connection.
        return try await auth.verified(sites: value.sites, selectedSiteID: value.selectedSiteID, at: value.verifiedAt, expected: authGeneration)
    }
    private func verify(_ client: AtlassianMCP, services: Set<WorkService>) async throws -> [AtlassianSite] {
        let tools = try await client.tools()
        var required: Set<String> = ["getAccessibleAtlassianResources"]
        if services.contains(.jira) { required.formUnion(["searchJiraIssuesUsingJql", "getJiraIssue"]) }
        if services.contains(.confluence) { required.formUnion(["searchConfluence", "getConfluenceContent"]) }
        guard required.isSubset(of: tools) else { throw PuddleError("Atlassian did not enable the requested read/search tools. Check site access, admin policy and consent permissions.") }
        let result = try await client.call("getAccessibleAtlassianResources", arguments: [:])
        guard let rows = Self.rows(result.value, keys: ["resources", "accessibleResources", "sites", "cloudIds"]) else { throw PuddleError("Atlassian returned an unsupported site list.") }
        var seen = Set<String>()
        let sites: [AtlassianSite] = rows.compactMap { row in
            guard let id = row["id"]?.string ?? row["cloudId"]?.string, id.range(of: #"^[A-Za-z0-9-]{1,100}$"#, options: .regularExpression) != nil,
                  let rawURL = row["url"]?.string, var parts = URLComponents(string: rawURL), parts.scheme == "https",
                  let host = parts.host, host.hasSuffix(".atlassian.net"), parts.user == nil, parts.password == nil,
                  parts.port == nil || parts.port == 443, seen.insert(id).inserted else { return nil }
            parts.path = ""; parts.query = nil; parts.fragment = nil
            guard let url = parts.url else { return nil }
            return AtlassianSite(id: id, name: String((row["name"]?.string ?? host).prefix(200)), url: url)
        }
        guard !sites.isEmpty else { throw PuddleError("No supported Atlassian Cloud site is available to this account.") }
        return Array(sites.prefix(30))
    }
    private func site(_ service: WorkService) async throws -> AtlassianSite {
        guard let value = try await auth.load(), value.services.contains(service), let site = value.info.selectedSite else {
            throw PuddleError("Connect \(service.title) and choose an Atlassian site in Connections first.")
        }
        return site
    }
    static func rows(_ value: ConnectorJSON, keys: [String], depth: Int = 0) -> [ConnectorJSON]? {
        if let array = value.array { return array }
        guard depth < 4 else { return nil }
        for key in keys + ["data", "result"] { if let nested = value[key], let array = rows(nested, keys: keys, depth: depth + 1) { return array } }
        return nil
    }
    private static func unwrap(_ value: ConnectorJSON) -> ConnectorJSON {
        value["data"] ?? value["result"] ?? value
    }
    private func source(site: AtlassianSite, service: WorkService, locator: String) -> URL {
        if service == .jira { return site.url.appendingPathComponent("browse/\(locator)") }
        var parts = URLComponents(url: site.url.appendingPathComponent("wiki/pages/viewpage.action"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "pageId", value: locator)]; return parts.url!
    }
    private func item(_ row: ConnectorJSON, service: WorkService, site: AtlassianSite) -> WorkItem? {
        let outerExcerpt = row["excerpt"]?.string
        let row = row["content"] ?? row
        let fields = row["fields"] ?? row
        guard let locator = (service == .jira ? row["key"]?.string ?? row["id"]?.string : row["id"]?.string), validLocator(locator, service: service),
              let title = fields["summary"]?.string ?? row["title"]?.string else { return nil }
        let detail = fields["status"]?["name"]?.string ?? fields["status"]?.string ?? row["type"]?.string ?? ""
        let excerpt = fields["description"]?.string ?? row["excerpt"]?.string ?? outerExcerpt ?? row["body"]?["value"]?.string ?? ""
        var url = source(site: site, service: service, locator: locator)
        if let raw = row["url"]?.string ?? row["webUrl"]?.string,
           let candidate = URL(string: raw, relativeTo: site.url)?.absoluteURL,
           candidate.absoluteString.count <= 2000, WorkConnectorHTTP.valid(candidate, hosts: [site.url.host!]) { url = candidate }
        return WorkItem(service: service, locator: locator, title: title, detail: detail,
            excerpt: excerpt.contains("<") ? MailText.fromHTML(excerpt) : excerpt, url: url)
    }
    private func validLocator(_ value: String, service: WorkService) -> Bool {
        let pattern = service == .jira ? #"^(?:[A-Za-z][A-Za-z0-9_]*-[0-9]+|[0-9]+)$"# : #"^[0-9]{1,30}$"#
        return value.count <= 100 && value.range(of: pattern, options: .regularExpression) != nil
    }
    public func search(_ query: String, service: WorkService, nativeQuery: Bool = false) async throws -> WorkReadResult {
        guard [.jira, .confluence].contains(service), query.count <= 2000 else { throw PuddleError("Use a Jira or Confluence query under 2,000 characters.") }
        let expected = revision, site = try await site(service)
        guard expected == revision else { throw CancellationError() }
        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let expression: String
        if nativeQuery { expression = query }
        else if service == .jira { expression = phrase.isEmpty ? "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC" : "text ~ \"\(phrase)\" ORDER BY updated DESC" }
        else { expression = phrase.isEmpty ? "type = page ORDER BY lastmodified DESC" : "type = page AND text ~ \"\(phrase)\" ORDER BY lastmodified DESC" }
        var arguments: [String: ConnectorJSON] = ["cloudId": .string(site.id)]
        if service == .jira { arguments["jql"] = .string(expression); arguments["maxResults"] = .number(10); arguments["view"] = .string("compact") }
        else { arguments["cql"] = .string(expression); arguments["limit"] = .number(10) }
        let result = try await mcp().call(service == .jira ? "searchJiraIssuesUsingJql" : "searchConfluence", arguments: arguments)
        guard expected == revision else { throw CancellationError() }
        let root = Self.unwrap(result.value)
        guard let rows = Self.rows(root, keys: service == .jira ? ["issues", "results"] : ["results", "contents"]) else {
            return WorkReadResult(service: service, title: "\(service.title) search", text: result.text, hasMore: true,
                scope: "The server returned unstructured search content. Completeness and result locators could not be determined.", references: [SourceReference(title: site.name, url: site.url)])
        }
        let items = Array(rows.prefix(10).compactMap { item($0, service: service, site: site) })
        let more = rows.count > 10 || root["isLast"]?.bool == false || root["nextPageToken"]?.string != nil || root["_links"]?["next"]?.string != nil || (root["total"]?.number ?? 0) > Double(items.count) || items.count != rows.count
        return WorkReadResult(service: service, title: "\(service.title) search", items: items, hasMore: more,
            scope: "First 10 results from \(site.name). \(service == .jira && phrase.isEmpty && !nativeQuery ? "Empty search shows unresolved work assigned to you." : "Query: " + String(expression.prefix(300))) Full descriptions and later results are not included.")
    }
    public func read(_ locator: String, service: WorkService) async throws -> WorkReadResult {
        guard validLocator(locator, service: service), [.jira, .confluence].contains(service) else { throw PuddleError("Use a Jira issue key/ID or numeric Confluence page ID from search results.") }
        let expected = revision, site = try await site(service)
        guard expected == revision else { throw CancellationError() }
        var arguments: [String: ConnectorJSON] = ["cloudId": .string(site.id)]
        if service == .jira { arguments["issueIdOrKey"] = .string(locator); arguments["view"] = .string("evidence"); arguments["responseContentFormat"] = .string("markdown") }
        else { arguments["content_id"] = .string(locator); arguments["detail"] = .string("full"); arguments["content_format"] = .string("markdown") }
        let result = try await mcp().call(service == .jira ? "getJiraIssue" : "getConfluenceContent", arguments: arguments)
        guard expected == revision else { throw CancellationError() }
        let root = Self.unwrap(result.value), row = root["issue"] ?? root["content"] ?? root
        let title = row["title"]?.string ?? row["fields"]?["summary"]?.string ?? row["summary"]?.string ?? "\(service.title) \(locator)"
        // Keep Jira's status, assignee and other evidence alongside its description.
        var text = service == .jira ? result.text : row["body"]?["value"]?.string ?? row["body"]?["storage"]?["value"]?.string ?? result.text
        if row["body"]?["representation"]?.string == "storage" || row["body"]?["representation"]?.string == "html" || row["body"]?["storage"] != nil { text = MailText.fromHTML(text) }
        return WorkReadResult(service: service, title: title, text: text, scope: "Current content from \(site.name), bounded to 12,000 characters. Comments, attachments and embedded resources may be absent; Jira descriptions may retain structured metadata.",
            references: [SourceReference(title: title, url: item(row, service: service, site: site)?.url ?? source(site: site, service: service, locator: locator))])
    }
}
