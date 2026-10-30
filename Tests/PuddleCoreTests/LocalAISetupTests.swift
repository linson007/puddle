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
        if request.url?.path == "/ready" { body = "{}" }
        else if request.url?.path == "/v1/models" { body = #"{"data":[{"id":"setup-fixture","context_length":32768}]}"# }
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
    func testLiveSetupAgainstRunningSplash() async throws {
        guard ProcessInfo.processInfo.environment["PUDDLE_LIVE_SPLASH"] == "1" else { throw XCTSkip("Opt in with PUDDLE_LIVE_SPLASH=1") }
        let result = try await SplashClient(address: "http://127.0.0.1:8000").verifySetup()
        XCTAssertTrue(result.toolCalling); XCTAssertFalse(result.answer.isEmpty)
    }
    private func hardware(chip: String = "Apple M5 Pro", memory: Int = 32, disk: Int = 50, major: Int = 26, minor: Int = 4) -> LocalAIHardware {
        LocalAIHardware(chip: chip, memoryBytes: UInt64(memory) * 1_073_741_824, freeDiskBytes: Int64(disk) * 1_073_741_824,
            os: OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0))
    }
    func testHardwarePreflightDistinguishesEngineOSMemoryAndDisk() {
        XCTAssertTrue(hardware().issues(for: .balanced).isEmpty)
        XCTAssertFalse(hardware(chip: "Apple M2 Max").supportsSplash)
        XCTAssertFalse(hardware(major: 26, minor: 3).supportsSplash)
        XCTAssertTrue(hardware(major: 27, minor: 0).supportsSplash)
        XCTAssertEqual(hardware(memory: 24).recommendation, .compact)
        XCTAssertEqual(hardware(memory: 16, disk: 5).issues(for: .balanced).count, 2)
    }
    func testLaunchArgumentsKeepServerOnLoopbackAndBoundContext() throws {
        let args = try SplashModelPreset.compact.arguments(port: 8001)
        XCTAssertTrue(args.contains("127.0.0.1")); XCTAssertTrue(args.contains("32768")); XCTAssertTrue(args.contains("8001"))
        XCTAssertThrowsError(try SplashModelPreset.compact.arguments(port: 0))
    }
    func testVerificationChecksRealReplyAndRequiredToolWithoutExecutingPersonalTools() async throws {
        let transport = SetupTransport()
        let result = try await SplashClient(address: "http://127.0.0.1:8000", transport: transport).verifySetup()
        XCTAssertTrue(result.toolCalling); XCTAssertEqual(result.model.contextTokens, 32768)
        XCTAssertEqual(result.answer, "Hello from this Mac.")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "127.0.0.1" })
        let last = try JSONSerialization.jsonObject(with: requests.last!.httpBody!) as! [String: Any]
        XCTAssertEqual(last["tool_choice"] as? String, "required")
    }
    func testChatOnlyModelDoesNotReceiveToolVerifiedBadge() async throws {
        let client = try SplashClient(address: "http://localhost:8000", transport: SetupTransport(validTools: false))
        let result = try await client.verifySetup()
        XCTAssertFalse(result.toolCalling)
    }
    func testEmptyReplyCannotCompleteSetup() async throws {
        let client = try SplashClient(address: "http://localhost:8000", transport: SetupTransport(emptyAnswer: true))
        do { _ = try await client.verifySetup(); XCTFail("Empty response accepted") } catch {}
    }
}
