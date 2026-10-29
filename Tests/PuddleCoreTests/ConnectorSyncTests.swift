import Foundation
import XCTest
@testable import PuddleCore

private actor SyncFixture: HTTPTransport {
    var requests: [URLRequest] = []
    var phase = 0
    var expired = false
    func advance(expired: Bool = false) { phase += 1; self.expired = expired; requests = [] }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url!.path
        let object: [String: Any]
        var status = 200
        if path.hasSuffix("/profile") { object = ["emailAddress": "fixture@example.test", "historyId": "100"] }
        else if path.hasSuffix("/history") {
            if expired { object = [:]; status = 404 }
            else { object = ["historyId": "110", "history": [["messagesAdded": [["message": ["id": "new"]]], "labelsRemoved": [["message": ["id": "one"]]]]]] }
        } else if path.hasSuffix("/messages") {
            object = ["messages": (phase == 0 ? ["one", "two"] : ["one", "two", "new"]).map { ["id": $0] }]
        } else {
            object = ["id": request.url!.lastPathComponent, "labelIds": phase == 0 ? ["INBOX", "UNREAD"] : ["INBOX"],
                "payload": ["mimeType": "text/plain", "body": ["data": Data("Fixture body".utf8).base64URL]]]
        }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private actor RetryFixture: HTTPTransport {
    var count = 0
    let retryAfter: String
    init(_ retryAfter: String = "0") { self.retryAfter = retryAfter }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: count < 3 ? 429 : 200,
            httpVersion: nil, headerFields: ["Retry-After": retryAfter])!)
    }
}

final class ConnectorSyncTests: XCTestCase {
    private func google(_ transport: any HTTPTransport) throws -> GoogleSession {
        let secrets = MemorySecrets()
        try secrets.write(JSONEncoder().encode(GoogleCredentials(accessToken: "fixture", refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600), scope: OAuthFlow.scope + " " + OAuthFlow.calendarScope)), key: "google-tokens")
        return GoogleSession(store: secrets, transport: transport)
    }

    func testIncrementalSyncReusesUnchangedBodiesAndRefreshesLabels() async throws {
        let fixture = SyncFixture(), session = try google(fixture)
        let client = GmailClient(session: session, transport: fixture)
        let first = try await client.synchronize(cached: [], historyID: nil)
        XCTAssertTrue(first.messages.allSatisfy(\.isUnread))
        await fixture.advance()
        let second = try await client.synchronize(cached: first.messages, historyID: first.historyID)
        XCTAssertTrue(second.usedHistory); XCTAssertEqual(second.historyID, "110")
        XCTAssertEqual(second.newMessageIDs, ["new"])
        XCTAssertFalse(second.messages.first { $0.id == "one" }!.isUnread)
        let requests = await fixture.requests
        XCTAssertFalse(requests.contains { $0.url!.path.hasSuffix("/messages/two") })
        XCTAssertEqual(requests.filter { $0.url!.path.contains("/messages/") }.count, 2)
    }

    func testExpiredCursorRebuildsBaselineWithoutDuplicateArrivals() async throws {
        let fixture = SyncFixture(), session = try google(fixture)
        let client = GmailClient(session: session, transport: fixture)
        let first = try await client.synchronize(cached: [], historyID: nil)
        await fixture.advance(expired: true)
        let rebuilt = try await client.synchronize(cached: first.messages, historyID: first.historyID)
        XCTAssertFalse(rebuilt.usedHistory); XCTAssertTrue(rebuilt.newMessageIDs.isEmpty)
        var state = AppSnapshot(); state.merge(first.messages)
        XCTAssertTrue(state.merge(rebuilt.messages, newMessageIDs: rebuilt.newMessageIDs).isEmpty)
    }

    func testCalendarFollowsSmallPagesAndPreservesTruncation() async throws {
        let fixture = FixtureTransport { request in
            let second = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.name == "pageToken" }
            let events = second ? (0..<50).map { ["id": "event-\($0)", "start": ["date": "2026-10-30"]] as [String: Any] } : [["id": "first", "start": ["date": "2026-10-29"]]]
            return (try JSONSerialization.data(withJSONObject: ["items": events, "nextPageToken": second ? "third" : "second"]), 200)
        }
        let page = try await GoogleCalendarClient(session: google(fixture), transport: fixture).upcomingPage()
        XCTAssertEqual(page.events.count, 50); XCTAssertTrue(page.hasMore)
        let requests = await fixture.requests; XCTAssertEqual(requests.count, 2)
    }

    func testRetriesHonorRetryAfterAndNeverReplayWrites() async throws {
        let read = RetryFixture(), write = RetryFixture(), longDelay = RetryFixture("120")
        let request = URLRequest(url: URL(string: "https://gmail.googleapis.com/fixture")!)
        _ = try await RetryingTransport(base: read, wait: { _ in }).send(request)
        var post = request; post.httpMethod = "POST"
        _ = try await RetryingTransport(base: write, wait: { _ in XCTFail("Writes cannot retry") }).send(post)
        let (data, response) = try await RetryingTransport(base: longDelay, wait: { _ in XCTFail("Long delays go to the polling worker") }).send(request)
        let reads = await read.count, writes = await write.count, delayed = await longDelay.count
        XCTAssertEqual(reads, 3); XCTAssertEqual(writes, 1); XCTAssertEqual(delayed, 1)
        XCTAssertThrowsError(try checkHTTP(response, data: data, service: "Gmail")) {
            XCTAssertEqual(($0 as? HTTPServiceError)?.retryAfter, 120)
        }
    }
}
