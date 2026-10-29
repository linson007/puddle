import XCTest
import Foundation
@testable import PuddleCore

final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    func write(_ data: Data, key: String) throws { lock.withLock { values[key] = data } }
    func delete(_ key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

actor FixtureTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, Int)
    private let handler: Handler
    private(set) var requests: [URLRequest] = []
    init(_ handler: @escaping Handler) { self.handler = handler }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (data, status) = try await handler(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
private func mailFixture(id: String = "m1", body: String = "Please review by Friday.") throws -> Data {
    try json(["id": id, "threadId": "t\(id)", "labelIds": ["INBOX", "UNREAD"],
              "internalDate": "1793200000000", "snippet": "Please review by Friday.",
              "payload": ["mimeType": "text/plain", "headers": [
                ["name": "Subject", "value": "Review request"], ["name": "From", "value": "Maya <maya@example.test>"]],
                          "body": ["data": Data(body.utf8).base64URL]]])
}
private func session(transport: any HTTPTransport, expired: Bool = false) throws -> (GoogleSession, MemorySecrets) {
    let secrets = MemorySecrets()
    try secrets.write(JSONEncoder().encode(GoogleClientConfiguration(clientID: "test.apps.googleusercontent.com", clientSecret: "desktop-client")), key: "google-client")
    try secrets.write(JSONEncoder().encode(GoogleCredentials(accessToken: "access", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(expired ? -10 : 3600), scope: OAuthFlow.scope)), key: "google-tokens")
    return (GoogleSession(store: secrets, transport: transport), secrets)
}

final class OAuthTests: XCTestCase {
    func testPKCEAgainstRFC7636Vector() {
        let flow = OAuthFlow(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "state")
        XCTAssertEqual(flow.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
    func testGeneratedSecretsHaveSufficientEntropyAndURLSafeAlphabet() throws {
        let first = try OAuthFlow(); let second = try OAuthFlow()
        XCTAssertEqual(first.verifier.count, 43)
        XCTAssertNotEqual(first.verifier, second.verifier)
        XCTAssertNotEqual(first.state, second.state)
        XCTAssertNil(first.verifier.range(of: "[^A-Za-z0-9_-]", options: .regularExpression))
    }
    func testAuthorizationRequestsIdentityReadOnlyGmailAndPKCE() throws {
        let flow = OAuthFlow(verifier: "verifier", state: "state")
        let url = flow.authorizationURL(client: .init(clientID: "test.apps.googleusercontent.com"), redirect: URL(string: "http://127.0.0.1:4321/")!)
        let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(Set(fields["scope"]!.split(separator: " ").map(String.init)), Set(OAuthFlow.identityScopes + [OAuthFlow.scope]))
        XCTAssertFalse(fields["scope"]!.contains("gmail.send"))
        XCTAssertEqual(fields["code_challenge_method"], "S256")
        XCTAssertEqual(fields["access_type"], "offline")
        XCTAssertEqual(fields["redirect_uri"], "http://127.0.0.1:4321/")
    }
    func testDesktopClientImportRejectsWebClient() throws {
        let config = try GoogleClientConfiguration.parse(json(["installed": ["client_id": "test.apps.googleusercontent.com", "client_secret": "secret"]]))
        XCTAssertEqual(config.clientID, "test.apps.googleusercontent.com")
        XCTAssertThrowsError(try GoogleClientConfiguration.parse(json(["web": ["client_id": "test.apps.googleusercontent.com"]])))
        XCTAssertThrowsError(try GoogleClientConfiguration.parse(json(["installed": ["client_id": "not-google"]])))
    }
    func testCallbackRequiresUniqueMatchingStateAndCode() throws {
        let flow = OAuthFlow(verifier: "verifier", state: "correct")
        XCTAssertEqual(try flow.code(from: URL(string: "http://127.0.0.1/?state=correct&code=a%2Bb")!), "a+b")
        for query in ["state=wrong&code=code", "state=correct&state=correct&code=code", "state=correct", "state=correct&code=a&code=b", "state=correct&error=access_denied"] {
            XCTAssertThrowsError(try flow.code(from: URL(string: "http://127.0.0.1/?\(query)")!))
        }
    }
    func testFormEncodingDoesNotConfusePlusAndAmpersand() {
        XCTAssertEqual(String(decoding: formBody(["code": "a+b&c=d space"]), as: UTF8.self), "code=a%2Bb%26c%3Dd%20space")
    }
    func testRefreshPreservesRefreshTokenAndSavesNewAccessToken() async throws {
        let transport = FixtureTransport { _ in (try json(["access_token": "updated", "expires_in": 3600]), 200) }
        let (google, secrets) = try session(transport: transport, expired: true)
        let access = try await google.accessToken()
        XCTAssertEqual(access, "updated")
        let saved = try JSONDecoder().decode(GoogleCredentials.self, from: XCTUnwrap(try secrets.read("google-tokens")))
        XCTAssertEqual(saved.refreshToken, "refresh")
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertTrue(String(decoding: request.httpBody!, as: UTF8.self).contains("grant_type=refresh_token"))
    }
    func testConcurrentRefreshUsesOneTokenRequest() async throws {
        let transport = FixtureTransport { _ in
            try await Task.sleep(for: .milliseconds(40))
            return (try json(["access_token": "updated", "expires_in": 3600]), 200)
        }
        let (google, _) = try session(transport: transport, expired: true)
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await google.accessToken() } }
            var result: [String] = []
            for try await token in group { result.append(token) }
            return result
        }
        XCTAssertEqual(Set(tokens), ["updated"])
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }
    func testExchangeRejectsMissingReadPermission() async throws {
        let transport = FixtureTransport { _ in (try json(["access_token": "new", "refresh_token": "refresh", "expires_in": 3600, "scope": "email"]), 200) }
        let secrets = MemorySecrets()
        let google = GoogleSession(store: secrets, transport: transport)
        try await google.configure(.init(clientID: "test.apps.googleusercontent.com"))
        do {
            try await google.exchange(code: "code", flow: OAuthFlow(verifier: "verifier", state: "state"), redirect: URL(string: "http://127.0.0.1:4321/")!)
            XCTFail("Should require Gmail read access")
        } catch { XCTAssertTrue(error.localizedDescription.contains("read access")) }
        XCTAssertNil(try secrets.read("google-tokens"))
    }
    func testExchangeUsesPKCEAndPersistsGrantedTokens() async throws {
        let transport = FixtureTransport { request in
            if request.url?.host == "openidconnect.googleapis.com" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new")
                XCTAssertNil(request.url?.query)
                return (try json(["sub": "user-one", "email": "you@example.test", "email_verified": true, "name": "You"]), 200)
            }
            let body = String(decoding: request.httpBody!, as: UTF8.self)
            XCTAssertTrue(body.contains("code_verifier=test-verifier"))
            XCTAssertTrue(body.contains("grant_type=authorization_code"))
            XCTAssertTrue(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A4321%2F"))
            return (try json(["access_token": "new", "refresh_token": "refresh-new", "expires_in": 3600, "scope": OAuthFlow.scope]), 200)
        }
        let secrets = MemorySecrets()
        let google = GoogleSession(store: secrets, transport: transport)
        try await google.configure(.init(clientID: "test.apps.googleusercontent.com"))
        try await google.exchange(code: "code", flow: OAuthFlow(verifier: "test-verifier", state: "state"), redirect: URL(string: "http://127.0.0.1:4321/")!)
        let access = try await google.accessToken()
        XCTAssertEqual(access, "new")
        XCTAssertNotNil(try secrets.read("google-tokens"))
        let account = try await google.account()
        XCTAssertEqual(account?.email, "you@example.test")
    }
    func testAppClientProvisioningIsOneTimeAndPreservesExistingConfiguration() async throws {
        let secrets = MemorySecrets()
        let google = GoogleSession(store: secrets)
        let absent = try await google.configureIfNeeded(nil)
        XCTAssertFalse(absent)
        let provisioned = try await google.configureIfNeeded(.init(clientID: "first.apps.googleusercontent.com"))
        XCTAssertTrue(provisioned)
        _ = try await google.configureIfNeeded(.init(clientID: "second.apps.googleusercontent.com"))
        let client = try await google.configuration()
        XCTAssertEqual(client?.clientID, "first.apps.googleusercontent.com")
    }
    func testPartialConsentConnectsOnlyTheGrantedServiceAndConfirmsIdentity() async throws {
        let secrets = MemorySecrets()
        let transport = FixtureTransport { request in
            if request.url?.host == "openidconnect.googleapis.com" {
                return (try json(["sub": "calendar-user", "email": "calendar@example.test", "email_verified": true]), 200)
            }
            return (try json(["access_token": "partial", "refresh_token": "refresh", "expires_in": 3600,
                              "scope": (OAuthFlow.identityScopes + [OAuthFlow.calendarScope]).joined(separator: " ")]), 200)
        }
        let google = GoogleSession(store: secrets, transport: transport)
        try await google.configure(.init(clientID: "test.apps.googleusercontent.com"))
        try await google.exchange(code: "code", flow: OAuthFlow(scopes: [OAuthFlow.scope, OAuthFlow.calendarScope]), redirect: URL(string: "http://127.0.0.1:4321/")!)
        let scopes = try await google.grantedScopes()
        XCTAssertTrue(scopes.contains(OAuthFlow.calendarScope))
        XCTAssertFalse(scopes.contains(OAuthFlow.scope))
        let account = try await google.account()
        XCTAssertEqual(account?.email, "calendar@example.test")
    }
    func testUnverifiedIdentityCannotPersistAccountTokens() async throws {
        let secrets = MemorySecrets()
        let transport = FixtureTransport { request in
            if request.url?.host == "openidconnect.googleapis.com" {
                return (try json(["sub": "user", "email": "unverified@example.test", "email_verified": false]), 200)
            }
            return (try json(["access_token": "new", "refresh_token": "refresh", "expires_in": 3600, "scope": OAuthFlow.scope]), 200)
        }
        let google = GoogleSession(store: secrets, transport: transport)
        try await google.configure(.init(clientID: "test.apps.googleusercontent.com"))
        do {
            try await google.exchange(code: "code", flow: OAuthFlow(), redirect: URL(string: "http://127.0.0.1:4321/")!)
            XCTFail("An unverified Google identity must be refused")
        } catch { XCTAssertTrue(error.localizedDescription.contains("verified email")) }
        XCTAssertNil(try secrets.read("google-tokens"))
    }
    func testDisconnectDuringRefreshCannotRestoreTokens() async throws {
        let transport = FixtureTransport { _ in
            // Ignore task cancellation, like a service that already completed.
            try? await Task.sleep(for: .milliseconds(60))
            return (try json(["access_token": "updated", "expires_in": 3600]), 200)
        }
        let (google, secrets) = try session(transport: transport, expired: true)
        let refresh = Task { try await google.accessToken() }
        try await Task.sleep(for: .milliseconds(10))
        try await google.disconnect()
        do { _ = try await refresh.value; XCTFail("Disconnected session must not return refreshed access") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertNil(try secrets.read("google-tokens"))
    }
    func testDisconnectRemovesTokensButKeepsClient() async throws {
        let transport = FixtureTransport { _ in (Data(), 500) }
        let (google, secrets) = try session(transport: transport)
        try await google.disconnect()
        XCTAssertNil(try secrets.read("google-tokens"))
        XCTAssertNotNil(try secrets.read("google-client"))
    }

    func testDisconnectInvalidatesEverySharedRefreshWaiter() async throws {
        let transport = FixtureTransport { _ in
            try? await Task.sleep(for: .milliseconds(100))
            return (try json(["access_token": "updated", "expires_in": 3600]), 200)
        }
        let (google, secrets) = try session(transport: transport, expired: true)
        let callers = (0..<8).map { _ in Task { try await google.accessToken() } }
        while await transport.requests.isEmpty { await Task.yield() }
        try await Task.sleep(for: .milliseconds(20))
        try await google.disconnect()
        for caller in callers {
            do { _ = try await caller.value; XCTFail("Disconnected callers must not receive tokens") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertNil(try secrets.read("google-tokens"))
    }
}

final class MailTests: XCTestCase {
    func testDecodesUnicodeBodyAndHeaders() throws {
        let message = try GmailMessageDecoder.decode(mailFixture(body: "Hello café — ₹4,500 🌊"))
        XCTAssertEqual(message.body, "Hello café — ₹4,500 🌊")
        XCTAssertEqual(message.subject, "Review request")
        XCTAssertTrue(message.isUnread)
        XCTAssertEqual(message.date.timeIntervalSince1970, 1793200000)
    }
    func testPrefersPlainTextAlternativeAndSkipsAttachmentBody() throws {
        let payload: [String: Any] = ["mimeType": "multipart/mixed", "parts": [
            ["mimeType": "multipart/alternative", "parts": [
                ["mimeType": "text/plain", "body": ["data": Data("Plain email".utf8).base64URL]],
                ["mimeType": "text/html", "body": ["data": Data("<p>HTML duplicate</p>".utf8).base64URL]]]],
            ["mimeType": "text/plain", "filename": "secret.txt", "body": ["data": Data("Attachment secret".utf8).base64URL]]]]
        let message = try GmailMessageDecoder.decode(json(["id": "m", "payload": payload]))
        XCTAssertEqual(message.body, "Plain email")
        XCTAssertEqual(message.attachments, ["secret.txt"])
        XCTAssertEqual(message.subject, "(No subject)")
    }
    func testHTMLIsConvertedToInertTextWithoutScriptsOrTrackingPixels() {
        let html = "<head><style>hidden</style></head><p>Hello &amp; welcome</p><script>alert('secret')</script><img src='https://tracking.example.test/pixel'><p>Cost: &#x20B9;5 &#128578;</p>"
        let text = MailText.fromHTML(html)
        XCTAssertTrue(text.contains("Hello & welcome"))
        XCTAssertTrue(text.contains("₹5 🙂"))
        XCTAssertFalse(text.contains("secret")); XCTAssertFalse(text.contains("tracking")); XCTAssertFalse(text.contains("hidden"))
    }
    func testMissingBodyIsClearlyMarkedAsPreview() throws {
        let message = try GmailMessageDecoder.decode(json(["id": "m", "snippet": "Preview only"]));
        XCTAssertTrue(message.body.contains("full body unavailable"))
        XCTAssertTrue(message.body.contains("Preview only"))
    }
    func testFirstSyncIsBaselineAndLaterSyncDetectsArrivals() {
        var state = AppSnapshot()
        let one = MailMessage(id: "one", subject: "One", sender: "Maya", body: "body")
        XCTAssertTrue(state.merge([one]).isEmpty)
        XCTAssertFalse(state.messages[0].isNew)
        state.messages[0].summary = "Keep this summary"
        let two = MailMessage(id: "two", subject: "Two", sender: "Sam", body: "body")
        let arrivals = state.merge([one, two, two])
        XCTAssertEqual(arrivals.map(\.id), ["two"])
        XCTAssertEqual(state.messages.count, 2)
        XCTAssertEqual(state.messages.first { $0.id == "one" }?.summary, "Keep this summary")
        XCTAssertTrue(state.messages.first { $0.id == "two" }!.isNew)
        XCTAssertTrue(state.merge([one, two]).isEmpty)
        state.merge([two])
        XCTAssertEqual(state.messages.map(\.id), ["two"])
    }
    func testSnapshotSurvivesRestartWithPrivateFilePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(directory: directory)
        var state = AppSnapshot(); state.account = "you@example.test"
        state.merge([MailMessage(id: "one", subject: "One", sender: "Maya", body: "private")])
        try store.save(state)
        let restored = try store.load()
        XCTAssertEqual(restored.account, state.account)
        XCTAssertEqual(restored.messages, state.messages)
        XCTAssertTrue(restored.mergeAfterRestartHasNoArrivals())
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("state.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    func testEmptyGmailInboxIsAValidSync() async throws {
        let transport = FixtureTransport { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (try json(["resultSizeEstimate": 0]), 200)
        }
        let (google, _) = try session(transport: transport)
        let messages = try await GmailClient(session: google, transport: transport).inbox()
        XCTAssertTrue(messages.isEmpty)
    }
    func testGmailFetchesBodiesUsingOnlyGETAndSkipsDisappearedMessage() async throws {
        let transport = FixtureTransport { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
            if request.url!.path.hasSuffix("/messages") {
                return (try json(["messages": [["id": "m1"], ["id": "gone"]]]), 200)
            }
            if request.url!.path.hasSuffix("/gone") { return (Data(), 404) }
            return (try mailFixture(), 200)
        }
        let (google, _) = try session(transport: transport)
        let messages = try await GmailClient(session: google, transport: transport).inbox()
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.body, "Please review by Friday.")
    }
    func testGmailRetries401OnceWithRefreshedToken() async throws {
        let transport = FixtureTransport { request in
            if request.url?.host == "oauth2.googleapis.com" { return (try json(["access_token": "fresh", "expires_in": 3600]), 200) }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer access" { return (Data(), 401) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
            return (try json(["emailAddress": "you@example.test"]), 200)
        }
        let (google, _) = try session(transport: transport)
        let email = try await GmailClient(session: google, transport: transport).accountEmail()
        XCTAssertEqual(email, "you@example.test")
        let count = await transport.requests.count
        XCTAssertEqual(count, 3)
    }
}

private extension AppSnapshot {
    func mergeAfterRestartHasNoArrivals() -> Bool {
        var copy = self
        return copy.merge(messages).isEmpty
    }
}

final class SplashTests: XCTestCase {
    func testOnlyLoopbackAddressesAreAllowed() throws {
        for address in ["http://127.0.0.1:8000", "http://localhost:8000/v1", "http://[::1]:8000"] {
            XCTAssertNoThrow(try SplashClient(address: address))
        }
        for address in ["https://api.openai.com", "https://example.test", "http://127.0.0.1.example.test", "http://user:password@localhost", "file:///tmp/server", "http://localhost:8000?forward=remote", "http://localhost:8000/unexpected"] {
            XCTAssertThrowsError(try SplashClient(address: address))
        }
        XCTAssertEqual(try SplashClient(address: "http://localhost:8000/v1").baseURL.absoluteString, "http://127.0.0.1:8000")
    }
    func testRequestUsesDiscoveredModelAndNeverIncludesOAuthSecrets() async throws {
        let transport = FixtureTransport { request in
            switch request.url!.path {
            case "/ready": return (try json(["status": "ready"]), 200)
            case "/v1/models": return (try json(["data": [["id": "local-qwen"]]]), 200)
            case "/v1/chat/completions":
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                XCTAssertEqual(body["model"] as? String, "local-qwen")
                XCTAssertEqual(body["reasoning_effort"] as? String, "none")
                XCTAssertNil(body["tools"])
                let text = String(decoding: request.httpBody!, as: UTF8.self)
                XCTAssertFalse(text.contains("refresh_token"))
                XCTAssertTrue(text.contains("Review request"))
                return (try json(["choices": [["message": ["content": "Review by Friday."], "finish_reason": "stop"]]]), 200)
            default: XCTFail("Unexpected endpoint"); return (Data(), 404)
            }
        }
        let splash = try SplashClient(address: "http://127.0.0.1:8000", transport: transport)
        let message = try GmailMessageDecoder.decode(mailFixture())
        let answer = try await splash.summarize(message)
        XCTAssertEqual(answer, "Review by Friday.")
    }
    func testUnavailableEngineFailsBeforeSendingEmailBody() async throws {
        let transport = FixtureTransport { _ in (try json(["error": ["message": "Model is loading"]]), 503) }
        let splash = try SplashClient(address: "http://127.0.0.1:8000", transport: transport)
        do {
            _ = try await splash.summarize(MailMessage(id: "m", subject: "Private", sender: "Maya", body: "private"))
            XCTFail("Should fail on readiness")
        } catch { XCTAssertTrue(error.localizedDescription.contains("503")) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests.first?.httpBody)
    }
    func testConnectionFailureExplainsHowToStartSplash() async throws {
        let transport = FixtureTransport { _ in throw URLError(.cannotConnectToHost) }
        let splash = try SplashClient(address: "http://127.0.0.1:8000", transport: transport)
        do { _ = try await splash.model(); XCTFail("Connection should fail") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("Start Splash separately"))
            XCTAssertTrue(error.localizedDescription.contains("127.0.0.1:8000"))
        }
    }
    func testContextIsBoundedAndLabelsTruncatedData() {
        let email = MailMessage(id: "m", subject: "Private", sender: "Maya", body: String(repeating: "x", count: 100_000))
        let context = SplashClient.emailContext([email])
        XCTAssertLessThan(context.count, 21_000)
        XCTAssertTrue(context.contains("Body shortened"))
        XCTAssertTrue(SplashClient.instructions.contains("untrusted reference"))
    }
    func testIncompleteAnswerIsClearlyMarked() async throws {
        let transport = FixtureTransport { request in
            if request.url!.path == "/ready" { return (Data(), 200) }
            if request.url!.path == "/v1/models" { return (try json(["data": [["id": "local"]]]), 200) }
            return (try json(["choices": [["message": ["content": "Partial answer"], "finish_reason": "length"]]]), 200)
        }
        let splash = try SplashClient(address: "http://127.0.0.1:8000", transport: transport)
        let result = try await splash.answer(question: "Brief", emails: [], history: [])
        XCTAssertTrue(result.contains("output limit"))
    }
}

actor EndToEndFixture: HTTPTransport {
    var hasArrival = false
    private(set) var requests: [URLRequest] = []
    func addArrival() { hasArrival = true }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url!.path
        let data: Data
        if path.hasSuffix("/profile") { data = try json(["emailAddress": "you@example.test"]) }
        else if path.hasSuffix("/messages") {
            data = try json(["messages": hasArrival ? [["id": "m2"], ["id": "m1"]] : [["id": "m1"]]])
        } else if path.contains("/messages/") { data = try mailFixture(id: request.url!.lastPathComponent) }
        else if path == "/ready" { data = try json(["status": "ready"]) }
        else if path == "/v1/models" { data = try json(["data": [["id": "fixture-local-model"]]] ) }
        else if path == "/v1/chat/completions" {
            data = try json(["choices": [["message": ["content": "Maya requests a review by Friday."], "finish_reason": "stop"]]])
        } else { throw PuddleError("Unexpected test endpoint") }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class EndToEndTests: XCTestCase {
    func testGmailSyncNewArrivalSplashSummaryAndRestart() async throws {
        let fixture = EndToEndFixture()
        let (google, _) = try session(transport: fixture)
        let gmail = GmailClient(session: google, transport: fixture)
        var state = AppSnapshot()
        state.account = try await gmail.accountEmail()
        let initial = try await gmail.inbox()
        XCTAssertTrue(state.merge(initial).isEmpty)
        await fixture.addArrival()
        let arrivals = state.merge(try await gmail.inbox())
        XCTAssertEqual(arrivals.map(\.id), ["m2"])
        let splash = try SplashClient(address: "http://127.0.0.1:8000", transport: fixture)
        let summary = try await splash.summarize(arrivals[0])
        let index = try XCTUnwrap(state.messages.firstIndex { $0.id == "m2" })
        state.messages[index].summary = summary
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = SnapshotStore(directory: directory)
        try disk.save(state)
        var restored = try disk.load()
        XCTAssertEqual(restored.messages.first { $0.id == "m2" }?.summary, "Maya requests a review by Friday.")
        let afterRestart = try await gmail.inbox()
        XCTAssertTrue(restored.merge(afterRestart).isEmpty)
        let requests = await fixture.requests
        XCTAssertTrue(requests.filter { $0.url?.host == "gmail.googleapis.com" }.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.map { $0.url!.host! }, ["127.0.0.1"])
    }
}
