import Foundation
import XCTest
@testable import PuddleCore

private actor StreamFixture: HTTPTransport {
    var responses: [String]
    var requests: [URLRequest] = []
    init(_ responses: [String]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body: String
        switch request.url!.path {
        case "/ready": body = #"{"status":"ready"}"#
        case "/v1/models": body = #"{"data":[{"id":"stream-fixture","max_model_len":8192}]}"#
        default: body = responses.removeFirst()
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor PartialRecorder {
    var partials: [String] = []
    var calls: [AgentToolCall] = []
    var metrics: [TurnMetrics] = []
    func partial(_ value: String) { partials.append(value) }
    func execute(_ value: AgentToolCall) -> String { calls.append(value); return "No tasks" }
    func timing(_ value: TurnMetrics) { metrics.append(value) }
}

final class StreamingTests: XCTestCase {
    private let text = """
    : keepalive
    data: {"choices":[{"delta":{"content":"Hello"},"finish_reason":null}]}

    data: {"choices":[{"delta":{"content":" world"},"finish_reason":null}]}

    data: {"choices":[{"delta":{},"finish_reason":"stop"}]}
    data: [DONE]
    """

    func testFragmentedTextAndToolArgumentsCompleteBeforeExecution() async throws {
        let tool = """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"list_tasks","arguments":"{"}}]},"finish_reason":null}]}
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"}"}}]},"finish_reason":null}]}
        data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}
        data: [DONE]
        """
        let fixture = StreamFixture([tool, text]), recorder = PartialRecorder()
        let agent = LocalAgent(splash: try SplashClient(address: "http://127.0.0.1:8000", transport: fixture))
        let result = try await agent.respond(question: "List tasks", history: [], context: AgentContext(), tools: [.tasks],
            execute: { await recorder.execute($0) }, onPartial: { await recorder.partial($0) })
        XCTAssertEqual(result, "Hello world")
        let calls = await recorder.calls, partials = await recorder.partials
        XCTAssertEqual(calls.first?.function.arguments, "{}")
        XCTAssertEqual(calls.first?.id, "call_1")
        XCTAssertTrue(partials.contains("Hello")); XCTAssertEqual(partials.last, "Hello world")
    }

    func testInterruptedToolStreamNeverExecutes() async throws {
        let incomplete = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"create_reminder","arguments":"{}"}}]},"finish_reason":null}]}"#
        let fixture = StreamFixture([incomplete]), recorder = PartialRecorder()
        let agent = LocalAgent(splash: try SplashClient(address: "http://127.0.0.1:8000", transport: fixture))
        do {
            _ = try await agent.respond(question: "Remind me", history: [], context: AgentContext(), tools: [.remind],
                execute: { await recorder.execute($0) }, onPartial: { _ in })
            XCTFail("An interrupted stream must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("incomplete")) }
        let calls = await recorder.calls; XCTAssertTrue(calls.isEmpty)
    }

    func testSharedDiscoverySkipsLearningForGeneralChatAndRecordsTiming() async throws {
        let fixture = StreamFixture([text, text]), recorder = PartialRecorder()
        let client = try SplashClient(address: "http://127.0.0.1:8000", transport: fixture)
        let service = ConversationService(connection: ModelConnection(client: client))
        for _ in 0..<2 {
            _ = try await service.respond(question: "Explain binary search", history: [], context: AgentContext(), tools: [],
                learn: { _ in XCTFail("No extraction required"); return [] }, execute: { _ in "" }, onActivity: { _ in },
                onPartial: { await recorder.partial($0) }, onMetrics: { await recorder.timing($0) })
        }
        let requests = await fixture.requests, metrics = await recorder.metrics
        XCTAssertEqual(requests.filter { $0.url?.path == "/v1/models" }.count, 1)
        XCTAssertEqual(requests.filter { $0.url?.path == "/v1/chat/completions" }.count, 2)
        XCTAssertEqual(metrics.count, 2); XCTAssertNotNil(metrics[0].firstTokenSeconds)
        XCTAssertEqual(metrics[0].extractionSeconds, 0)
    }

    func testContextBudgetIncludesToolArgumentsAndMultibyteText() {
        let call = AgentToolCall(name: "list_tasks", arguments: String(repeating: "x", count: 9000))
        XCTAssertGreaterThan(PromptBudget.tokens(messages: [AgentMessage(role: "assistant", content: "", calls: [call])], tools: []), 3000)
        XCTAssertGreaterThan(PromptBudget.tokens(String(repeating: "界", count: 100)), PromptBudget.tokens(String(repeating: "x", count: 100)))
    }
}
