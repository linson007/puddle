import Foundation
import XCTest
@testable import PuddleCore

private actor SetupTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let validTools: Bool
    let emptyAnswer: Bool
    init(validTools: Bool = true, emptyAnswer: Bool = false) { self.validTools = validTools; self.emptyAnswer = emptyAnswer }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body: String
        if request.url?.path == "/v1/models" { body = #"{"data":[{"id":"setup-fixture","context_length":32768}]}"# }
        else {
            let input = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            if input["tool_choice"] != nil, validTools {
                body = #"{"choices":[{"message":{"tool_calls":[{"id":"test","type":"function","function":{"name":"list_tasks","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#
            } else { body = "{\"choices\":[{\"message\":{\"content\":\"\(emptyAnswer ? "" : "Hello from this Mac.")\"},\"finish_reason\":\"stop\"}]}" }
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class LocalAISetupTests: XCTestCase {
    func testVerificationChecksRealReplyAndRequiredToolWithoutExecutingPersonalTools() async throws {
        let transport = SetupTransport()
        let result = try await LocalInferenceClient(address: "http://127.0.0.1:8000", transport: transport).verifySetup()
        XCTAssertTrue(result.toolCalling); XCTAssertEqual(result.model.contextTokens, 32768)
        XCTAssertEqual(result.answer, "Hello from this Mac.")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "127.0.0.1" })
        let last = try JSONSerialization.jsonObject(with: requests.last!.httpBody!) as! [String: Any]
        XCTAssertEqual(last["tool_choice"] as? String, "required")
    }
    func testChatOnlyModelDoesNotReceiveToolVerifiedBadge() async throws {
        let client = try LocalInferenceClient(address: "http://localhost:8000", transport: SetupTransport(validTools: false))
        let result = try await client.verifySetup()
        XCTAssertFalse(result.toolCalling)
    }
    func testEmptyReplyCannotCompleteSetup() async throws {
        let client = try LocalInferenceClient(address: "http://localhost:8000", transport: SetupTransport(emptyAnswer: true))
        do { _ = try await client.verifySetup(); XCTFail("Empty response accepted") } catch {}
    }
}
