import Foundation
import XCTest
import PuddleCore
@testable import Puddle

private actor SetupProbeTransport: HTTPTransport {
    let paused: Bool
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(paused: Bool = false) { self.paused = paused }
    func resume() { continuation?.resume(); continuation = nil }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if paused, !started {
            started = true
            await withCheckedContinuation { continuation = $0 }
        }
        let body: String
        if request.url?.path == "/v1/models" { body = #"{"data":[{"id":"probe-fixture"}]}"# }
        else {
            let input = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            body = input["tool_choice"] == nil
                ? #"{"choices":[{"message":{"content":"Hello."},"finish_reason":"stop"}]}"#
                : #"{"choices":[{"message":{"tool_calls":[{"id":"probe","type":"function","function":{"name":"list_tasks","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor final class LocalAISetupControllerTests: XCTestCase {
    func testGenericConnectionVerificationAndReset() async throws {
        let controller = LocalAISetupController()
        controller.verify(client: try LocalInferenceClient(address: "http://localhost:1234", transport: SetupProbeTransport()))
        for _ in 0..<100 where controller.isVerifying { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(controller.verification?.model.id, "probe-fixture")
        XCTAssertEqual(controller.verification?.toolCalling, true)
        XCTAssertNil(controller.error)
        controller.invalidateVerification()
        XCTAssertNil(controller.verification); XCTAssertTrue(controller.status.isEmpty)
    }

    func testCancelledConnectionCannotPublishLateVerification() async throws {
        let transport = SetupProbeTransport(paused: true), controller = LocalAISetupController()
        controller.verify(client: try LocalInferenceClient(address: "http://localhost:8080", transport: transport))
        for _ in 0..<100 {
            if await transport.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await transport.started
        XCTAssertTrue(started)
        controller.invalidateVerification()
        await transport.resume()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(controller.isVerifying); XCTAssertNil(controller.verification)
        XCTAssertNil(controller.error); XCTAssertTrue(controller.status.isEmpty)
    }
}
