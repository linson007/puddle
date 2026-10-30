import Foundation
import XCTest
@testable import PuddleCore

private actor LatePolicyHTTP: HTTPTransport {
    var gate: CheckedContinuation<Void, Never>?
    var waiting: Bool { gate != nil }
    func finish() { gate?.resume(); gate = nil }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await withCheckedContinuation { gate = $0 }
        return (Data("late response".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
final class NetworkPolicyTests: XCTestCase {
    func testOperationBoundBeforeCredentialWaitCannotAcquireFreshAuthorityAfterResume() async throws {
        let policy = NetworkPolicy(), http = LatePolicyHTTP()
        let transport = PolicyTransport(base: http, policy: policy, bindToCurrentPolicy: true)
        policy.allowExternalConnections(false); policy.allowExternalConnections(true)
        let request = URLRequest(url: URL(string: "https://gmail.googleapis.com/fixture")!)
        do { _ = try await transport.send(request); XCTFail("Stale operation acquired fresh authority") } catch {}
        do { _ = try await transport.sendBounded(request, maximumBytes: 64, until: nil); XCTFail("Stale bounded operation accepted") } catch {}
        do { _ = try await transport.stream(request, onLine: { _ in }); XCTFail("Stale stream accepted") } catch {}
        let waiting = await http.waiting; XCTAssertFalse(waiting, "No request may reach the base transport")
    }
    func testPauseThenResumeCannotAcceptAnEarlierInFlightExternalResponse() async throws {
        let policy = NetworkPolicy(), http = LatePolicyHTTP(), transport = PolicyTransport(base: http, policy: policy)
        let request = Task { try await transport.send(URLRequest(url: URL(string: "https://api.github.com/user")!)) }
        for _ in 0..<100 { if await http.waiting { break }; try await Task.sleep(for: .milliseconds(2)) }
        policy.allowExternalConnections(false); policy.allowExternalConnections(true); await http.finish()
        do { _ = try await request.value; XCTFail("A stale external response crossed the privacy boundary") } catch {}
    }
}
