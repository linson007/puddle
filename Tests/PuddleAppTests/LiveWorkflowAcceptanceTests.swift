import Foundation
import XCTest
import PuddleCore
@testable import Puddle

private final class AcceptanceSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    func write(_ data: Data, key: String) throws { lock.withLock { values[key] = data } }
    func delete(_ key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

/// Live inference, synthetic workspace, no provider traffic or OS notifications.
private struct AcceptanceHTTP: HTTPTransport {
    let base = URLSessionTransport()
    private func check(_ request: URLRequest) throws {
        guard request.url?.host == "127.0.0.1", request.url?.port == 8000 else {
            throw PuddleError("Live acceptance allows only the synthetic local Splash endpoint.")
        }
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try check(request); return try await base.send(request)
    }
    func stream(_ request: URLRequest, onLine: @Sendable (String) async throws -> Void) async throws -> HTTPURLResponse {
        try check(request); return try await base.stream(request, onLine: onLine)
    }
}
@MainActor private final class AcceptanceReminders: ReminderScheduling {
    func reconcile(tasks: [AssistantTask], enabled: Bool) async throws {
        XCTAssertFalse(enabled, "Live acceptance must not schedule personal macOS notifications")
    }
}

@MainActor final class LiveWorkflowAcceptanceTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let secrets = AcceptanceSecrets()
        init(learning: Bool) throws {
            guard ProcessInfo.processInfo.environment["PUDDLE_LIVE_SPLASH"] == "1" else {
                throw XCTSkip("Set PUDDLE_LIVE_SPLASH=1 for synthetic end-to-end app/model acceptance")
            }
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("puddle-live-workflow-\(UUID())")
            var state = AppSnapshot()
            state.settings.automaticallyLearn = learning; state.settings.automaticallyCheck = false
            state.settings.notifications = false; state.settings.contextTokens = 8192
            try EncryptedSnapshotStore(directory: directory, secrets: secrets).save(state)
        }
        @MainActor func store() -> PuddleStore {
            PuddleStore(directory: directory, cache: EncryptedSnapshotStore(directory: directory, secrets: secrets),
                secrets: secrets, transport: AcceptanceHTTP(), reminderScheduler: AcceptanceReminders())
        }
    }
    private func wait(_ message: String, until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw PuddleError("Live acceptance timed out: \(message)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private func start(_ store: PuddleStore) async throws {
        await store.start(); await store.testSplash()
        try await wait("local model connection") { store.splashModel != nil || store.errorMessage != nil }
        XCTAssertNotNil(store.splashModel, store.errorMessage ?? "No local model")
        XCTAssertFalse(store.mailConnected); XCTAssertFalse(store.calendarConnected)
    }
    private func finish(_ store: PuddleStore) async throws {
        try await wait("assistant turn") { !store.isThinking || store.pendingApproval != nil }
        guard store.pendingApproval == nil else { throw PuddleError("Unexpected action review during a read-only acceptance turn") }
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
    }
    private func stop(_ store: PuddleStore) { store.stopAI(); store.suspendConnectionWork() }
    private func report(_ name: String, store: PuddleStore, values: [String: Any]) throws {
        guard let path = ProcessInfo.processInfo.environment["PUDDLE_ACCEPTANCE_OUTPUT_DIRECTORY"] else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var object = values
        object["model"] = store.splashModel; object["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        object["memory_bytes"] = ProcessInfo.processInfo.physicalMemory; object["context_tokens"] = store.state.settings.contextTokens
        let file = folder.appendingPathComponent(name + ".json")
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func testLiveMemoryLearningCorrectionForgettingAndRestart() async throws {
        let fixture = try Fixture(learning: true), store = fixture.store()
        defer { stop(store); try? FileManager.default.removeItem(at: fixture.directory) }
        try await start(store)
        store.ask("My name is Amara. I prefer concise replies."); try await finish(store)
        XCTAssertTrue(store.state.memories.contains { MemoryLearning.identity($0.title) == "identity.name" && $0.content == "Amara" })
        XCTAssertTrue(store.state.memories.contains { $0.content.localizedCaseInsensitiveContains("concise") })
        store.clearChat(); store.ask("What is my name and how do I prefer you to reply?"); try await finish(store)
        let recalled = store.state.chat.last?.content ?? ""
        XCTAssertTrue(recalled.contains("Amara"), recalled)
        XCTAssertTrue(recalled.localizedCaseInsensitiveContains("concise"), recalled)
        store.ask("My name is Leena."); try await finish(store)
        let names = store.state.memories.filter { MemoryLearning.identity($0.title) == "identity.name" }
        XCTAssertEqual(names.count, 1); XCTAssertEqual(names.first?.content, "Leena")
        store.setAutomaticLearning(false)
        let before = store.state.memories
        store.ask("I prefer very long academic essays."); try await finish(store)
        XCTAssertEqual(store.state.memories, before)
        store.removeMemory(try XCTUnwrap(names.first).id)
        store.clearChat(); stop(store)
        let reopened = fixture.store(); defer { stop(reopened) }
        try await start(reopened)
        XCTAssertFalse(reopened.state.memories.contains { MemoryLearning.identity($0.title) == "identity.name" })
        reopened.ask("Do you know my name? If it is not in your saved context, say you do not know."); try await finish(reopened)
        let forgotten = reopened.state.chat.last?.content ?? ""
        XCTAssertFalse(forgotten.contains("Amara")); XCTAssertFalse(forgotten.contains("Leena"))
        try report("memory-workflow", store: reopened, values: ["recall": recalled, "after_forget": forgotten, "memory_count": reopened.state.memories.count])
    }

    func testLiveReminderReviewDeclinePersistenceCompletionAndRetry() async throws {
        let fixture = try Fixture(learning: false), store = fixture.store()
        defer { stop(store); try? FileManager.default.removeItem(at: fixture.directory) }
        try await start(store)
        let due = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 7200)
        let question = "Create a reminder titled Check the blue notebook at \(due.ISO8601Format()). Use that exact title and time."
        store.ask(question)
        try await wait("reminder review") { store.pendingApproval != nil || !store.isThinking }
        _ = try XCTUnwrap(store.pendingApproval, store.state.chat.last?.content ?? store.errorMessage ?? "No review")
        XCTAssertTrue(store.state.tasks.isEmpty)
        store.resolveApproval(false); try await finish(store)
        XCTAssertTrue(store.state.tasks.isEmpty)
        store.clearChat(); store.ask(question)
        try await wait("second reminder review") { store.pendingApproval != nil || !store.isThinking }
        _ = try XCTUnwrap(store.pendingApproval, store.state.chat.last?.content ?? "No review")
        store.resolveApproval(true); try await finish(store)
        let task = try XCTUnwrap(store.state.tasks.first)
        XCTAssertEqual(store.state.tasks.count, 1); XCTAssertEqual(task.title, "Check the blue notebook")
        XCTAssertEqual(try XCTUnwrap(task.dueAt).timeIntervalSince1970, due.timeIntervalSince1970, accuracy: 1)
        stop(store)
        let reopened = fixture.store(); defer { stop(reopened) }
        try await start(reopened)
        XCTAssertEqual(reopened.state.tasks.first?.id, task.id)
        reopened.ask("Mark my saved task Check the blue notebook complete.")
        try await wait("completion review") { reopened.pendingApproval != nil || !reopened.isThinking }
        let reviewTrace = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reopened.state.chat))
        try report("task-completion-review", store: reopened, values: ["chat": reviewTrace,
            "task_ids": reopened.state.tasks.map { $0.id.uuidString }, "task_titles": reopened.state.tasks.map(\.title)])
        _ = try XCTUnwrap(reopened.pendingApproval, reopened.state.chat.last?.content ?? "No review")
        XCTAssertFalse(reopened.state.tasks[0].completed)
        reopened.resolveApproval(true); try await finish(reopened)
        XCTAssertTrue(reopened.state.tasks[0].completed)
        reopened.retryLastQuestion(); try await finish(reopened)
        XCTAssertEqual(reopened.state.tasks.count, 1); XCTAssertTrue(reopened.state.tasks[0].completed)
        XCTAssertEqual(reopened.state.chat.last(where: { $0.role == "user" })?.receipts?.filter { $0.tool == AgentTool.updateTask.rawValue && $0.status == "completed" }.count, 1)
        try report("task-workflow", store: reopened, values: ["title": task.title, "due_at": due.ISO8601Format(), "reply_after_retry": reopened.state.chat.last?.content ?? ""])
    }

    func testLiveStopDiscardsLateStreamAndNextTurnWorks() async throws {
        let fixture = try Fixture(learning: false), store = fixture.store()
        defer { stop(store); try? FileManager.default.removeItem(at: fixture.directory) }
        try await start(store)
        store.ask("Write a numbered list of 250 detailed ideas for organizing a synthetic notebook. Do not use tools.")
        try await wait("first streamed text") { !store.streamingReply.isEmpty || !store.isThinking }
        XCTAssertTrue(store.isThinking, "The long response completed before cancellation could be exercised")
        store.stopAI(); store.clearChat()
        XCTAssertFalse(store.isThinking); XCTAssertTrue(store.streamingReply.isEmpty)
        store.ask("Reply with exactly: ready-for-next-turn"); try await finish(store)
        XCTAssertEqual(store.state.chat.count, 2)
        let answer = store.state.chat.last?.content ?? ""
        XCTAssertTrue(answer.contains("ready-for-next-turn"), answer)
        try report("cancellation-workflow", store: store, values: ["next_turn_reply": answer])
    }

    func testLiveNamedTaskLookupAfterRestartUsesCurrentSavedIds() async throws {
        let fixture = try Fixture(learning: false), seed = fixture.store()
        defer { stop(seed); try? FileManager.default.removeItem(at: fixture.directory) }
        try await start(seed)
        let cases = [("Review amber notebook", "Finish my saved task Review amber notebook."),
            ("Call the synthetic library", "Mark Call the synthetic library as done."),
            ("Water the test plant", "Complete my Water the test plant task.")]
        for (title, _) in cases { XCTAssertTrue(seed.addTask(title: title, dueAt: nil)) }
        stop(seed)
        for (title, question) in cases {
            let store = fixture.store(); defer { stop(store) }
            try await start(store); store.clearChat(); store.ask(question)
            try await wait("named task lookup") { store.pendingApproval != nil || !store.isThinking }
            let approval = try XCTUnwrap(store.pendingApproval, store.state.chat.last?.content ?? "No review")
            XCTAssertTrue(approval.detail.contains(title), approval.detail)
            XCTAssertTrue(store.state.chat.last(where: { $0.role == "user" })?.receipts?.contains {
                $0.tool == AgentTool.tasks.rawValue && $0.status == "completed"
            } == true, "The model must read the current list before updating a saved task")
            store.resolveApproval(false); try await finish(store)
            XCTAssertTrue(store.state.tasks.allSatisfy { !$0.completed })
            stop(store)
        }
    }

    func testLiveWarmPlanningLatencyAndHonestMissingContext() async throws {
        let fixture = try Fixture(learning: false), store = fixture.store()
        defer { stop(store); try? FileManager.default.removeItem(at: fixture.directory) }
        try await start(store)
        let prompts = ["Give three short steps for planning a quiet morning.", "Give three short steps to organize a desk.",
            "Give three short steps for preparing a personal weekly review.", "Give three short steps to start a reading habit.",
            "Give three short steps to organize a notebook."]
        var firstTokens: [Double] = [], totals: [Double] = [], replies: [String] = []
        for prompt in prompts {
            store.clearChat(); store.ask(prompt + " Answer in under 80 words. No tools or saved context are needed.")
            try await finish(store)
            let line = try XCTUnwrap(store.state.chat.last)
            let metrics = try XCTUnwrap(line.metrics)
            firstTokens.append(try XCTUnwrap(metrics.firstTokenSeconds)); totals.append(metrics.totalSeconds)
            replies.append(line.content); XCTAssertFalse(line.content.isEmpty)
            XCTAssertTrue(store.state.tasks.isEmpty); XCTAssertTrue(store.state.actionProposals.isEmpty)
        }
        func p95(_ values: [Double]) -> Double { values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1] }
        // Initial warm, concise-response targets for the explicitly tested configuration.
        XCTAssertLessThan(p95(firstTokens), 5); XCTAssertLessThan(p95(totals), 30)
        store.clearChat(); store.ask("What is my dentist's name? If I have not told you, say you do not know; do not invent one.")
        try await finish(store)
        let missing = store.state.chat.last?.content ?? ""
        let honestLimits = ["don't know", "do not know", "haven't", "don't have", "do not have", "no record", "not provided", "not shared"]
        XCTAssertTrue(honestLimits.contains { missing.localizedCaseInsensitiveContains($0) }, missing)
        try report("planning-latency", store: store, values: ["prompts": prompts, "replies": replies, "missing_context_reply": missing,
            "first_token_seconds": firstTokens, "total_seconds": totals, "first_token_p95_seconds": p95(firstTokens), "total_p95_seconds": p95(totals),
            "first_token_budget_seconds": 5, "total_budget_seconds": 30])
    }
}
