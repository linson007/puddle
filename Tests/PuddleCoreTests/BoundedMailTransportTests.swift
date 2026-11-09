import Foundation
import XCTest
@testable import PuddleCore

private actor BoundedMailHTTP: HTTPTransport {
    var unbounded = 0, bounds: [Int] = [], callbacks = 0
    let statuses: [Int]
    let rejectBody: Bool
    init(statuses: [Int] = [200], rejectBody: Bool = false) { self.statuses = statuses; self.rejectBody = rejectBody }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        unbounded += 1; throw PuddleError("Unbounded mailbox read reached the transport")
    }
    func sendBounded(_ request: URLRequest, maximumBytes: Int, until: (@Sendable (Data, HTTPURLResponse) -> Bool)?) async throws -> (Data, HTTPURLResponse) {
        bounds.append(maximumBytes)
        if rejectBody { throw PuddleError("Fixture response exceeds its streaming byte limit") }
        let path = request.url!.path
        let body: String
        if path.hasSuffix("/profile") { body = #"{"emailAddress":"fixture@example.test","historyId":"one"}"# }
        else if path.contains("/attachments/") { body = #"{"data":"c2FmZQ"}"# }
        else if path.contains("/threads/") { body = #"{"messages":[]}"# }
        else if path.hasSuffix("calendarList") || path.hasSuffix("events") { body = #"{"items":[]}"# }
        else if request.url?.host == "graph.microsoft.com" { body = #"{"value":[]}"# }
        else { body = #"{"messages":[]}"# }
        let response = HTTPURLResponse(url: request.url!, statusCode: statuses[min(bounds.count - 1, statuses.count - 1)], httpVersion: nil, headerFields: ["Retry-After": "0"])!
        let data = Data(body.utf8)
        if let until { _ = until(data, response); callbacks += 1 }
        return (data, response)
    }
}
final class BoundedMailTransportTests: XCTestCase {
    func testOAuthModelAndActionBoundariesNeverCallUnboundedSend() async throws {
        let secrets = MemorySecrets()
        try secrets.write(JSONEncoder().encode(GoogleClientConfiguration(clientID: "fixture.apps.googleusercontent.com")), key: "google-client")
        try secrets.write(JSONEncoder().encode(GoogleCredentials(accessToken: "expired", refreshToken: "fixture", expiresAt: .distantPast, scope: OAuthFlow.scope)), key: "google-tokens")
        let googleHTTP = BoundedMailHTTP(rejectBody: true)
        do { _ = try await GoogleSession(store: secrets, transport: googleHTTP).accessToken(); XCTFail("Huge token body accepted") } catch {}
        let googleBounds = await googleHTTP.bounds, googleUnbounded = await googleHTTP.unbounded
        XCTAssertEqual(googleBounds, [256 * 1024]); XCTAssertEqual(googleUnbounded, 0)

        let microsoftHTTP = BoundedMailHTTP(rejectBody: true), microsoft = MicrosoftMailSession(secrets: MemorySecrets(), transport: microsoftHTTP)
        let config = try MicrosoftClientConfiguration(clientID: UUID().uuidString)
        try await microsoft.configure(config)
        let attempt = try MicrosoftOAuthAttempt(configuration: config, callback: URL(string: "http://127.0.0.1:4321/oauth/callback")!, allowSend: false, allowOrganize: false)
        do { try await microsoft.exchange(code: "fixture", attempt: attempt); XCTFail("Huge Microsoft token body accepted") } catch {}
        let microsoftBounds = await microsoftHTTP.bounds, microsoftUnbounded = await microsoftHTTP.unbounded
        XCTAssertEqual(microsoftBounds, [256 * 1024]); XCTAssertEqual(microsoftUnbounded, 0)

        let modelHTTP = BoundedMailHTTP(rejectBody: true)
        do { _ = try await LocalInferenceClient(address: "http://127.0.0.1:8000", transport: modelHTTP).model(); XCTFail("Huge model body accepted") } catch {}
        let modelBounds = await modelHTTP.bounds, modelUnbounded = await modelHTTP.unbounded
        XCTAssertEqual(modelBounds, [8 * 1024 * 1024]); XCTAssertEqual(modelUnbounded, 0)

        let actionHTTP = BoundedMailHTTP(rejectBody: true)
        let credentials = GoogleCredentials(accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture, scope: OAuthFlow.mailSendScope,
            account: GoogleAccount(id: "fixture", email: "fixture@example.test", name: nil))
        try secrets.write(JSONEncoder().encode(credentials), key: "google-tokens")
        var proposal = ActionProposal(account: "fixture@example.test", payload: .email(MailDraft(to: "recipient@example.test", subject: "Fixture", body: "Fixture")))
        try proposal.authorize(digest: proposal.digest)
        do { _ = try await GoogleActionClient(session: GoogleSession(store: secrets), transport: actionHTTP).execute(proposal); XCTFail("Huge action body accepted") } catch {}
        let actionBounds = await actionHTTP.bounds, actionUnbounded = await actionHTTP.unbounded
        XCTAssertEqual(actionBounds, [1024 * 1024]); XCTAssertEqual(actionUnbounded, 0)
    }
    private func google() throws -> GoogleSession {
        let secrets = MemorySecrets()
        try secrets.write(JSONEncoder().encode(GoogleCredentials(accessToken: "fixture", refreshToken: "fixture", expiresAt: Date().addingTimeInterval(3600), scope: OAuthFlow.scope)), key: "google-tokens")
        return GoogleSession(store: secrets)
    }
    func testRetryDecoratorPreservesStreamingBoundAndCompletionPredicateOnEveryReadAttempt() async throws {
        let http = BoundedMailHTTP(statuses: [429, 503, 200])
        let request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/messages")!)
        let (_, response) = try await RetryingTransport(base: http, wait: { _ in }).sendBounded(request, maximumBytes: 321, until: { data, _ in !data.isEmpty })
        XCTAssertEqual(response.statusCode, 200)
        let bounds = await http.bounds, unbounded = await http.unbounded, callbacks = await http.callbacks
        XCTAssertEqual(bounds, [321, 321, 321]); XCTAssertEqual(unbounded, 0); XCTAssertEqual(callbacks, 3)
    }
    func testBoundedWritesAndOversizedResponsesAreNeverRetried() async throws {
        let http = BoundedMailHTTP(statuses: [429]), failing = BoundedMailHTTP(rejectBody: true)
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/fixture")!); request.httpMethod = "POST"
        _ = try await RetryingTransport(base: http, wait: { _ in XCTFail("Write replay") }).sendBounded(request, maximumBytes: 64, until: nil)
        request.httpMethod = "GET"
        do { _ = try await RetryingTransport(base: failing, wait: { _ in XCTFail("Size failure replay") }).sendBounded(request, maximumBytes: 64, until: nil); XCTFail("Oversized response accepted") } catch {}
        let writes = await http.bounds, failures = await failing.bounds
        XCTAssertEqual(writes.count, 1); XCTAssertEqual(failures.count, 1)
    }
    func testGmailProfileInboxThreadAndAttachmentUseBoundedReads() async throws {
        let http = BoundedMailHTTP(), client = GmailClient(session: try google(), transport: http)
        let email = try await client.accountEmail(); XCTAssertEqual(email, "fixture@example.test")
        let inbox = try await client.inbox(); XCTAssertTrue(inbox.isEmpty)
        let thread = try await client.thread("fixture"); XCTAssertTrue(thread.messages.isEmpty)
        let attachment = try await client.attachment(MailAttachment(id: "part", name: "note.txt", mimeType: "text/plain", bytes: 4), messageID: "fixture")
        XCTAssertEqual(attachment, Data("safe".utf8))
        let bounds = await http.bounds, unbounded = await http.unbounded
        XCTAssertEqual(bounds, Array(repeating: 16 * 1024 * 1024, count: 4)); XCTAssertEqual(unbounded, 0)
    }
    func testOversizedGmailThreadStopsAtTransportBeforeJSONParsing() async throws {
        let http = BoundedMailHTTP(rejectBody: true)
        do { _ = try await GmailClient(session: google(), transport: http).thread("huge"); XCTFail("Huge thread accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("streaming byte limit")) }
        let unbounded = await http.unbounded, bounds = await http.bounds
        XCTAssertEqual(unbounded, 0); XCTAssertEqual(bounds.count, 1)
    }
    func testOutlookAndCalendarRetainTheirBoundsThroughRetryDecorators() async throws {
        let secrets = MemorySecrets()
        let vault: [String: Any] = ["activeID": "fixture", "accounts": [["account": ["id": "fixture", "email": "fixture@example.test", "scopes": ["Mail.Read"]], "accessToken": "fixture", "refreshToken": "fixture", "expiresAt": Date().addingTimeInterval(3600).timeIntervalSinceReferenceDate]]]
        try secrets.write(JSONSerialization.data(withJSONObject: vault), key: "microsoft-accounts")
        let http = BoundedMailHTTP(), outlook = MicrosoftMailSession(secrets: secrets, transport: http)
        let messages = try await OutlookMailClient(session: outlook, transport: http).inbox(); XCTAssertTrue(messages.isEmpty)
        let calendar = GoogleCalendarClient(session: try google(), transport: http)
        _ = try await calendar.upcoming(); _ = try await calendar.calendars()
        let bounds = await http.bounds, unbounded = await http.unbounded
        XCTAssertEqual(bounds, [16 * 1024 * 1024, 4 * 1024 * 1024, 4 * 1024 * 1024]); XCTAssertEqual(unbounded, 0)
    }
}
