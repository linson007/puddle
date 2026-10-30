import Foundation
import XCTest
@testable import PuddleCore

private actor SummaryTransport: HTTPTransport {
    var texts: [String] = []
    let invalid: Bool
    let repairable: Bool
    init(invalid: Bool = false, repairable: Bool = false) { self.invalid = invalid; self.repairable = repairable }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let object: [String: Any]
        if request.url!.path == "/v1/models" { object = ["data": [["id": "fixture", "max_model_len": 4096]]] }
        else if request.url!.path == "/ready" { object = ["status": "ready"] }
        else {
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let text = try XCTUnwrap(messages.last?["content"] as? String); texts.append(text)
            let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.count, 1)
            XCTAssertEqual((tools.first?["function"] as? [String: Any])?["name"] as? String, AgentTool.meetingSummary.rawValue)
            var arguments: [String: Any] = ["key_points": [invalid ? "Invented conclusion." : text], "decisions": [], "actions": [], "questions": []]
            if repairable {
                arguments = ["key_points": [], "decisions": [], "questions": [], "actions": [["quote": "I will review by Friday.", "owner": texts.count == 1 ? "Alex" : "I", "timing": "Friday"]]]
            }
            object = ["choices": [["message": ["tool_calls": [["id": "extract", "type": "function", "function": ["name": AgentTool.meetingSummary.rawValue, "arguments": arguments]]]], "finish_reason": "tool_calls"]]]
        }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class MeetingSummaryTests: XCTestCase {
    private func arguments(points: [String] = [], decisions: [String] = [], actions: [[String: String]] = [], questions: [String] = []) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["key_points": points, "decisions": decisions, "actions": actions, "questions": questions]), as: UTF8.self)
    }
    func testOnlyLiteralQuotesAndOwnersAndTimingAreAccepted() throws {
        let source = "Mira: I will send the report by Friday. We agreed to postpone launch."
        let action = ["quote": "Mira: I will send the report by Friday.", "owner": "Mira", "timing": "Friday"]
        let summary = try LocalMeetingSummarizer.validate(arguments: arguments(decisions: ["We agreed to postpone launch."], actions: [action]), source: source, model: "fixture")
        XCTAssertEqual(summary.actions.first?.owner, "Mira"); XCTAssertEqual(summary.actions.first?.timing, "Friday")
        XCTAssertThrowsError(try LocalMeetingSummarizer.validate(arguments: arguments(points: ["We agreed to launch."]), source: source, model: "fixture"))
        var wrong = action; wrong["owner"] = "Li"
        XCTAssertThrowsError(try LocalMeetingSummarizer.validate(arguments: arguments(actions: [wrong]), source: source, model: "fixture"))
        wrong = action; wrong["timing"] = "2026-10-30"
        XCTAssertThrowsError(try LocalMeetingSummarizer.validate(arguments: arguments(actions: [wrong]), source: source, model: "fixture"))
    }
    func testChunkingPreservesEveryCharacterAndRespectsUnicodeBudget() throws {
        let text = String(repeating: "Mira: We will review this.\nनमस्ते दुनिया\n", count: 100)
        let chunks = try LocalMeetingSummarizer.chunks(notes: "", transcript: text, tokenBudget: 500)
        XCTAssertGreaterThan(chunks.count, 1); XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { PromptBudget.tokens($0) <= 500 })
        XCTAssertThrowsError(try LocalMeetingSummarizer.chunks(notes: "", transcript: String(repeating: "x", count: 200_000), tokenBudget: 300))
        XCTAssertThrowsError(try LocalMeetingSummarizer.chunks(notes: "small", transcript: "", tokenBudget: 20))
    }
    func testDigestDetectsSourceEditsAndBoundaryChangesAndRoundTrips() throws {
        let summary = MeetingSummary(model: "fixture", sourceDigest: MeetingSummary.digest(notes: "A", transcript: "B"), actions: [MeetingAction(quote: "A", owner: "A")])
        XCTAssertTrue(summary.isCurrent(notes: "A", transcript: "B"))
        XCTAssertFalse(summary.isCurrent(notes: "AB", transcript: ""))
        XCTAssertFalse(summary.isCurrent(notes: "A", transcript: "B!"))
        XCTAssertEqual(try JSONDecoder().decode(MeetingSummary.self, from: JSONEncoder().encode(summary)), summary)
    }
    func testSummaryReadsBothSourcesAndDoesNotExposeWritableTools() async throws {
        let transport = SummaryTransport()
        let connection = ModelConnection(client: try SplashClient(address: "http://127.0.0.1:8000", transport: transport))
        var note = MeetingNote(title: "Test"); note.notes = "No launch decision yet."; note.transcript = "We need another review."
        let summary = try await LocalMeetingSummarizer(connection: connection).summarize(note: note, contextTokens: 8192) { _, _ in }
        XCTAssertEqual(summary.keyPoints.map(\.quote), [note.notes, note.transcript])
        XCTAssertTrue(summary.isCurrent(notes: note.notes, transcript: note.transcript))
        let texts = await transport.texts; XCTAssertEqual(texts, [note.notes, note.transcript])
    }
    func testInvalidMetadataGetsOneStrictLocalRepairWithoutInventingAnOwner() async throws {
        let transport = SummaryTransport(repairable: true)
        let connection = ModelConnection(client: try SplashClient(address: "http://127.0.0.1:8000", transport: transport))
        var note = MeetingNote(title: "Test"); note.transcript = "Alex: I will review by Friday."
        let summary = try await LocalMeetingSummarizer(connection: connection).summarize(note: note, contextTokens: 8192) { _, _ in }
        XCTAssertEqual(summary.actions.first?.owner, "I")
        let requests = await transport.texts; XCTAssertEqual(requests.count, 2)
    }
    func testUnsupportedModelOutputFailsWholeSummary() async throws {
        let connection = ModelConnection(client: try SplashClient(address: "http://127.0.0.1:8000", transport: SummaryTransport(invalid: true)))
        var note = MeetingNote(title: "Test"); note.transcript = "We did not approve the launch."
        do { _ = try await LocalMeetingSummarizer(connection: connection).summarize(note: note, contextTokens: 8192) { _, _ in }; XCTFail("Expected unsupported quote rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("did not match")) }
    }
}
