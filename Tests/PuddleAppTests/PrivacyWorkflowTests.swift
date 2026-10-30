import Foundation
import XCTest
@testable import Puddle
@testable import PuddleCore

private final class PrivacyDisk: SnapshotPersistence, @unchecked Sendable {
    var snapshot = AppSnapshot()
    func load() throws -> AppSnapshot { snapshot }
    func save(_ next: AppSnapshot) throws { snapshot = next }
}
private final class PrivacySecrets: SecretStore, @unchecked Sendable {
    func read(_ key: String) throws -> Data? { nil }
    func write(_ data: Data, key: String) throws {}
    func delete(_ key: String) throws {}
}
private actor PrivacyHTTP: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.url?.path == "/v1/models" ? #"{"data":[{"id":"fixture"}]}"# : #"{"choices":[{"message":{"content":"Private fixture reply"},"finish_reason":"stop"}]}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor final class PrivacyWorkflowTests: XCTestCase {
    private final class Scheduler: ReminderScheduling {
        var calls = 0
        func reconcile(tasks: [AssistantTask], enabled: Bool) async throws { calls += 1 }
    }
    func testPrivateSessionNeverPersistsItsChatTasksOrMemories() async throws {
        let disk = PrivacyDisk(), scheduler = Scheduler()
        disk.snapshot.chat = [ChatLine(role: "user", content: "Saved chat")]
        let store = PuddleStore(cache: disk, secrets: PrivacySecrets(), transport: PrivacyHTTP(), reminderScheduler: scheduler)
        await store.start(); await Task.yield(); let before = scheduler.calls
        store.beginPrivateSession()
        XCTAssertTrue(store.privateSession); XCTAssertFalse(store.availableTools.contains(.remember)); XCTAssertFalse(store.availableTools.contains(.proposeEmail))
        store.addTask(title: "Ephemeral task", dueAt: Date().addingTimeInterval(600))
        store.ask("Explain a simple idea")
        for _ in 0..<200 where store.isThinking { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(store.state.chat.contains { $0.content.contains("Private fixture") })
        XCTAssertEqual(disk.snapshot.chat.first?.content, "Saved chat"); XCTAssertTrue(disk.snapshot.tasks.isEmpty)
        XCTAssertEqual(scheduler.calls, before)
        store.endPrivateSession(); XCTAssertFalse(store.privateSession)
        XCTAssertEqual(store.state.chat.first?.content, "Saved chat"); XCTAssertTrue(store.state.tasks.isEmpty)
    }
    func testPausedAssistantKeepsCachedBriefButDoesNotAdvertiseFreshProviderTools() async {
        let store = PuddleStore(cache: PrivacyDisk(), secrets: PrivacySecrets(), transport: PrivacyHTTP(), reminderScheduler: Scheduler())
        await store.start(); store.connected = true; store.grantedScopes = [OAuthFlow.scope, OAuthFlow.calendarScope]
        XCTAssertTrue(store.availableTools.contains(.searchMail)); XCTAssertTrue(store.availableTools.contains(.calendar))
        store.setExternalConnectionsPaused(true)
        XCTAssertFalse(store.availableTools.contains(.searchMail)); XCTAssertFalse(store.availableTools.contains(.calendar))
        XCTAssertTrue(store.availableTools.contains(.briefing)); XCTAssertTrue(store.availableTools.contains(.tasks))
        store.suspendConnectionWork()
    }
    func testNetworkPauseAllowsLoopbackAndRejectsExternalRequests() throws {
        let policy = NetworkPolicy(); policy.allowExternalConnections(false)
        XCTAssertNoThrow(try policy.check(URL(string: "http://127.0.0.1:8000")))
        XCTAssertThrowsError(try policy.check(URL(string: "https://gmail.googleapis.com")))
        policy.allowExternalConnections(true)
        XCTAssertNoThrow(try policy.check(URL(string: "https://gmail.googleapis.com")))
    }
    func testLockDisablesToolsAndPreventsChatSubmission() async {
        let store = PuddleStore(cache: PrivacyDisk(), secrets: PrivacySecrets(), transport: PrivacyHTTP(), reminderScheduler: Scheduler())
        await store.start(); store.lockWorkspace(); store.ask("Must not run")
        XCTAssertTrue(store.isLocked); XCTAssertTrue(store.availableTools.isEmpty); XCTAssertTrue(store.state.chat.isEmpty)
        store.unlockWorkspace(); XCTAssertFalse(store.isLocked)
    }
    func testRetentionPreservesCurrentConversationAndRecentArchives() async throws {
        let disk = PrivacyDisk()
        disk.snapshot.chat = [ChatLine(role: "user", content: "Current")]
        disk.snapshot.settings.archiveRetentionDays = 30
        disk.snapshot.conversations = [Conversation(createdAt: Date().addingTimeInterval(-90 * 86400), lines: [ChatLine(role: "user", content: "Old")]), Conversation(lines: [ChatLine(role: "user", content: "Recent")])]
        let store = PuddleStore(cache: disk, secrets: PrivacySecrets(), transport: PrivacyHTTP(), reminderScheduler: Scheduler())
        await store.start(); XCTAssertEqual(store.expiredArchiveIDs.count, 1); store.applyArchiveRetention()
        XCTAssertEqual(disk.snapshot.conversations.count, 1); XCTAssertEqual(disk.snapshot.chat.first?.content, "Current")
    }
}
