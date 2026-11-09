import Foundation
import XCTest
@testable import Puddle
@testable import PuddleCore

private final class LifecycleDisk: SnapshotPersistence, @unchecked Sendable {
    private let lock = NSLock()
    var snapshot = AppSnapshot()
    func load() -> AppSnapshot { lock.withLock { snapshot } }
    func save(_ state: AppSnapshot) { lock.withLock { snapshot = state } }
}
private final class LifecycleSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var rejectDelete = false
    func failDeletion(_ value: Bool) { lock.withLock { rejectDelete = value } }
    func read(_ key: String) -> Data? { lock.withLock { values[key] } }
    func write(_ data: Data, key: String) { lock.withLock { values[key] = data } }
    func delete(_ key: String) throws {
        try lock.withLock {
            if rejectDelete, key == "google-tokens" { throw PuddleError("Fixture Keychain deletion denied") }
            values.removeValue(forKey: key)
        }
    }
}
private actor LifecycleHTTP: HTTPTransport {
    let profileGate = AsyncTestGate()
    var profiles = 0, cancelledProfiles = 0
    var draftBody: String?
    func draft(_ body: String) { draftBody = body }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: Data
        if request.url?.path.hasSuffix("/profile") == true {
            profiles += 1
            if profiles == 1 {
                await profileGate.pause()
                if Task.isCancelled { cancelledProfiles += 1 }
            }
            body = Data(#"{"emailAddress":"fixture@example.test","historyId":"current"}"#.utf8)
        } else if request.url?.path == "/v1/models" { body = Data(#"{"data":[{"id":"fixture","max_model_len":32768}]}"#.utf8) }
        else if request.url?.path == "/v1/chat/completions", let draftBody {
            let input = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
            let messages = input["messages"] as! [[String: Any]]
            if messages.last?["role"] as? String == "tool" { body = Data(#"{"choices":[{"message":{"content":"Finished"},"finish_reason":"stop"}]}"#.utf8) }
            else {
                let call = AgentToolCall(name: AgentTool.proposeEmail.rawValue, arguments: String(decoding: try JSONEncoder().encode(["to": "recipient@example.test", "subject": "Fixture", "body": draftBody, "source_message_id": ""]), as: UTF8.self))
                let calls = try JSONSerialization.jsonObject(with: JSONEncoder().encode([call]))
                body = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["tool_calls": calls], "finish_reason": "tool_calls"]]])
            }
        } else { body = Data(#"{"messages":[]}"#.utf8) }
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor private final class LifecycleReminders: ReminderScheduling {
    var enabled = false
    var pendingTitles: [String] = []
    func reconcile(tasks: [AssistantTask], enabled: Bool) async throws {
        self.enabled = enabled; pendingTitles = enabled ? tasks.map(\.title) : []
    }
}

@MainActor final class IssueLifecycleTests: XCTestCase {
    private func fixture() async -> (PuddleStore, LifecycleDisk, LifecycleSecrets, LifecycleHTTP, LifecycleReminders) {
        let disk = LifecycleDisk(), secrets = LifecycleSecrets(), http = LifecycleHTTP(), reminders = LifecycleReminders()
        disk.snapshot.settings.automaticallyCheck = false
        disk.snapshot.settings.automaticallyLearn = false
        let store = PuddleStore(cache: disk, secrets: secrets, transport: http, reminderScheduler: reminders)
        await store.start()
        return (store, disk, secrets, http, reminders)
    }
    private func connect(_ store: PuddleStore, secrets: LifecycleSecrets) throws {
        let credentials = GoogleCredentials(accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture, scope: OAuthFlow.scope,
            account: GoogleAccount(id: "fixture", email: "fixture@example.test", name: nil))
        secrets.write(try JSONEncoder().encode(credentials), key: "google-tokens")
        store.connected = true; store.grantedScopes = [OAuthFlow.scope]; store.state.account = "fixture@example.test"
    }
    func testPrivateSessionRefusesBothDemoTransitionsAndRetainsEphemeralWork() async throws {
        let (store, _, _, _, _) = await fixture()
        await store.beginPrivateSession()
        let ephemeral = ChatLine(role: "user", content: "Private work")
        store.state.chat = [ephemeral]
        await store.enterDemo(); await store.leaveDemo()
        XCTAssertTrue(store.privateSession); XCTAssertFalse(store.demo)
        XCTAssertEqual(store.state.chat, [ephemeral])
        await store.endPrivateSession(); await store.suspendConnectionWork()
    }
    func testFailedGoogleDisconnectKeepsActualConnectionAndCanRetry() async throws {
        let (store, _, secrets, _, _) = await fixture()
        try connect(store, secrets: secrets); secrets.failDeletion(true)
        await store.disconnect()
        XCTAssertTrue(store.connected); XCTAssertEqual(store.grantedScopes, [OAuthFlow.scope])
        XCTAssertNotNil(store.errorMessage); XCTAssertFalse(store.isDisconnecting)
        XCTAssertNotNil(secrets.read("google-tokens")); XCTAssertEqual(store.state.account, "fixture@example.test")
        secrets.failDeletion(false); await store.disconnect()
        XCTAssertFalse(store.connected); XCTAssertTrue(store.grantedScopes.isEmpty)
        XCTAssertNil(secrets.read("google-tokens")); XCTAssertNil(store.state.account)
        await store.suspendConnectionWork()
    }
    func testRefreshCancelsAndDrainsPreviousTrackedSyncBeforeReplacement() async throws {
        let (store, _, secrets, http, _) = await fixture()
        try connect(store, secrets: secrets)
        await store.refresh(); await fulfillment(of: [http.profileGate.entered], timeout: 5)
        await store.refresh()
        let before = await http.profiles; XCTAssertEqual(before, 1)
        await http.profileGate.release()
        try await waitForTestEvent("Replacement sync completed") { await store.state.lastSync != nil }
        let profiles = await http.profiles, cancelled = await http.cancelledProfiles
        XCTAssertEqual(profiles, 2); XCTAssertEqual(cancelled, 1)
        await store.suspendConnectionWork()
    }
    func testLockClearsRemindersAndEditsCannotRescheduleUntilUnlock() async throws {
        let (store, _, _, _, reminders) = await fixture()
        store.state.settings.notifications = true
        _ = await store.addTask(title: "Sensitive commitment", dueAt: Date().addingTimeInterval(600))
        try await waitForTestEvent("Reminder scheduled") { await reminders.enabled }
        await store.lockWorkspace()
        XCTAssertFalse(reminders.enabled); XCTAssertTrue(reminders.pendingTitles.isEmpty)
        store.scheduleReminders(); await Task.yield()
        XCTAssertFalse(reminders.enabled)
        store.unlockWorkspace()
        try await waitForTestEvent("Reminder restored after unlock") { await reminders.enabled }
        await store.suspendConnectionWork()
    }
    func testUnreadyGoogleAndWorkListenersTimeOutWithoutOpeningBrowser() async throws {
        let google = LoopbackSignIn(), work = WorkOAuthCallback()
        do { _ = try await google.start(readinessTimeout: .milliseconds(20), startListener: { _ in }); XCTFail("Google listener hung") }
        catch { XCTAssertTrue(error.localizedDescription.contains("did not become ready")) }
        do { _ = try await work.start(readinessTimeout: .milliseconds(20), startListener: { _ in }); XCTFail("Work listener hung") }
        catch { XCTAssertTrue(error.localizedDescription.contains("did not become ready")) }
        google.cancel(); work.close()
    }
    func testChatProposalGroundingRejectsUnsupportedAndExternalCompletionClaims() async throws {
        for external in [false, true] {
            let (store, _, _, http, _) = await fixture()
            await http.draft("I approved the invoice. Please find attached.")
            if external { _ = await store.askReference(question: "Draft a reply", reference: "I approved the invoice. I attached the invoice.") }
            else { _ = await store.ask("Draft a reply asking for an update.") }
            await store.aiTask?.value
            XCTAssertTrue(store.state.actionProposals.isEmpty)
            XCTAssertTrue(store.state.chat.flatMap { $0.receipts ?? [] }.contains { $0.status == "failed" })
            await store.suspendConnectionWork()
        }
        let (store, _, _, http, _) = await fixture()
        await http.draft("I approved the invoice.")
        _ = await store.ask("I approved the invoice. Draft a reply with that update.")
        await store.aiTask?.value
        XCTAssertEqual(store.state.actionProposals.count, 1)
        await store.suspendConnectionWork()
    }
}
