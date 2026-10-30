import Foundation
import XCTest
@testable import PuddleCore

private actor NewsletterHTTP: HTTPTransport {
    var requests: [URLRequest] = []
    let status: Int
    init(status: Int = 204) { self.status = status }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
final class NewsletterTests: XCTestCase {
    func testOnlyOneClickPublicHTTPSHeadersCreateTargets() throws {
        XCTAssertNotNil(NewsletterTarget.from(sender: "Sender", unsubscribe: "<mailto:leave@example.com>, <https://news.example.com/leave?t=opaque>", post: "List-Unsubscribe=One-Click"))
        for target in ["http://news.example.com/leave", "https://127.0.0.1/leave", "https://router.local/leave", "https://user:pass@news.example.com/leave", "https://news.example.com:8443/leave"] {
            XCTAssertNil(NewsletterTarget.from(sender: "Sender", unsubscribe: "<\(target)>", post: "List-Unsubscribe=One-Click"))
        }
        XCTAssertNil(NewsletterTarget.from(sender: "Sender", unsubscribe: "<https://news.example.com/leave>", post: ""))
    }
    func testReservedAddressesAreRejectedBeforeDispatch() {
        for address in ["127.0.0.1", "10.0.0.2", "172.16.1.1", "192.168.0.2", "169.254.169.254", "100.64.0.1", "192.0.2.1", "198.51.100.2", "203.0.113.1", "::1", "fe80::1", "fc00::1", "2001:db8::1", "::ffff:8.8.8.8"] { XCTAssertFalse(PublicNewsletterHost.isPublic(address), address) }
        XCTAssertTrue(PublicNewsletterHost.isPublic("8.8.8.8")); XCTAssertTrue(PublicNewsletterHost.isPublic("2606:4700:4700::1111"))
    }
    func testReviewedRequestHasFixedAnonymousBodyAndNeverRetriesFailure() async throws {
        let http = NewsletterHTTP(), client = NewsletterClient(transport: http, validateHost: { _ in })
        let target = NewsletterTarget(sender: "Newsletter", url: URL(string: "https://news.example.com/unsubscribe?token=opaque")!)
        var action = ActionProposal(account: "person@example.com", payload: .unsubscribe(target))
        do { _ = try await client.execute(action); XCTFail("Unreviewed unsubscribe dispatched") } catch {}
        try action.authorize(digest: action.digest)
        _ = try await client.execute(action)
        let request = await http.requests.first!
        XCTAssertEqual(request.httpMethod, "POST"); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(String(decoding: request.httpBody!, as: UTF8.self), "List-Unsubscribe=One-Click")
        let failing = NewsletterHTTP(status: 503)
        do { _ = try await NewsletterClient(transport: failing, validateHost: { _ in }).execute(action); XCTFail("Failure accepted") } catch {}
        let attempts = await failing.requests.count; XCTAssertEqual(attempts, 1)
    }
}
