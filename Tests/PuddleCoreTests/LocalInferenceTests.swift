import Foundation
import XCTest
@testable import PuddleCore

final class LocalInferenceTests: XCTestCase {
    func testDiscoveryKeepsServerOrderAndExactIDsWithoutSendingPrompts() async throws {
        let transport = FixtureTransport { request in
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertEqual(request.url?.path, "/v1/models")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            return (Data(#"{"data":[{"id":""},{"id":"  "},{"id":"first","max_model_len":0,"context_length":8192},{"id":"first"},{"id":"org/model:Q4","max_model_len":16384},{"id":"unknown","context_length":-1}]}"#.utf8), 200)
        }
        let client = try LocalInferenceClient(address: "http://localhost:1234/v1", apiKey: "fixture-key", modelID: "missing", transport: transport)
        let models = try await client.availableModels()
        XCTAssertEqual(models.map(\.id), ["first", "org/model:Q4", "unknown"])
        XCTAssertEqual(models.map(\.contextTokens), [8192, 16384, nil])
        do { _ = try await client.modelInfo(); XCTFail("Discovery must not silently replace a missing selection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("selected model")) }
    }

    func testLiveConfiguredLocalServer() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["PUDDLE_LIVE_INFERENCE_ADDRESS"] else {
            throw XCTSkip("Opt in with PUDDLE_LIVE_INFERENCE_ADDRESS pointing to a running local server")
        }
        let client = try LocalInferenceClient(address: address, apiKey: environment["PUDDLE_LIVE_INFERENCE_KEY"] ?? "",
            modelID: environment["PUDDLE_LIVE_INFERENCE_MODEL"] ?? "")
        let result = try await client.verifySetup()
        XCTAssertFalse(result.answer.isEmpty)
        XCTAssertTrue(result.toolCalling, result.toolDiagnostic ?? "The selected model must support tool calling")
    }

    func testStandardEndpointsSupportDiscoverySelectionAndChatWithoutProviderExtensions() async throws {
        for address in ["http://localhost:11434/v1/", "http://127.0.0.1:1234", "http://[::1]:8080/v1"] {
            let transport = FixtureTransport { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-test-key")
                switch request.url!.path {
                case "/v1/models":
                    return (Data(#"{"data":[{"id":"first"},{"id":"chosen","context_length":16384}]}"#.utf8), 200)
                case "/v1/chat/completions":
                    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                    XCTAssertEqual(Set(body.keys), ["model", "messages", "stream", "max_tokens", "temperature"])
                    XCTAssertEqual(body["model"] as? String, "chosen")
                    XCTAssertEqual(body["max_tokens"] as? Int, 1200)
                    return (Data(#"{"choices":[{"message":{"content":"Local answer"},"finish_reason":"stop"}]}"#.utf8), 200)
                default:
                    XCTFail("Unexpected provider-specific endpoint: \(request.url!.path)")
                    return (Data(), 404)
                }
            }
            let client = try LocalInferenceClient(address: address, apiKey: "local-test-key", modelID: " chosen \n", transport: transport)
            let info = try await client.modelInfo()
            XCTAssertEqual(info.id, "chosen"); XCTAssertEqual(info.contextTokens, 16384)
            let answer = try await client.answer(question: "Hello", emails: [], history: [])
            XCTAssertEqual(answer, "Local answer")
        }
    }

    func testCompatibleServerStreamsToolCallAndFollowupThroughAgent() async throws {
        let transport = FixtureTransport { request in
            if request.url!.path == "/v1/models" {
                return (Data(#"{"data":[{"id":"local-tools"}]}"#.utf8), 200)
            }
            XCTAssertEqual(request.url!.path, "/v1/chat/completions")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            XCTAssertEqual(Set(body.keys), ["model", "messages", "stream", "max_tokens", "temperature", "tools"])
            XCTAssertEqual(body["stream"] as? Bool, true)
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let payload: String
            if messages.contains(where: { $0["role"] as? String == "tool" }) {
                payload = #"data: {"choices":[{"delta":{"content":"No tasks saved."},"finish_reason":"stop"}]}"#
            } else {
                payload = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"local-call","type":"function","function":{"name":"list_tasks","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#
            }
            return (Data((payload + "\n\ndata: [DONE]\n\n").utf8), 200)
        }
        let client = try LocalInferenceClient(address: "http://localhost:1234/v1", transport: transport)
        let answer = try await LocalAgent(client: client).respond(question: "List tasks", history: [], context: AgentContext(), tools: [.tasks], execute: { call in
            XCTAssertEqual(call.function.name, "list_tasks")
            return "No saved tasks"
        }, onPartial: { _ in })
        XCTAssertEqual(answer, "No tasks saved.")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testMissingSelectedModelFailsBeforeSendingPrivateContext() async throws {
        let transport = FixtureTransport { request in
            XCTAssertEqual(request.url!.path, "/v1/models")
            XCTAssertNil(request.httpBody)
            return (Data(#"{"data":[{"id":"available"}]}"#.utf8), 200)
        }
        let client = try LocalInferenceClient(address: "http://localhost:11434", modelID: "missing", transport: transport)
        do {
            _ = try await client.answer(question: "Private question", emails: [], history: [])
            XCTFail("An unavailable model must fail discovery")
        } catch { XCTAssertTrue(error.localizedDescription.contains("selected model")) }
    }

    func testBlankSelectionUsesFirstModelAndUnknownCapacity() async throws {
        let transport = FixtureTransport { _ in (Data(#"{"data":[{"id":"first"},{"id":"second"}]}"#.utf8), 200) }
        let info = try await LocalInferenceClient(address: "http://localhost:8080", transport: transport).modelInfo()
        XCTAssertEqual(info.id, "first"); XCTAssertNil(info.contextTokens)
    }

    func testOldWorkspaceKeepsAddressAndNewSelectionSurvivesEncoding() throws {
        var settings = try JSONDecoder().decode(PuddleSettings.self, from: Data(#"{"splashAddress":"http://localhost:9000/v1"}"#.utf8))
        XCTAssertEqual(settings.inferenceAddress, "http://localhost:9000/v1")
        XCTAssertEqual(settings.inferenceModelID, "")
        settings.inferenceAddress = "http://localhost:11434"
        settings.inferenceModelID = "chosen"
        let restored = try JSONDecoder().decode(PuddleSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.inferenceAddress, "http://localhost:11434")
        XCTAssertEqual(restored.inferenceModelID, "chosen")
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        XCTAssertEqual(encoded["inferenceAddress"] as? String, "http://localhost:11434")
        XCTAssertNil(encoded["splashAddress"])
    }
}
