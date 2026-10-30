import Foundation
import CryptoKit
import Security

public struct GoogleClientConfiguration: Codable, Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String?
    public init(clientID: String, clientSecret: String? = nil) {
        self.clientID = clientID; self.clientSecret = clientSecret
    }

    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1024 else { throw PuddleError("The Google client JSON is too large. Choose the Desktop app credentials downloaded from Google.") }
        struct Download: Decodable {
            struct Installed: Decodable { let client_id: String; let client_secret: String? }
            let installed: Installed?
        }
        guard let installed = try JSONDecoder().decode(Download.self, from: data).installed,
              installed.client_id.hasSuffix(".apps.googleusercontent.com"),
              !installed.client_id.contains(where: \.isWhitespace) else {
            throw PuddleError("Import the JSON for a Google OAuth Desktop app client, not a Web application client.")
        }
        return Self(clientID: installed.client_id, clientSecret: installed.client_secret)
    }

    public static func load(from url: URL) throws -> Self {
        try parse(Data(contentsOf: url, options: .mappedIfSafe))
    }
}

public struct GoogleAccount: Codable, Equatable, Sendable {
    public let id: String
    public let email: String
    public let name: String?
}

public struct GoogleCredentials: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scope: String
    public var account: GoogleAccount?
    public init(accessToken: String, refreshToken: String, expiresAt: Date, scope: String, account: GoogleAccount? = nil) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiresAt = expiresAt; self.scope = scope; self.account = account
    }
}

public protocol SecretStore: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data, key: String) throws
    func delete(_ key: String) throws
}

public struct KeychainStore: SecretStore {
    private let service: String
    public init(service: String = Bundle.main.bundleIdentifier ?? "app.puddle.mac") { self.service = service }
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: key,
         kSecAttrSynchronizable as String: false]
    }
    public func read(_ key: String) throws -> Data? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw keychainError(status) }
        return data
    }
    public func write(_ data: Data, key: String) throws {
        let status = SecItemUpdate(query(key) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = query(key)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecSuccess else { throw keychainError(added) }
        } else if status != errSecSuccess { throw keychainError(status) }
    }
    public func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }
    private func keychainError(_ status: OSStatus) -> PuddleError {
        PuddleError("macOS Keychain could not access Puddle’s credentials (\(status)). Unlock your login keychain and try again.")
    }
}

public struct OAuthFlow: Sendable {
    public static let scope = "https://www.googleapis.com/auth/gmail.readonly"
    public static let calendarScope = "https://www.googleapis.com/auth/calendar.events.readonly"
    public static let mailSendScope = "https://www.googleapis.com/auth/gmail.send"
    public static let mailModifyScope = "https://www.googleapis.com/auth/gmail.modify"
    public static let calendarWriteScope = "https://www.googleapis.com/auth/calendar.events"
    public static let calendarListScope = "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
    public static func expandedScopes(_ scopes: Set<String>) -> Set<String> {
        var result = scopes
        if scopes.contains(mailModifyScope) { result.formUnion([scope, mailSendScope]) }
        if scopes.contains(calendarWriteScope) || scopes.contains("https://www.googleapis.com/auth/calendar") || scopes.contains("https://www.googleapis.com/auth/calendar.readonly") { result.insert(calendarScope) }
        if scopes.contains("https://www.googleapis.com/auth/calendar") { result.insert(calendarWriteScope) }
        return result
    }
    public static let identityScopes = ["openid", "https://www.googleapis.com/auth/userinfo.email", "https://www.googleapis.com/auth/userinfo.profile"]
    public let verifier: String
    public let state: String
    public let scopes: [String]
    public var challenge: String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URL }
    public init(verifier: String, state: String, scopes: [String] = [Self.scope]) {
        self.verifier = verifier; self.state = state; self.scopes = Self.requestedScopes(scopes)
    }
    public init(scopes: [String] = [Self.scope]) throws {
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw PuddleError("macOS could not start secure sign-in. Try again.")
            }
            return Data(bytes).base64URL
        }
        verifier = try random(); state = try random()
        self.scopes = Self.requestedScopes(scopes)
    }
    private static func requestedScopes(_ services: [String]) -> [String] {
        var seen = Set<String>()
        return (identityScopes + services).filter { seen.insert($0).inserted }
    }
    public func authorizationURL(client: GoogleClientConfiguration, redirect: URL) -> URL {
        var parts = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return parts.url!
    }
    public func code(from callback: URL) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            let matches = items.filter { $0.name == name }
            return matches.count == 1 ? matches[0].value : nil
        }
        guard value("state") == state else { throw PuddleError("Sign-in could not be verified. Try connecting again.") }
        if value("error") != nil { throw PuddleError("Google sign-in was declined. Your inbox has not been connected.") }
        guard let code = value("code"), !code.isEmpty else { throw PuddleError("Google did not return a sign-in code.") }
        return code
    }
}

extension Data {
    public var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }
}

public actor GoogleSession {
    private let store: any SecretStore
    private let transport: any HTTPTransport
    private var refreshTask: Task<GoogleCredentials, Error>?
    private var generation = UUID()
    public init(store: any SecretStore = KeychainStore(), transport: any HTTPTransport = URLSessionTransport()) {
        self.store = store; self.transport = transport
    }
    public func configuration() throws -> GoogleClientConfiguration? {
        try store.read("google-client").map { try JSONDecoder().decode(GoogleClientConfiguration.self, from: $0) }
    }
    public func configure(_ client: GoogleClientConfiguration) throws {
        try store.write(JSONEncoder().encode(client), key: "google-client")
    }
    /// App-level provisioning is only needed once. Preserve a client's existing
    /// configuration and account when a new build is installed.
    public func configureIfNeeded(_ client: GoogleClientConfiguration?) throws -> Bool {
        if try configuration() != nil { return true }
        guard let client else { return false }
        try configure(client)
        return true
    }
    public func hasCredentials() throws -> Bool { try store.read("google-tokens") != nil }
    public func account() throws -> GoogleAccount? {
        guard let data = try store.read("google-tokens") else { return nil }
        return try JSONDecoder().decode(GoogleCredentials.self, from: data).account
    }
    public func accounts() throws -> [GoogleAccount] {
        var known = try storedAccounts()
        if let data = try store.read("google-tokens"), let current = try? JSONDecoder().decode(GoogleCredentials.self, from: data), let account = current.account {
            known.removeAll { $0.account?.id == account.id }; known.append(current)
        }
        return known.compactMap(\.account).sorted { $0.email < $1.email }
    }
    private func storedAccounts() throws -> [GoogleCredentials] {
        try store.read("google-accounts").map { try JSONDecoder().decode([GoogleCredentials].self, from: $0) } ?? []
    }
    private func retain(_ credentials: GoogleCredentials) throws {
        guard let account = credentials.account else { return }
        var known = try storedAccounts(); known.removeAll { $0.account?.id == account.id }
        guard known.count < 10 else { throw PuddleError("Keep up to ten Google accounts. Disconnect an unused account before adding another.") }
        known.append(credentials); try store.write(JSONEncoder().encode(known), key: "google-accounts")
    }
    public func selectAccount(email: String) throws {
        guard let chosen = try storedAccounts().first(where: { $0.account?.email == email }) else { throw PuddleError("Connect this Google account first.") }
        if let data = try store.read("google-tokens") { try retain(JSONDecoder().decode(GoogleCredentials.self, from: data)) }
        generation = UUID(); refreshTask?.cancel(); refreshTask = nil
        try store.write(JSONEncoder().encode(chosen), key: "google-tokens")
    }
    public func grantedScopes() throws -> Set<String> {
        guard let data = try store.read("google-tokens") else { return [] }
        return OAuthFlow.expandedScopes(Set(try JSONDecoder().decode(GoogleCredentials.self, from: data).scope.split(separator: " ").map(String.init)))
    }
    public func disconnect() throws {
        generation = UUID(); refreshTask?.cancel(); refreshTask = nil
        if let current = try account() {
            let remaining = try storedAccounts().filter { $0.account?.id != current.id }
            if remaining.isEmpty { try store.delete("google-accounts") }
            else { try store.write(JSONEncoder().encode(remaining), key: "google-accounts") }
        }
        try store.delete("google-tokens")
    }
    public func exchange(code: String, flow: OAuthFlow, redirect: URL) async throws {
        guard let client = try configuration() else { throw PuddleError("Import a Google Desktop OAuth client first.") }
        let expectedGeneration = generation
        var fields = ["client_id": client.clientID, "code": code, "code_verifier": flow.verifier,
                      "redirect_uri": redirect.absoluteString, "grant_type": "authorization_code"]
        if let secret = client.clientSecret { fields["client_secret"] = secret }
        var tokens = try await Self.tokens(fields, transport: transport, previous: nil, requiredScopes: flow.scopes)
        tokens.account = try await Self.identity(access: tokens.accessToken, transport: transport)
        try Task.checkCancellation()
        guard generation == expectedGeneration else { throw CancellationError() }
        if let data = try store.read("google-tokens") { try retain(JSONDecoder().decode(GoogleCredentials.self, from: data)) }
        try retain(tokens)
        try store.write(JSONEncoder().encode(tokens), key: "google-tokens")
        generation = UUID(); refreshTask?.cancel(); refreshTask = nil
    }
    private static func identity(access: String, transport: any HTTPTransport) async throws -> GoogleAccount {
        var request = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw PuddleError("Google could not confirm your account. Connect again and allow access to your email address.")
        }
        struct Identity: Decodable { let sub: String; let email: String; let email_verified: Bool; let name: String? }
        let identity = try JSONDecoder().decode(Identity.self, from: data)
        guard !identity.sub.isEmpty, !identity.email.isEmpty, identity.email_verified else {
            throw PuddleError("Google did not confirm a verified email address. Try another Google account.")
        }
        return GoogleAccount(id: identity.sub, email: identity.email, name: identity.name)
    }
    public func accessToken(rejected: String? = nil, expectedAccount: String? = nil) async throws -> String {
        try Task.checkCancellation()
        guard let data = try store.read("google-tokens") else { throw PuddleError("Connect Google in Connections first.") }
        let credentials = try JSONDecoder().decode(GoogleCredentials.self, from: data)
        guard expectedAccount == nil || credentials.account?.email == expectedAccount else { throw PuddleError("The Google account changed before dispatch. Review the action again.") }
        if credentials.expiresAt > Date().addingTimeInterval(60), credentials.accessToken != rejected {
            return credentials.accessToken
        }
        if let refreshTask {
            let expectedGeneration = generation
            let updated = try await refreshTask.value
            try Task.checkCancellation()
            guard generation == expectedGeneration else { throw CancellationError() }
            return updated.accessToken
        }
        guard let client = try configuration() else { throw PuddleError("Import your Google OAuth client again.") }
        let expectedGeneration = generation
        let transport = self.transport
        let task = Task {
            var fields = ["client_id": client.clientID, "refresh_token": credentials.refreshToken,
                          "grant_type": "refresh_token"]
            if let secret = client.clientSecret { fields["client_secret"] = secret }
            return try await Self.tokens(fields, transport: transport, previous: credentials,
                                         requiredScopes: credentials.scope.split(separator: " ").map(String.init))
        }
        refreshTask = task
        do {
            let updated = try await task.value
            try Task.checkCancellation()
            guard generation == expectedGeneration else { throw CancellationError() }
            try retain(updated)
            try store.write(JSONEncoder().encode(updated), key: "google-tokens")
            refreshTask = nil
            return updated.accessToken
        } catch {
            if generation == expectedGeneration { refreshTask = nil }
            throw error
        }
    }
    private static func tokens(_ fields: [String: String], transport: any HTTPTransport,
                               previous: GoogleCredentials?, requiredScopes: [String]) async throws -> GoogleCredentials {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(fields)
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw PuddleError("Google could not complete sign-in. Reconnect in Connections. If your OAuth app is in Testing, check its test users and token expiry.")
        }
        struct Tokens: Decodable {
            let access_token: String; let refresh_token: String?; let expires_in: Double; let scope: String?
        }
        let tokens = try JSONDecoder().decode(Tokens.self, from: data)
        let scope = tokens.scope ?? previous?.scope ?? requiredScopes.joined(separator: " ")
        var granted = OAuthFlow.expandedScopes(Set(scope.split(separator: " ").map(String.init)))
        if granted.contains("https://www.googleapis.com/auth/calendar.readonly") { granted.insert(OAuthFlow.calendarScope) }
        let services = Set(requiredScopes).intersection([OAuthFlow.scope, OAuthFlow.calendarScope])
        // Google lets people approve services individually. Keep the services
        // they granted available instead of rejecting the whole connection.
        let allowed = previous == nil ? !services.isDisjoint(with: granted) : Set(requiredScopes).isSubset(of: granted)
        guard allowed else {
            throw PuddleError("Requested read access was not granted. Connect again and allow the mail/calendar permissions you selected.")
        }
        guard let refresh = tokens.refresh_token ?? previous?.refreshToken, !refresh.isEmpty else {
            throw PuddleError("Google did not grant background access. Reconnect Google and accept the consent screen.")
        }
        return GoogleCredentials(accessToken: tokens.access_token, refreshToken: refresh,
                                 expiresAt: Date().addingTimeInterval(tokens.expires_in), scope: scope, account: previous?.account)
    }
}
