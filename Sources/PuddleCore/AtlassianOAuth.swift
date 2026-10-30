import Foundation

public struct AtlassianOAuthAttempt: Sendable {
    public let state: String
    let verifier: String
    let clientID: String
    let redirect: URL
    let scopes: [String]
    let services: Set<WorkService>
    let endpoints: AtlassianOAuthEndpoints
    public let authorizationURL: URL
    public func code(from callback: URL) throws -> String {
        guard callback.scheme == redirect.scheme, callback.host == redirect.host, callback.port == redirect.port, callback.path == redirect.path,
              callback.user == nil, callback.password == nil, callback.fragment == nil,
              let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { throw PuddleError("Atlassian returned an unexpected callback.") }
        let items = parts.queryItems ?? []
        func one(_ key: String) -> String? { let values = items.filter { $0.name == key }; return values.count == 1 ? values[0].value : nil }
        guard one("state") == state else { throw PuddleError("Atlassian sign-in could not be verified. Try again.") }
        guard !items.contains(where: { $0.name == "error" }), let code = one("code"), !code.isEmpty, code.count <= 16_000 else { throw PuddleError("Atlassian authorization was declined or could not be completed.") }
        return code
    }
}
struct AtlassianOAuthEndpoints: Codable, Sendable {
    let issuer: URL
    let authorize: URL
    let token: URL
    let registration: URL
}
struct AtlassianCredentials: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    let clientID: String
    let endpoints: AtlassianOAuthEndpoints
    let scopes: [String]
    let services: Set<WorkService>
    var sites: [AtlassianSite] = []
    var selectedSiteID: String?
    var verifiedAt = Date()
    var info: AtlassianConnectionInfo { AtlassianConnectionInfo(sites: sites, selectedSiteID: selectedSiteID, services: services, verifiedAt: verifiedAt) }
}

actor AtlassianAuthorization {
    static let resource = URL(string: "https://mcp.atlassian.com/v2/mcp")!
    private let secrets: any SecretStore
    private let transport: any HTTPTransport
    private let key = "atlassian-connector-v1"
    private var revision = UUID()
    private var refreshing: Task<AtlassianCredentials, Error>?
    init(secrets: any SecretStore, transport: any HTTPTransport) { self.secrets = secrets; self.transport = transport }
    func load() throws -> AtlassianCredentials? { try secrets.read(key).map { try JSONDecoder().decode(AtlassianCredentials.self, from: $0) } }
    func save(_ value: AtlassianCredentials) throws { try secrets.write(JSONEncoder().encode(value), key: key) }
    func generation() -> UUID { revision }
    func install(_ value: AtlassianCredentials) throws { try save(value); revision = UUID(); refreshing?.cancel(); refreshing = nil }
    func install(_ value: AtlassianCredentials, expected: UUID) throws {
        try Task.checkCancellation()
        guard revision == expected else { throw CancellationError() }
        try install(value)
    }
    func verified(sites: [AtlassianSite], selectedSiteID: String?, at date: Date, expected: UUID) throws -> AtlassianConnectionInfo {
        guard revision == expected, var latest = try load() else { throw CancellationError() }
        latest.sites = sites; latest.selectedSiteID = selectedSiteID; latest.verifiedAt = date
        try save(latest); return latest.info
    }
    func selectSite(_ id: String?) throws -> AtlassianConnectionInfo {
        guard var value = try load(), id == nil || value.sites.contains(where: { $0.id == id }) else { throw PuddleError("Choose a site from this Atlassian connection.") }
        value.selectedSiteID = id; try install(value); return value.info
    }
    func disconnect() throws { try secrets.delete(key); revision = UUID(); refreshing?.cancel(); refreshing = nil }
    private func json(_ url: URL, body: ConnectorJSON? = nil) async throws -> ConnectorJSON {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = body.data }
        let (data, _) = try await WorkConnectorHTTP.send(request, transport: transport, service: "Atlassian sign-in", hosts: ["auth.atlassian.com", "mcp.atlassian.com"])
        return try WorkConnectorHTTP.decode(data)
    }
    func prepare(redirect: URL, services: Set<WorkService>) async throws -> AtlassianOAuthAttempt {
        guard redirect.scheme == "http", redirect.host == "127.0.0.1", (1...65535).contains(redirect.port ?? 0), redirect.path == "/oauth/callback",
              redirect.user == nil, redirect.password == nil, redirect.query == nil, redirect.fragment == nil,
              !services.isEmpty, services.isSubset(of: [.jira, .confluence]) else { throw PuddleError("Choose Jira, Confluence, or both for this connection.") }
        let resource = try await json(URL(string: "https://mcp.atlassian.com/.well-known/oauth-protected-resource/v2/mcp")!)
        guard resource["resource"]?.string == Self.resource.absoluteString,
              let issuerText = resource["authorization_servers"]?.array?.first?.string,
              let issuer = URL(string: issuerText), WorkConnectorHTTP.valid(issuer, hosts: ["auth.atlassian.com", "mcp.atlassian.com"]), issuer.query == nil else {
            throw PuddleError("Atlassian did not advertise a trusted authorization server.")
        }
        var discovery = URLComponents(url: issuer, resolvingAgainstBaseURL: false)!
        discovery.path = "/.well-known/oauth-authorization-server" + (issuer.path == "/" ? "" : issuer.path)
        let metadata = try await json(discovery.url!)
        guard metadata["issuer"]?.string == issuerText,
              let authorizeText = metadata["authorization_endpoint"]?.string, let authorize = URL(string: authorizeText),
              let tokenText = metadata["token_endpoint"]?.string, let token = URL(string: tokenText),
              let registrationText = metadata["registration_endpoint"]?.string, let registration = URL(string: registrationText),
              [authorize, token, registration].allSatisfy({ WorkConnectorHTTP.valid($0, hosts: [issuer.host!]) && $0.query == nil }),
              metadata["code_challenge_methods_supported"]?.array?.contains(where: { $0.string == "S256" }) == true,
              metadata["token_endpoint_auth_methods_supported"]?.array?.contains(where: { $0.string == "none" }) == true else {
            throw PuddleError("Atlassian's authorization server does not support the required public-client PKCE flow.")
        }
        let flow = try OAuthFlow(scopes: [])
        var scopes = ["read:me", "offline_access"]
        if services.contains(.jira) { scopes += ["read:jira:agent-interface", "search:jira:agent-interface"] }
        if services.contains(.confluence) { scopes += ["read:confluence:agent-interface", "search:confluence:agent-interface"] }
        let supported = Set(resource["scopes_supported"]?.array?.compactMap(\.string) ?? [])
        guard Set(scopes).isSubset(of: supported) else { throw PuddleError("Atlassian does not advertise the requested read/search permissions.") }
        let client = try await json(registration, body: .object([
            "client_name": .string("Puddle local assistant"), "redirect_uris": .strings([redirect.absoluteString]),
            "grant_types": .strings(["authorization_code", "refresh_token"]), "response_types": .strings(["code"]),
            "token_endpoint_auth_method": .string("none"), "scope": .string(scopes.joined(separator: " ")),
        ]))
        guard let clientID = client["client_id"]?.string, !clientID.isEmpty, clientID.count <= 4000,
              client["token_endpoint_auth_method"]?.string == nil || client["token_endpoint_auth_method"]?.string == "none" else {
            throw PuddleError("Atlassian could not register this local sign-in client.")
        }
        var url = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect.absoluteString), URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: flow.state), URLQueryItem(name: "code_challenge", value: flow.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "resource", value: Self.resource.absoluteString)]
        return AtlassianOAuthAttempt(state: flow.state, verifier: flow.verifier, clientID: clientID, redirect: redirect, scopes: scopes, services: services,
            endpoints: AtlassianOAuthEndpoints(issuer: issuer, authorize: authorize, token: token, registration: registration), authorizationURL: url.url!)
    }
    private func tokens(parameters: [String: String], endpoints: AtlassianOAuthEndpoints) async throws -> ConnectorJSON {
        guard WorkConnectorHTTP.valid(endpoints.token, hosts: [endpoints.issuer.host ?? ""]) else { throw PuddleError("Stored Atlassian authorization metadata is invalid. Reconnect.") }
        var request = URLRequest(url: endpoints.token, timeoutInterval: 30); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formBody(parameters)
        let (data, _) = try await WorkConnectorHTTP.send(request, transport: transport, service: "Atlassian authorization", hosts: ["auth.atlassian.com", "mcp.atlassian.com"])
        let body = try WorkConnectorHTTP.decode(data)
        guard body["error"] == nil, let access = body["access_token"]?.string, WorkConnectorHTTP.credential(access),
              body["token_type"]?.string?.lowercased() == "bearer",
              let expires = body["expires_in"]?.number, expires > 0, expires <= 366 * 86400 else {
            throw PuddleError("Atlassian did not return a valid expiring access token. Reconnect.")
        }
        return body
    }
    func exchange(_ attempt: AtlassianOAuthAttempt, code: String) async throws -> AtlassianCredentials {
        let result = try await tokens(parameters: ["grant_type": "authorization_code", "client_id": attempt.clientID, "code": code,
            "redirect_uri": attempt.redirect.absoluteString, "code_verifier": attempt.verifier, "resource": Self.resource.absoluteString], endpoints: attempt.endpoints)
        return AtlassianCredentials(accessToken: result["access_token"]!.string!, refreshToken: result["refresh_token"]?.string,
            expiresAt: Date().addingTimeInterval(result["expires_in"]!.number!), clientID: attempt.clientID,
            endpoints: attempt.endpoints, scopes: attempt.scopes, services: attempt.services)
    }
    func token() async throws -> String {
        guard let value = try load() else { throw PuddleError("Connect Jira / Confluence in Connections first.") }
        if value.expiresAt > Date().addingTimeInterval(60) { return value.accessToken }
        if let refreshing { return try await refreshing.value.accessToken }
        guard let refresh = value.refreshToken, WorkConnectorHTTP.credential(refresh) else { throw PuddleError("Atlassian sign-in expired. Reconnect in Connections.") }
        let expected = revision
        let worker = Task { [self] in
            let response = try await tokens(parameters: ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": value.clientID,
                "resource": Self.resource.absoluteString], endpoints: value.endpoints)
            try Task.checkCancellation()
            guard revision == expected else { throw CancellationError() }
            var updated = value; updated.accessToken = response["access_token"]!.string!
            updated.refreshToken = response["refresh_token"]?.string ?? refresh
            updated.expiresAt = Date().addingTimeInterval(response["expires_in"]!.number!)
            try save(updated); return updated
        }
        refreshing = worker
        defer { if revision == expected { refreshing = nil } }
        return try await worker.value.accessToken
    }
}
