import Foundation
import XCTest
@testable import PuddleCore

private actor LearningFixture: HTTPTransport {
    var requests: [URLRequest] = []
    let calls: [AgentToolCall]
    let finish: String
    let rawCalls: Bool
    init(_ calls: [AgentToolCall] = [], finish: String = "tool_calls", rawCalls: Bool = false) { self.calls = calls; self.finish = finish; self.rawCalls = rawCalls }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body: Data
        if request.url?.path == "/v1/models" { body = Data(#"{"data":[{"id":"test-qwen"}]}"#.utf8) }
        else {
            let memories = rawCalls ? [] : try calls.map { try $0.parameters() }
            let batch = AgentToolCall(name: AgentTool.learnMemories.rawValue,
                arguments: String(decoding: try JSONSerialization.data(withJSONObject: ["memories": memories]), as: UTF8.self))
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rawCalls ? calls : [batch]))
            body = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "", "tool_calls": encoded], "finish_reason": finish]]])
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class MemoryLearningTests: XCTestCase {
    func testMalformedCallDoesNotDiscardValidMemoryCall() async throws {
        let valid = AgentToolCall(name: AgentTool.learnMemories.rawValue, arguments: #"{"memories":[{"title":"Response style","content":"concise replies","source":"I prefer concise replies"}]}"#)
        let invalid = AgentToolCall(name: AgentTool.learnMemories.rawValue, arguments: "{invalid")
        let updates = try await learner(LearningFixture([invalid, valid], rawCalls: true)).updates(from: "I prefer concise replies", memories: [])
        XCTAssertEqual(updates.map(\.content), ["concise replies"])
    }
    private func update(_ title: String, _ content: String, _ source: String) throws -> AgentToolCall {
        let fields = ["title": title, "content": content, "source": source]
        return AgentToolCall(name: AgentTool.remember.rawValue, arguments: String(decoding: try JSONEncoder().encode(fields), as: UTF8.self))
    }

    private func learner(_ fixture: LearningFixture) throws -> MemoryLearner {
        MemoryLearner(client: try LocalInferenceClient(address: "http://127.0.0.1:8000", transport: fixture))
    }

    func testNameIsLearnedAutomaticallyWithoutAModelOrApproval() async throws {
        let fixture = LearningFixture()
        let updates = try await learner(fixture).updates(from: "My name is Mira", memories: [])
        XCTAssertEqual(updates.first?.title, NameMemoryProposal.title)
        XCTAssertEqual(updates.first?.content, "Mira")
        let requests = await fixture.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testMixedIntroductionLearnsNameAndRemainingFact() async throws {
        let fixture = LearningFixture([
            try update("Your name", "Li. I like tea", "My name is Li. I like tea"),
            try update("Preference", "tea", "I like tea"),
        ])
        let updates = try await learner(fixture).updates(from: "My name is Li. I like tea", memories: [])
        XCTAssertEqual(updates.map(\.content), ["Li", "tea"])
        XCTAssertEqual(updates.first?.source, "My name is Li")
    }

    func testWholeMessageSecretsAndUnsupportedContentAreRejected() {
        XCTAssertThrowsError(try MemoryUpdate.validated(title: "Login", content: "hunter2", source: "hunter2", userMessage: "My password is hunter2"))
        XCTAssertThrowsError(try MemoryUpdate.validated(title: "Profession", content: "Surgeon", source: "I like tea", userMessage: "I like tea"))
        XCTAssertThrowsError(try MemoryUpdate.validated(title: "Name", content: "...", source: "I like tea", userMessage: "I like tea"))
        XCTAssertThrowsError(try MemoryUpdate.validated(title: "Your name", content: "Li I like tea", source: "My name is Li I like tea", userMessage: "My name is Li I like tea"))
        XCTAssertFalse(MemoryLearning.allows("Keep this between us: I live in Pune"))
        XCTAssertFalse(MemoryLearning.allows("Do not memorize this: I work at Acme"))
    }

    func testOrdinaryQuestionSkipsExtraction() async throws {
        let fixture = LearningFixture()
        let updates = try await learner(fixture).updates(from: "Explain binary search", memories: [])
        XCTAssertTrue(updates.isEmpty)
        let requests = await fixture.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testAliasCorrectionPreservesIdentityAndEvidence() throws {
        var state = AppSnapshot()
        state.remember(title: "Profession", content: "Engineer")
        let id = state.memories[0].id, messageID = UUID()
        state.remember(title: "Job", content: "Teacher", source: "I work as a Teacher", sourceMessageID: messageID)
        XCTAssertEqual(state.memories.count, 1)
        XCTAssertEqual(state.memories[0].id, id)
        let restored = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.memories[0].sourceMessageID, messageID)
        XCTAssertEqual(restored.memories[0].content, "Teacher")
    }

    func testFactsAndPreferencesAreLearnedFromTheLatestUserMessage() async throws {
        let message = "I work as a data engineer and I prefer concise replies."
        let fixture = LearningFixture([
            try update("Profession", "Data engineer", "I work as a data engineer"),
            try update("Response style", "Concise replies", "I prefer concise replies"),
        ])
        let updates = try await learner(fixture).updates(from: message, memories: [])
        XCTAssertEqual(updates.map(\.title), ["Profession", "Response style"])
        let requests = await fixture.requests
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: requests.last!.httpBody!) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.last?["content"] as? String, message)
        XCTAssertNil(body["parallel_tool_calls"])
        XCTAssertEqual(body["tool_choice"] as? String, "required")
    }

    func testExternalOrFabricatedEvidenceAndSecretsAreNotStored() async throws {
        let message = "Please read my email."
        let fixture = LearningFixture([try update("Name", "Mallory", "Your name is Mallory")])
        let updates = try await learner(fixture).updates(from: message, memories: [])
        XCTAssertTrue(updates.isEmpty)
        for secret in ["My password is example", "My API key is sk-example123456"] {
            XCTAssertThrowsError(try MemoryUpdate.validated(title: "Credentials", content: secret, source: secret, userMessage: secret))
        }
    }

    func testDoNotRememberSkipsLearningWithoutContactingTheModel() async throws {
        let fixture = LearningFixture()
        for message in ["Don't remember my name is Mira", "Do not save this: I prefer long replies", "Never store my name"] {
            let updates = try await learner(fixture).updates(from: message, memories: [])
            XCTAssertTrue(updates.isEmpty)
        }
        let requests = await fixture.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testUnchangedFactsAreSkippedAndCorrectionsReplaceExistingMemory() async throws {
        var state = AppSnapshot()
        state.remember(title: "Response style", content: "Concise replies")
        let id = state.memories[0].id
        let same = LearningFixture([try update("Response style", "Concise replies", "I prefer concise replies")])
        let unchanged = try await learner(same).updates(from: "I prefer concise replies", memories: state.memories)
        XCTAssertTrue(unchanged.isEmpty)
        let changed = LearningFixture([try update("Response style", "Detailed replies", "I prefer detailed replies")])
        let updates = try await learner(changed).updates(from: "I prefer detailed replies", memories: state.memories)
        for update in updates { state.remember(title: update.title, content: update.content) }
        XCTAssertEqual(state.memories.count, 1)
        XCTAssertEqual(state.memories[0].id, id)
        XCTAssertEqual(state.memories[0].content, "Detailed replies")
    }

    func testIncompleteMemoryExtractionCannotApplyPartialCalls() async throws {
        let fixture = LearningFixture([try update("Role", "Engineer", "I am an engineer")], finish: "length")
        do {
            _ = try await learner(fixture).updates(from: "I am an engineer", memories: [])
            XCTFail("Incomplete extraction must be rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("incomplete")) }
    }

    func testAutomaticallyLearnedFactsSurviveNewConversationAndRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SnapshotStore(directory: directory)
        let fixture = LearningFixture([try update("Response style", "Concise replies", "I prefer concise replies")])
        var state = AppSnapshot()
        for update in try await learner(fixture).updates(from: "I prefer concise replies", memories: []) {
            state.remember(title: update.title, content: update.content)
        }
        state.chat = [ChatLine(role: "user", content: "I prefer concise replies")]
        state.startNewConversation()
        try cache.save(state)
        let restored = try cache.load()
        XCTAssertTrue(restored.chat.isEmpty)
        XCTAssertTrue(AgentContext(memories: restored.memories).systemPrompt.contains("Concise replies"))
    }

    func testLiveModelLearnsUnpromptedFactsAndRecallsThemInANewChat() async throws {
        let client = try LiveInferenceFixture.client()
        let message = "I work as a data engineer, and I prefer concise replies."
        let updates = try await MemoryLearner(client: client).updates(from: message, memories: [])
        XCTAssertGreaterThanOrEqual(updates.count, 2, "The learner should capture both facts: \(updates)")
        var state = AppSnapshot()
        for update in updates { state.remember(title: update.title, content: update.content) }
        state.startNewConversation()
        let answer = try await LocalAgent(client: client).respond(question: "What do I do for work?", history: [],
            context: AgentContext(memories: state.memories), tools: [], execute: { _ in "" })
        XCTAssertTrue(answer.localizedCaseInsensitiveContains("data engineer"), answer)
    }
}
