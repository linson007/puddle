import Foundation

public protocol BrowserOAuthAttempt: Sendable {
    var state: String { get }
    var authorizationURL: URL { get }
    func code(from callback: URL) throws -> String
}
extension AtlassianOAuthAttempt: BrowserOAuthAttempt {}

public enum MailProvider: String, Codable, CaseIterable, Sendable { case google, outlook }
public struct MicrosoftClientConfiguration: Codable, Equatable, Sendable {
    public let clientID: String
    public let tenant: String
    public init(clientID: String, tenant: String = "common") throws {
        guard UUID(uuidString: clientID) != nil, ["common", "organizations", "consumers"].contains(tenant) || UUID(uuidString: tenant) != nil else { throw PuddleError("Use a Microsoft Desktop public-client application ID and a valid tenant ID or common/organizations/consumers.") }
        self.clientID = clientID; self.tenant = tenant
    }
}
public struct MicrosoftOAuthAttempt: BrowserOAuthAttempt {
    public let state: String
    public let verifier: String
    public let authorizationURL: URL
    public let redirect: URL
    public let scopes: [String]
    public init(configuration: MicrosoftClientConfiguration, callback: URL, allowSend: Bool, allowOrganize: Bool) throws {
        let nonce = try OAuthFlow(scopes: []); state = nonce.state; verifier = nonce.verifier
        var redirect = URLComponents(url: callback, resolvingAgainstBaseURL: false)!
        redirect.host = "localhost"; self.redirect = redirect.url!
        scopes = ["openid", "profile", "offline_access", "User.Read", "Mail.Read"] + (allowSend ? ["Mail.Send"] : []) + (allowOrganize ? ["Mail.ReadWrite"] : [])
        var parts = URLComponents(string: "https://login.microsoftonline.com/\(configuration.tenant)/oauth2/v2.0/authorize")!
        parts.queryItems = [URLQueryItem(name: "client_id", value: configuration.clientID), URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: self.redirect.absoluteString), URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")), URLQueryItem(name: "prompt", value: "select_account"),
            URLQueryItem(name: "state", value: state), URLQueryItem(name: "code_challenge", value: nonce.challenge), URLQueryItem(name: "code_challenge_method", value: "S256")]
        authorizationURL = parts.url!
    }
    public func code(from callback: URL) throws -> String {
        guard callback.scheme == "http", ["localhost", "127.0.0.1"].contains(callback.host ?? ""), callback.port == redirect.port, callback.path == redirect.path,
              callback.user == nil, callback.password == nil, callback.fragment == nil else { throw PuddleError("Microsoft returned an unexpected callback address.") }
        let values = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let states = values.filter { $0.name == "state" }, codes = values.filter { $0.name == "code" }
        guard states.count == 1, states[0].value == state, !values.contains(where: { $0.name == "error" }), codes.count == 1, let code = codes[0].value, !code.isEmpty else { throw PuddleError("Microsoft sign-in was declined or could not be verified. Try again.") }
        return code
    }
}
public struct MicrosoftMailAccount: Codable, Identifiable, Sendable {
    public let id: String
    public let email: String
    public let scopes: Set<String>
}
private struct MicrosoftCredentials: Codable, Sendable {
    let account: MicrosoftMailAccount
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}
public actor MicrosoftMailSession {
    private struct Vault: Codable { var accounts: [MicrosoftCredentials] = []; var activeID: String? }
    private let secrets: any SecretStore
    private let transport: any HTTPTransport
    private var revision = UUID()
    private var refreshing: Task<MicrosoftCredentials, Error>?
    public init(secrets: any SecretStore = KeychainStore(), transport: any HTTPTransport = URLSessionTransport()) { self.secrets = secrets; self.transport = transport }
    public func configuration() throws -> MicrosoftClientConfiguration? { try secrets.read("microsoft-client").map { try JSONDecoder().decode(MicrosoftClientConfiguration.self, from: $0) } }
    public func configure(_ configuration: MicrosoftClientConfiguration) throws {
        _ = try MicrosoftClientConfiguration(clientID: configuration.clientID, tenant: configuration.tenant)
        guard try vault().accounts.isEmpty || self.configuration() == configuration else { throw PuddleError("Disconnect Microsoft accounts before replacing the application ID.") }
        try secrets.write(JSONEncoder().encode(configuration), key: "microsoft-client")
    }
    private func vault() throws -> Vault { try secrets.read("microsoft-accounts").map { try JSONDecoder().decode(Vault.self, from: $0) } ?? Vault() }
    private func save(_ value: Vault) throws { try secrets.write(JSONEncoder().encode(value), key: "microsoft-accounts") }
    public func accounts() throws -> [MicrosoftMailAccount] { try vault().accounts.map(\.account) }
    public func account() throws -> MicrosoftMailAccount? { let value = try vault(); return value.accounts.first { $0.account.id == value.activeID }?.account }
    public func select(_ id: String) throws {
        var value = try vault(); guard value.accounts.contains(where: { $0.account.id == id }) else { throw PuddleError("Connect this Microsoft account first.") }
        revision = UUID(); refreshing?.cancel(); refreshing = nil; value.activeID = id; try save(value)
    }
    public func disconnect() throws {
        var value = try vault(); revision = UUID(); refreshing?.cancel(); refreshing = nil
        value.accounts.removeAll { $0.account.id == value.activeID }; value.activeID = nil
        if value.accounts.isEmpty { try secrets.delete("microsoft-accounts") } else { try save(value) }
    }
    public func exchange(code: String, attempt: MicrosoftOAuthAttempt) async throws {
        guard let config = try configuration() else { throw PuddleError("Configure the Microsoft application ID first.") }
        let expected = revision
        let response = try await token(config: config, fields: ["grant_type": "authorization_code", "code": code, "code_verifier": attempt.verifier, "redirect_uri": attempt.redirect.absoluteString], previous: nil, scopes: attempt.scopes)
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me?$select=id,mail,userPrincipalName")!)
        request.setValue("Bearer \(response.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, http) = try await transport.send(request); try checkHTTP(http, data: data, service: "Microsoft")
        struct Identity: Decodable { let id: String; let mail: String?; let userPrincipalName: String? }
        let identity = try JSONDecoder().decode(Identity.self, from: data), email = identity.mail ?? identity.userPrincipalName ?? ""
        guard !identity.id.isEmpty, MailDraft.validAddress(email) else { throw PuddleError("Microsoft did not return a usable mailbox identity.") }
        let account = MicrosoftMailAccount(id: identity.id, email: email, scopes: response.scopes)
        var value = try vault(); value.accounts.removeAll { $0.account.id == account.id }
        guard value.accounts.count < 10 else { throw PuddleError("Keep up to ten Microsoft accounts.") }
        value.accounts.append(MicrosoftCredentials(account: account, accessToken: response.accessToken, refreshToken: response.refreshToken, expiresAt: response.expiresAt)); value.activeID = account.id
        try Task.checkCancellation(); guard revision == expected else { throw CancellationError() }
        try save(value); revision = UUID()
    }
    private struct TokenResult: Sendable { let accessToken: String; let refreshToken: String; let expiresAt: Date; let scopes: Set<String> }
    private func token(config: MicrosoftClientConfiguration, fields original: [String: String], previous: MicrosoftCredentials?, scopes: [String]) async throws -> TokenResult {
        var fields = original; fields["client_id"] = config.clientID; fields["scope"] = scopes.joined(separator: " ")
        var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/\(config.tenant)/oauth2/v2.0/token")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.httpBody = formBody(fields)
        let (data, http) = try await transport.send(request); try checkHTTP(http, data: data, service: "Microsoft")
        struct Tokens: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Double; let scope: String? }
        let tokens = try JSONDecoder().decode(Tokens.self, from: data)
        let granted = Set((tokens.scope ?? scopes.joined(separator: " ")).split(separator: " ").map { String($0).components(separatedBy: "/").last ?? String($0) })
        guard granted.contains("Mail.Read") || granted.contains("Mail.ReadWrite"), let refresh = tokens.refresh_token ?? previous?.refreshToken, !refresh.isEmpty else { throw PuddleError("Microsoft did not grant mail and offline access. Reconnect and review consent.") }
        return TokenResult(accessToken: tokens.access_token, refreshToken: refresh, expiresAt: Date().addingTimeInterval(tokens.expires_in), scopes: granted)
    }
    public func accessToken(expectedAccountID: String? = nil) async throws -> String {
        let value = try vault()
        guard let current = value.accounts.first(where: { $0.account.id == value.activeID }) else { throw PuddleError("Connect Outlook first.") }
        guard expectedAccountID == nil || current.account.id == expectedAccountID else { throw PuddleError("The Outlook account changed before dispatch. Review the action again.") }
        if current.expiresAt > Date().addingTimeInterval(60) { return current.accessToken }
        let expected = revision
        if let refreshing { let updated = try await refreshing.value; guard revision == expected else { throw CancellationError() }; return updated.accessToken }
        guard let config = try configuration() else { throw PuddleError("Configure the Microsoft app ID again.") }
        let task = Task {
            let result = try await self.token(config: config, fields: ["grant_type": "refresh_token", "refresh_token": current.refreshToken], previous: current, scopes: Array(current.account.scopes) + ["offline_access"])
            return MicrosoftCredentials(account: MicrosoftMailAccount(id: current.account.id, email: current.account.email, scopes: result.scopes), accessToken: result.accessToken, refreshToken: result.refreshToken, expiresAt: result.expiresAt)
        }; refreshing = task
        do {
            let updated = try await task.value; try Task.checkCancellation(); guard revision == expected else { throw CancellationError() }
            var next = try vault(); if let index = next.accounts.firstIndex(where: { $0.account.id == updated.account.id }) { next.accounts[index] = updated }
            try save(next); refreshing = nil; return updated.accessToken
        } catch { if revision == expected { refreshing = nil }; throw error }
    }
}
