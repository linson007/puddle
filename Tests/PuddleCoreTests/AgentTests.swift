import XCTest
import Foundation
@testable import PuddleCore

private func agentJSON(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

private actor AgentFixture: HTTPTransport {
    var responses: [[String: Any]]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [[String: Any]]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body: Data
        if request.url!.path == "/ready" { body = try agentJSON(["status": "ready"]) }
        else if request.url!.path == "/v1/models" { body = try agentJSON(["data": [["id": "local-qwen"]]]) }
        else {
            guard !responses.isEmpty else { throw PuddleError("No fixture response left") }
            body = try agentJSON(responses.removeFirst())
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor ToolRecorder {
    var names: [String] = []
    func record(_ call: AgentToolCall) -> String { names.append(call.function.name); return "Fixture result" }
}

private func reply(_ content: String, calls: [[String: Any]] = [], reason: String = "stop") -> [String: Any] {
    var message: [String: Any] = ["content": content]
    if !calls.isEmpty { message["tool_calls"] = calls }
    return ["choices": [["message": message, "finish_reason": reason]]]
}
private func call(_ name: String, arguments: Any, id: String = "call_1") -> [String: Any] {
    ["id": id, "type": "function", "function": ["name": name, "arguments": arguments]]
}

final class AgentTests: XCTestCase {
    func testNewChatSendsSavedNameWithoutPreviousConversationHistory() async throws {
        var state = AppSnapshot()
        state.remember(title: NameMemoryProposal.title, content: "Mira Rao")
        state.chat = [ChatLine(role: "user", content: "My name is Mira Rao")]
        state.startNewConversation()
        let fixture = AgentFixture([reply("Your name is Mira Rao.")])
        let agent = LocalAgent(splash: try SplashClient(address: "http://127.0.0.1:8000", transport: fixture))
        _ = try await agent.respond(question: "What is my name?", history: state.chat,
            context: AgentContext(memories: state.memories), tools: [.memories], execute: { _ in XCTFail("Saved name is already provided"); return "" })
        let requests = await fixture.requests
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: requests.last!.httpBody!) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue((messages[0]["content"] as? String)?.contains("Mira Rao") == true)
        XCTAssertEqual(messages[1]["content"] as? String, "What is my name?")
    }

    func testLiveModelRecallsSavedNameInANewChat() async throws {
        guard ProcessInfo.processInfo.environment["PUDDLE_LIVE_SPLASH"] == "1" else {
            throw XCTSkip("Set PUDDLE_LIVE_SPLASH=1 to check the running local model.")
        }
        var state = AppSnapshot()
        state.remember(title: NameMemoryProposal.title, content: "Mira Rao")
        state.startNewConversation()
        let agent = LocalAgent(splash: try SplashClient(address: "http://127.0.0.1:8000"))
        let answer = try await agent.respond(question: "What is my name?", history: state.chat,
            context: AgentContext(memories: state.memories), tools: [.memories],
            execute: { _ in "[{\"title\":\"Your name\",\"content\":\"Mira Rao\"}]" })
        XCTAssertTrue(answer.localizedCaseInsensitiveContains("Mira"), answer)
    }

    func testGeneralConversationWorksWithoutAccountsOrEmailContext() async throws {
        let fixture = AgentFixture([reply("Let’s explore your idea.")])
        let agent = LocalAgent(splash: try SplashClient(address: "http://127.0.0.1:8000", transport: fixture))
        let answer = try await agent.respond(question: "Help me brainstorm", history: [], context: AgentContext(), tools: [.memories, .tasks], execute: { _ in XCTFail("No tool needed"); return "" })
        XCTAssertEqual(answer, "Let’s explore your idea.")
        let requests = await fixture.requests
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: requests.last!.httpBody!) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.last?["content"] as? String, "Help me brainstorm")
        XCTAssertTrue((messages.first?["content"] as? String)?.contains("personal AI assistant") == true)
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertFalse(names.contains("search_mail")); XCTAssertFalse(names.contains("list_calendar_events"))
    }

    func testModelSelectedToolRunsAndResultReturnsWithMatchingCallID() async throws {
        let fixture = AgentFixture([
            reply("", calls: [call("list_calendar_events", arguments: ["days": 1])], reason: "tool_calls"),
            reply("You have a project review today.")])
        let recorder = ToolRecorder()
        let agent = LocalAgent(splash: try SplashClient(address: "http://127.0.0.1:8000", transport: fixture))
        let result = try await agent.respond(question: "What is on today?", history: [],
            context: AgentContext(calendarConnected: true), tools: [.calendar], execute: { await recorder.record($0) })
        XCTAssertEqual(result, "You have a project review today.")
        let names = await recorder.names
        XCTAssertEqual(names, ["list_calendar_events"])
        let requests = await fixture.requests
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: requests.last!.httpBody!) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.last?["role"] as? String, "tool")
        XCTAssertEqual(messages.last?["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(messages.last?["content"] as? String, "Fixture result")
    }

    func testUnavailableToolNeverReachesExecutor() async throws {
        let fixture = AgentFixture([reply("", calls: [call("search_mail", arguments: "{\"query\":\"\"}")]), reply("Connect Gmail if you want me to search it.")])
        let recorder = ToolRecorder()
        let agent = LocalAgent(splash: try SplashClient(address: "http://127.0.0.1:8000", transport: fixture))
        _ = try await agent.respond(question: "Any mail?", history: [], context: AgentContext(), tools: [.tasks], execute: { await recorder.record($0) })
        let names = await recorder.names
        XCTAssertTrue(names.isEmpty)
    }

    func testIncompleteToolCallDoesNotExecute() async throws {
        let fixture = AgentFixture([reply("", calls: [call("remember_fact", arguments: "{}")], reason: "length")])
        let recorder = ToolRecorder()
        let agent = LocalAgent(splash: try SplashClient(address: "http://127.0.0.1:8000", transport: fixture))
        do {
            _ = try await agent.respond(question: "Remember this", history: [], context: AgentContext(), tools: [.remember], execute: { await recorder.record($0) })
            XCTFail("Must reject incomplete calls")
        } catch { XCTAssertTrue(error.localizedDescription.contains("incomplete")) }
        let names = await recorder.names
        XCTAssertTrue(names.isEmpty)
    }

    func testDeclinedReminderIsReturnedToModelBeforeFinalAnswer() async throws {
        let fixture = AgentFixture([
            reply("", calls: [call("create_reminder", arguments: "{\"title\":\"Take a break\",\"due_at\":\"\"}")]),
            reply("Understood, I did not save it.")])
        let agent = LocalAgent(splash: try SplashClient(address: "http://127.0.0.1:8000", transport: fixture))
        let result = try await agent.respond(question: "Remind me to take a break", history: [], context: AgentContext(), tools: [.remind],
            execute: { _ in "The user declined this reminder. Nothing was saved." })
        XCTAssertEqual(result, "Understood, I did not save it.")
        let requests = await fixture.requests
        XCTAssertTrue(String(decoding: requests.last!.httpBody!, as: UTF8.self).contains("Nothing was saved"))
    }

    func testToolLoopHasAnExplicitStepLimit() async throws {
        let response = reply("", calls: [call("list_tasks", arguments: "{}")])
        let fixture = AgentFixture(Array(repeating: response, count: 6))
        let recorder = ToolRecorder()
        let agent = LocalAgent(splash: try SplashClient(address: "http://127.0.0.1:8000", transport: fixture))
        do {
            _ = try await agent.respond(question: "Keep going", history: [], context: AgentContext(), tools: [.tasks], execute: { await recorder.record($0) })
            XCTFail("Must stop")
        } catch { XCTAssertTrue(error.localizedDescription.contains("tool steps")) }
        let names = await recorder.names
        XCTAssertEqual(names.count, 6)
    }

    func testLongHistoryAndMemoryHaveBoundedPromptBudgets() async throws {
        let fixture = AgentFixture([reply("Hello")])
        let memories = (0..<50).map { MemoryNote(title: "Fact \($0)", content: String(repeating: "m", count: 4000)) }
        let history = (0..<40).map { _ in ChatLine(role: "user", content: String(repeating: "h", count: 10_000)) }
        let agent = LocalAgent(splash: try SplashClient(address: "http://127.0.0.1:8000", transport: fixture))
        _ = try await agent.respond(question: "Hello", history: history, context: AgentContext(memories: memories), tools: [], execute: { _ in "" })
        let requests = await fixture.requests
        XCTAssertLessThan(requests.last!.httpBody!.count, 45_000)
    }

    func testToolArgumentsAcceptObjectOrJSONString() throws {
        for arguments: Any in ["{\"query\":\"unread\"}", ["query": "unread"]] {
            let decoded = try JSONDecoder().decode(AgentToolCall.self, from: agentJSON(call("search_mail", arguments: arguments)))
            XCTAssertEqual(try decoded.parameters()["query"] as? String, "unread")
        }
    }
}

final class AssistantStateTests: XCTestCase {
    func testOlderInboxStateMigratesWithoutLosingConversation() throws {
        let old: [String: Any] = ["account": "you@example.test", "chat": [["id": UUID().uuidString, "role": "user", "content": "Keep this conversation"]]]
        let state = try JSONDecoder().decode(AppSnapshot.self, from: agentJSON(old))
        XCTAssertEqual(state.chat.first?.content, "Keep this conversation")
        XCTAssertTrue(state.memories.isEmpty); XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertFalse(state.assistantInstructions.isEmpty)
    }
    func testMemoryUpdatesByTitleAndSurvivesEncoding() throws {
        var state = AppSnapshot()
        state.remember(title: "Writing style", content: "Short")
        let id = state.memories[0].id
        state.remember(title: "writing STYLE", content: "Short and practical")
        XCTAssertEqual(state.memories.count, 1)
        XCTAssertEqual(state.memories[0].id, id)
        let restored = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.memories[0].content, "Short and practical")
    }
    func testRemindersFireOnceAndOverdueItemsCatchUpAfterRestart() throws {
        var state = AppSnapshot()
        let now = Date()
        state.tasks = [AssistantTask(title: "Overdue", dueAt: now.addingTimeInterval(-10)),
                       AssistantTask(title: "Later", dueAt: now.addingTimeInterval(100)), AssistantTask(title: "Undated")]
        var restored = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.dueReminders(now: now).map(\.title), ["Overdue"])
        XCTAssertTrue(restored.dueReminders(now: now).isEmpty)
        XCTAssertEqual(restored.dueReminders(now: now.addingTimeInterval(101)).map(\.title), ["Later"])
    }
    func testCompletedTasksDoNotTriggerReminders() {
        var state = AppSnapshot()
        var task = AssistantTask(title: "Done", dueAt: Date().addingTimeInterval(-1)); task.completed = true
        state.tasks = [task]
        XCTAssertTrue(state.dueReminders().isEmpty)
    }
}

final class CalendarTests: XCTestCase {
    func testCalendarSupportsTimedAllDayAndCancelledEvents() throws {
        let data = try agentJSON(["items": [
            ["id": "timed", "summary": "Review", "htmlLink": "https://www.google.com/calendar/event?eid=fixture", "start": ["dateTime": "2026-10-29T10:00:00+05:30"], "end": ["dateTime": "2026-10-29T11:00:00+05:30"]],
            ["id": "day", "summary": "Holiday", "start": ["date": "2026-10-30"]],
            ["id": "gone", "status": "cancelled"]]])
        let events = try GoogleCalendarClient.decode(data)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].start, "2026-10-29T10:00:00+05:30")
        XCTAssertEqual(events[0].sourceURL?.host, "www.google.com")
        XCTAssertEqual(events[1].start, "2026-10-30")
    }
    func testCalendarConnectionCanBeRequestedWithoutGmail() throws {
        let flow = OAuthFlow(verifier: "verifier", state: "state", scopes: [OAuthFlow.calendarScope])
        let url = flow.authorizationURL(client: .init(clientID: "test.apps.googleusercontent.com"), redirect: URL(string: "http://127.0.0.1:4321/")!)
        let scope = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "scope" }!.value
        XCTAssertEqual(Set(scope!.split(separator: " ").map(String.init)), Set(OAuthFlow.identityScopes + [OAuthFlow.calendarScope]))
        XCTAssertFalse(scope!.contains("gmail"))
    }
    func testCalendarUsesReadOnlyGETWithBoundedUpcomingWindow() async throws {
        let transport = FixtureTransport { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.host, "www.googleapis.com")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first { $0.name == "maxResults" }?.value, "50")
            XCTAssertEqual(items.first { $0.name == "singleEvents" }?.value, "true")
            return (try agentJSON(["items": []]), 200)
        }
        let secrets = MemorySecrets()
        try secrets.write(JSONEncoder().encode(GoogleCredentials(accessToken: "access", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600), scope: OAuthFlow.calendarScope)), key: "google-tokens")
        let session = GoogleSession(store: secrets, transport: transport)
        let events = try await GoogleCalendarClient(session: session, transport: transport).upcoming(days: 999)
        XCTAssertTrue(events.isEmpty)
    }
}
