import Foundation
import XCTest
@testable import Puddle
@testable import PuddleCore

private final class ActionSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock(); private var data: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { lock.withLock { data[key] } }
    func write(_ value: Data, key: String) throws { lock.withLock { data[key] = value } }
    func delete(_ key: String) throws { _ = lock.withLock { data.removeValue(forKey: key) } }
}
private final class ActionDisk: SnapshotPersistence, @unchecked Sendable {
    var snapshot = AppSnapshot(); var failWrites = false
    func load() throws -> AppSnapshot { snapshot }
    func save(_ next: AppSnapshot) throws { if failWrites { throw PuddleError("Fixture full disk") }; snapshot = next }
}
private actor ActionHTTP: HTTPTransport {
    var writes: [URLRequest] = []; var loseResponse = false
    func configureLoss() { loseResponse = true }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: String
        if request.httpMethod == "POST" {
            writes.append(request)
            if loseResponse { throw URLError(.networkConnectionLost) }
            body = #"{"id":"sent-fixture","threadId":"thread-fixture"}"#
        } else if request.url?.path == "/v1/models" { body = #"{"data":[{"id":"fixture"}]}"# }
        else { body = "{}" }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor final class ActionWorkflowTests: XCTestCase {
    private final class Scheduler: ReminderScheduling {
        func reconcile(tasks: [AssistantTask], enabled: Bool) async throws {}
    }
    private func fixture(scope: String = OAuthFlow.mailSendScope) throws -> (PuddleStore, ActionDisk, ActionHTTP) {
        let disk = ActionDisk(), secrets = ActionSecrets(), http = ActionHTTP()
        let credentials = GoogleCredentials(accessToken: "fixture", refreshToken: "fixture", expiresAt: Date().addingTimeInterval(3600), scope: scope,
            account: GoogleAccount(id: "fixture", email: "me@example.com", name: nil))
        try secrets.write(JSONEncoder().encode(credentials), key: "google-tokens")
        return (PuddleStore(cache: disk, secrets: secrets, transport: http, reminderScheduler: Scheduler()), disk, http)
    }
    private func action() -> ActionProposal {
        var draft = MailDraft(to: "you@example.com", subject: "Review", body: "Ready for review")
        draft.followUpAt = Date().addingTimeInterval(3600)
        return ActionProposal(account: "me@example.com", payload: .email(draft))
    }
    func testDraftDoesNotSendAndApprovedSendCreatesOneReceiptAndFollowup() async throws {
        let (store, disk, http) = try fixture(); await store.start()
        let proposal = action(); XCTAssertTrue(store.saveAction(proposal))
        var writes = await http.writes; XCTAssertTrue(writes.isEmpty)
        await store.executeAction(proposal.id, reviewedDigest: proposal.digest)
        XCTAssertEqual(disk.snapshot.actionProposals[0].status, .completed)
        XCTAssertEqual(disk.snapshot.tasks.count, 1)
        await store.executeAction(proposal.id, reviewedDigest: proposal.digest)
        writes = await http.writes; XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(disk.snapshot.tasks.count, 1)
    }
    func testChangedContentsOrFailedSaveCannotDispatch() async throws {
        let (store, disk, http) = try fixture(); await store.start()
        var proposal = action(); XCTAssertTrue(store.saveAction(proposal)); let digest = proposal.digest
        proposal.account = "other@example.com"; XCTAssertTrue(store.saveAction(proposal))
        await store.executeAction(proposal.id, reviewedDigest: digest)
        proposal.account = "me@example.com"; XCTAssertTrue(store.saveAction(proposal)); disk.failWrites = true
        await store.executeAction(proposal.id, reviewedDigest: proposal.digest)
        let writes = await http.writes; XCTAssertTrue(writes.isEmpty)
    }
    func testLostResponseIsUncertainAndNeverReplayed() async throws {
        let (store, disk, http) = try fixture(); await store.start(); await http.configureLoss()
        let proposal = action(); XCTAssertTrue(store.saveAction(proposal))
        await store.executeAction(proposal.id, reviewedDigest: proposal.digest)
        XCTAssertEqual(disk.snapshot.actionProposals[0].status, .uncertain)
        await store.executeAction(proposal.id, reviewedDigest: proposal.digest)
        let writes = await http.writes; XCTAssertEqual(writes.count, 1)
        XCTAssertTrue(disk.snapshot.tasks.isEmpty)
    }
    func testCalendarUndoIsLinkedAndCannotBeProposedAgainWhileSaved() async throws {
        let (store, _, _) = try fixture(); await store.start()
        var draft = CalendarDraft(); draft.title = "UI test event"
        var action = ActionProposal(account: "me@example.com", payload: .calendar(draft))
        action.status = .completed; action.resultID = "event-id"; action.resultETag = "etag"
        try store.commit { $0.actionProposals = [action] }
        XCTAssertTrue(store.canUndoCalendarAction(action)); store.proposeCalendarUndo(action)
        let undo = try XCTUnwrap(store.editingAction); XCTAssertEqual(undo.undoOf, action.id)
        XCTAssertTrue(store.saveAction(undo)); XCTAssertFalse(store.canUndoCalendarAction(action))
        store.discardAction(undo.id); XCTAssertTrue(store.canUndoCalendarAction(action))
    }
    func testReadPermissionCannotSend() async throws {
        let (store, _, http) = try fixture(scope: OAuthFlow.scope); await store.start()
        let proposal = action(); XCTAssertTrue(store.saveAction(proposal))
        await store.executeAction(proposal.id, reviewedDigest: proposal.digest)
        let writes = await http.writes; XCTAssertTrue(writes.isEmpty)
    }
}
