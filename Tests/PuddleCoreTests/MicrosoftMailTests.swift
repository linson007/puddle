import Foundation
import XCTest
@testable import PuddleCore

private final class MicrosoftSecrets: SecretStore, @unchecked Sendable {
    var data: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { data[key] }
    func write(_ value: Data, key: String) throws { data[key] = value }
    func delete(_ key: String) throws { data.removeValue(forKey: key) }
}
private actor MicrosoftHTTP: HTTPTransport {
    var id = "one", email = "one@example.com"
    var requests: [URLRequest] = []
    var pageThreads = false, unsafeNext = false
    func enableThreadPages(unsafeNext: Bool = false) { pageThreads = true; self.unsafeNext = unsafeNext }
    func setIdentity(_ id: String, email: String) { self.id = id; self.email = email }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body: String, status: Int
        if request.url!.path.hasSuffix("/token") {
            body = "{\"access_token\":\"token-\(id)\",\"refresh_token\":\"refresh-\(id)\",\"expires_in\":3600,\"scope\":\"Mail.Read Mail.Send Mail.ReadWrite User.Read\"}"; status = 200
        } else if request.url!.path == "/v1.0/me" {
            body = "{\"id\":\"\(id)\",\"mail\":\"\(email)\"}"; status = 200
        } else if request.url!.path.hasSuffix("/sendMail") { body = ""; status = 202 }
        else {
            body = #"{"value":[{"id":"message","conversationId":"thread","subject":"Fixture","from":{"emailAddress":{"address":"sender@example.com"}},"toRecipients":[],"receivedDateTime":"2026-10-30T09:00:00Z","isRead":false,"importance":"high","body":{"contentType":"html","content":"<p>Hello</p><img src='https://tracker.example/pixel'><script>hidden</script>"},"webLink":"https://outlook.office.com/mail/message"}]}"#; status = 200
        }
        var bytes = Data(body.utf8)
        if pageThreads, request.url!.path == "/v1.0/me/messages" {
            var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            if request.url!.query?.contains("skiptoken") == true {
                var items = object["value"] as! [[String: Any]]; items[0]["id"] = "second"; object["value"] = items
            } else { object["@odata.nextLink"] = unsafeNext ? "https://evil.example/me/messages" : "https://graph.microsoft.com/v1.0/me/messages?$skiptoken=fixture" }
            bytes = try JSONSerialization.data(withJSONObject: object)
        }
        return (bytes, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
final class MicrosoftMailTests: XCTestCase {
    private let config = try! MicrosoftClientConfiguration(clientID: "11111111-2222-3333-4444-555555555555")
    private func attempt() throws -> MicrosoftOAuthAttempt { try MicrosoftOAuthAttempt(configuration: config, callback: URL(string: "http://127.0.0.1:44001/oauth/callback")!, allowSend: true, allowOrganize: true) }
    func testAuthorizationUsesPKCEAndRejectsDuplicateStateAndWrongCallbackHost() throws {
        let attempt = try attempt(), values = URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(attempt.authorizationURL.host, "login.microsoftonline.com")
        XCTAssertTrue(values.contains { $0.name == "code_challenge_method" && $0.value == "S256" })
        XCTAssertFalse(values.first { $0.name == "scope" }!.value!.contains("googleapis"))
        let good = "http://127.0.0.1:44001/oauth/callback?state=\(attempt.state)&code=fixture"
        XCTAssertEqual(try attempt.code(from: URL(string: good)!), "fixture")
        XCTAssertThrowsError(try attempt.code(from: URL(string: good + "&state=other")!))
        XCTAssertThrowsError(try attempt.code(from: URL(string: good.replacingOccurrences(of: "127.0.0.1", with: "evil.example"))!))
        XCTAssertThrowsError(try MicrosoftClientConfiguration(clientID: config.clientID, tenant: "../../evil"))
    }
    func testMultipleAccountsAndExpectedIdentityProtectTokenUse() async throws {
        let http = MicrosoftHTTP(), session = MicrosoftMailSession(secrets: MicrosoftSecrets(), transport: http)
        try await session.configure(config); let attempt = try attempt()
        try await session.exchange(code: "one", attempt: attempt)
        await http.setIdentity("two", email: "two@example.com"); try await session.exchange(code: "two", attempt: attempt)
        let accounts = try await session.accounts(); XCTAssertEqual(accounts.count, 2)
        do { _ = try await session.accessToken(expectedAccountID: "one"); XCTFail("Wrong active account accepted") } catch {}
        try await session.select("one"); let token = try await session.accessToken(expectedAccountID: "one")
        XCTAssertEqual(token, "token-one")
        try await session.disconnect(); let remaining = try await session.accounts(); XCTAssertEqual(remaining.count, 1)
    }
    func testThreadPaginationKeepsProviderBoundaryAndRejectsUnexpectedNextHost() async throws {
        let http = MicrosoftHTTP(), session = MicrosoftMailSession(secrets: MicrosoftSecrets(), transport: http)
        try await session.configure(config); try await session.exchange(code: "one", attempt: attempt())
        await http.enableThreadPages()
        let page = try await OutlookMailClient(session: session, transport: http).thread("thread")
        XCTAssertEqual(Set(page.messages.map(\.id)), ["message", "second"]); XCTAssertFalse(page.hasMore)
        await http.enableThreadPages(unsafeNext: true)
        do { _ = try await OutlookMailClient(session: session, transport: http).thread("thread"); XCTFail("Unexpected host followed") } catch {}
        let requests = await http.requests
        XCTAssertFalse(requests.contains { $0.url?.host == "evil.example" })
    }
    func testMailReadingStripsTrackingHTMLAndSendingUsesReviewedMIME() async throws {
        let http = MicrosoftHTTP(), session = MicrosoftMailSession(secrets: MicrosoftSecrets(), transport: http)
        try await session.configure(config); try await session.exchange(code: "one", attempt: attempt())
        let client = OutlookMailClient(session: session, transport: http), mail = try await client.inbox()
        XCTAssertEqual(mail.first?.body, "Hello"); XCTAssertEqual(mail.first?.sourceURL.host, "outlook.office.com")
        XCTAssertTrue(mail.first?.isUnread == true)
        var action = ActionProposal(account: "one@example.com", payload: .email(MailDraft(to: "friend@example.com", subject: "Hello", body: "Reviewed body")), provider: .outlook)
        try action.authorize(digest: action.digest); _ = try await client.execute(action)
        let request = await http.requests.last!
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/plain")
        let mime = Data(base64Encoded: String(decoding: request.httpBody!, as: UTF8.self))!
        XCTAssertTrue(String(decoding: mime, as: UTF8.self).contains("To: friend@example.com"))
        var wrong = action; wrong.provider = .google
        do { _ = try await client.execute(wrong); XCTFail("Wrong provider accepted") } catch {}
    }
}
