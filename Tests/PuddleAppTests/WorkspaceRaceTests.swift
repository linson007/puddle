import AppKit
import Foundation
import XCTest
import PuddleCore
@testable import Puddle

// Sendable invariant: condition protects fixture state and all test-side reads.
private final class RaceDisk: SnapshotPersistence, @unchecked Sendable {
    private let condition = NSCondition()
    private var snapshot = AppSnapshot()
    private var recoveries: [MeetingCaptureRecovery] = []
    private var holdingLoad = false, holdingWrite = false, failingWrite = false
    private var loadEntry: XCTestExpectation?, writeEntry: XCTestExpectation?
    private var loads = 0
    func blockLoad(_ entered: XCTestExpectation) { condition.withLock { holdingLoad = true; loadEntry = entered } }
    func blockWrite(_ entered: XCTestExpectation) { condition.withLock { holdingWrite = true; writeEntry = entered } }
    func release() { condition.withLock { holdingLoad = false; holdingWrite = false; condition.broadcast() } }
    func failWrites(_ value: Bool) { condition.withLock { failingWrite = value } }
    var loadCount: Int { condition.withLock { loads } }
    func load() -> AppSnapshot {
        condition.lock(); defer { condition.unlock() }
        loads += 1; loadEntry?.fulfill(); loadEntry = nil
        while holdingLoad { condition.wait() }
        return snapshot
    }
    func save(_ snapshot: AppSnapshot) throws {
        condition.lock(); defer { condition.unlock() }
        writeEntry?.fulfill(); writeEntry = nil
        while holdingWrite { condition.wait() }
        if failingWrite { throw PuddleError("Injected disk full") }
        self.snapshot = snapshot
    }
    func loadMeetingRecoveries() -> [MeetingCaptureRecovery] { condition.withLock { recoveries } }
    func saveMeetingRecoveries(_ values: [MeetingCaptureRecovery]) throws {
        try condition.withLock { if failingWrite { throw PuddleError("Injected recovery disk full") }; recoveries = values }
    }
}
private struct RaceSecrets: SecretStore {
    func read(_ key: String) -> Data? { nil }
    func write(_ data: Data, key: String) {}
    func delete(_ key: String) {}
}
private struct RaceHTTP: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.cancelled) }
}
@MainActor private final class RaceReminders: ReminderScheduling {
    func reconcile(tasks: [AssistantTask], enabled: Bool) async throws {}
}
@MainActor private final class RaceCapture: MeetingAudioCapturing {
    var isSupported = true
    var starts = 0, finishes = 0, cancellations = 0
    var finishGate: AsyncTestGate?
    var finalText: String?
    var finishError: Error?
    private var segment: (@MainActor (MeetingTranscriptSegment) -> Void)?
    func installLanguage(_ language: String) async throws {}
    func start(language: String, source: MeetingAudioSource, onSegment: @escaping @MainActor @Sendable (MeetingTranscriptSegment) -> Void,
               onStatus: @escaping @MainActor @Sendable (String) -> Void, onError: @escaping @MainActor @Sendable (String) -> Void) async throws {
        starts += 1; segment = onSegment
    }
    func emit(_ text: String, final: Bool = false) { segment?(.init(channel: .microphone, start: 0, end: 2, text: text, isFinal: final)) }
    func finish() async throws {
        finishes += 1
        await finishGate?.pause()
        if let finishError { throw finishError }
        if let finalText { emit(finalText, final: true) }
    }
    func cancel() { cancellations += 1 }
}

@MainActor final class WorkspaceRaceTests: XCTestCase {
    private func store(_ disk: RaceDisk, capture: RaceCapture = RaceCapture()) -> PuddleStore {
        PuddleStore(cache: disk, secrets: RaceSecrets(), transport: RaceHTTP(), reminderScheduler: RaceReminders(), meetingAudioCapture: capture)
    }
    func testConcurrentRetriesShareOneCompleteStartup() async throws {
        let disk = RaceDisk(), entered = expectation(description: "Loading entered"), subject = store(disk)
        disk.blockLoad(entered)
        let first = Task { await subject.retryLoadingState() }
        await fulfillment(of: [entered], timeout: 5)
        let second = Task { await subject.retryLoadingState() }, third = Task { await subject.start() }
        await Task.yield()
        XCTAssertTrue(subject.isLoadingState)
        XCTAssertEqual(disk.loadCount, 1)
        disk.release()
        await first.value; await second.value; await third.value
        XCTAssertFalse(subject.isLoadingState)
        XCTAssertEqual(disk.loadCount, 1)
        await subject.suspendConnectionWork()
    }
    func testFailedReceiptSurvivesRollbackAndIsRetriedInArchivedConversation() async throws {
        let disk = RaceDisk(), subject = store(disk), line = ChatLine(role: "user", content: "Synthetic browser action")
        subject.storageAvailable = true
        try await subject.commit { $0.chat = [line] }
        disk.failWrites(true)
        let receipt = ToolReceipt(id: "action", tool: AgentTool.browserNavigate.rawValue, detail: "Action result uncertain", status: "unverified")
        await subject.saveToolFailureReceipt(receipt, userID: line.id)
        XCTAssertTrue(subject.state.chat[0].receipts?.contains(receipt) == true)
        XCTAssertNotNil(subject.persistenceFailure)
        XCTAssertTrue(subject.errorMessage?.contains("retained in memory") == true)
        do { try await subject.commit { $0.assistantInstructions = "Fail again" }; XCTFail("Disk failure must throw") } catch {}
        XCTAssertTrue(subject.state.chat[0].receipts?.contains(receipt) == true)
        subject.state.startNewConversation()
        disk.failWrites(false)
        try await subject.commit { $0.assistantInstructions = "Retry durable save" }
        XCTAssertTrue(disk.load().conversations.flatMap(\.lines).first?.receipts?.contains(receipt) == true)
        XCTAssertNil(subject.persistenceFailure)
    }
    func testURLSessionCancellationInterruptsRoutineAndDoesNotShowOutlookFailure() async throws {
        let disk = RaceDisk(), subject = store(disk)
        subject.storageAvailable = true
        let run = RoutineRun(routineID: UUID(), scheduledAt: Date(), status: .running)
        try await subject.commit { $0.routineRuns = [run] }
        await subject.recordRoutineFailure(run.id, error: URLError(.cancelled))
        XCTAssertEqual(subject.state.routineRuns.first?.status, .interrupted)
        XCTAssertEqual(disk.load().routineRuns.first?.status, .interrupted)
        subject.errorMessage = nil
        subject.reportOutlookError(URLError(.cancelled))
        XCTAssertNil(subject.errorMessage)
        subject.reportOutlookError(PuddleError("Real Outlook failure"))
        XCTAssertEqual(subject.errorMessage, "Real Outlook failure")
    }
    func testSharedTranscriptionEligibilityBlocksPrivateLockImportMissingStorageAndRecovery() async throws {
        let hardware = RaceCapture(), subject = store(RaceDisk(), capture: hardware), note = MeetingNote(title: "Synthetic")
        subject.state.meetings = [note]
        XCTAssertFalse(subject.canStartMeetingTranscription(note.id))
        subject.storageAvailable = true
        XCTAssertTrue(subject.canStartMeetingTranscription(note.id))
        await subject.beginPrivateSession()
        XCTAssertFalse(subject.canStartMeetingTranscription(note.id))
        subject.startMeetingTranscription(note.id, source: .microphone)
        XCTAssertTrue(subject.errorMessage?.contains("private session") == true)
        await subject.endPrivateSession(); await subject.lockWorkspace()
        XCTAssertFalse(subject.canStartMeetingTranscription(note.id))
        subject.startMeetingTranscription(note.id, source: .microphone)
        XCTAssertTrue(subject.errorMessage?.contains("Unlock") == true)
        subject.unlockWorkspace()
        subject.meetingWorkspace.pendingImport = .init(noteID: note.id, result: .init(text: "Pending", sourceName: "Fixture"))
        XCTAssertFalse(subject.canStartMeetingTranscription(note.id))
        XCTAssertTrue(subject.meetingTranscriptionBlockedReason(note.id)?.contains("importing") == true)
        subject.meetingWorkspace.pendingImport = nil
        subject.state.meetingCaptureRecoveries = [.init(noteID: note.id, text: "Review recovery")]
        XCTAssertFalse(subject.canStartMeetingTranscription(note.id))
        XCTAssertFalse(subject.canStartMeetingTranscription(UUID()))
        XCTAssertEqual(hardware.starts, 0)
        await subject.suspendConnectionWork()
    }
    func testLockStopsAudioBeforeSuspendingForRoutinePersistence() async throws {
        let disk = RaceDisk(), hardware = RaceCapture(), subject = store(disk, capture: hardware)
        subject.storageAvailable = true
        let created = await subject.createMeetingNote()
        let id = try XCTUnwrap(created)
        subject.startMeetingTranscription(id, source: .microphone)
        try await waitForTestEvent("Capture listening") { await subject.meetingCapture.status == .listening }
        hardware.emit("Retain before locking")
        subject.state.routineRuns = [.init(routineID: UUID(), scheduledAt: Date(), status: .running)]
        let entered = expectation(description: "Routine cleanup blocked")
        disk.blockWrite(entered)
        let lock = Task { await subject.lockWorkspace() }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(subject.isLocked)
        XCTAssertFalse(subject.meetingCapture.isActive)
        XCTAssertGreaterThan(hardware.cancellations, 0)
        hardware.emit("Late private speech")
        XCTAssertFalse(subject.meetingCapture.timeline.text.contains("Late private speech"))
        disk.release(); await lock.value
    }
    func testQuitWaitsForFinalRecognitionAndDurableCheckpoint() async throws {
        let disk = RaceDisk(), hardware = RaceCapture(), subject = store(disk, capture: hardware)
        subject.storageAvailable = true
        let created = await subject.createMeetingNote()
        let id = try XCTUnwrap(created)
        let gate = AsyncTestGate(); hardware.finishGate = gate; hardware.finalText = "Final recognized words"
        subject.startMeetingTranscription(id, source: .microphone)
        try await waitForTestEvent("Capture listening") { await subject.meetingCapture.status == .listening }
        hardware.emit("Provisional words")
        let lifecycle = PuddleLifecycle(); lifecycle.store = subject
        var reply: Bool?
        XCTAssertEqual(lifecycle.requestTermination { reply = $0 }, .terminateLater)
        await fulfillment(of: [gate.entered], timeout: 5)
        XCTAssertNil(reply)
        await gate.release(); await lifecycle.terminationTask?.value
        XCTAssertEqual(reply, true)
        XCTAssertTrue(disk.loadMeetingRecoveries().first?.text.contains("Final recognized words") == true)
    }
    func testQuitDeadlineCanKeepOpenAndRepliesOnlyOnceAfterLateSave() async throws {
        let disk = RaceDisk(), subject = store(disk); subject.storageAvailable = true
        let entered = expectation(description: "Save held during quit"); disk.blockWrite(entered)
        let save = Task { await subject.addTask(title: "Save before quit", dueAt: nil) }
        await fulfillment(of: [entered], timeout: 5)
        let lifecycle = PuddleLifecycle(); lifecycle.store = subject; lifecycle.terminationTimeout = .milliseconds(50)
        lifecycle.confirmQuit = { _, _ in false }
        let answered = expectation(description: "Quit deadline answered"), firstTask: Task<Void, Never>?
        var replies = 0
        XCTAssertEqual(lifecycle.requestTermination { allow in XCTAssertFalse(allow); replies += 1; answered.fulfill() }, .terminateLater)
        firstTask = lifecycle.terminationTask
        XCTAssertEqual(lifecycle.requestTermination { _ in XCTFail("Duplicate quit replied") }, .terminateLater)
        await fulfillment(of: [answered], timeout: 5)
        XCTAssertFalse(subject.isShuttingDown)
        disk.release(); _ = await save.value; await firstTask?.value
        XCTAssertEqual(replies, 1)
        await subject.suspendConnectionWork()
    }
    func testFailedFinalizationOffersKeepOpenAndRetainsText() async throws {
        let disk = RaceDisk(), hardware = RaceCapture(), subject = store(disk, capture: hardware)
        subject.storageAvailable = true
        let created = await subject.createMeetingNote()
        let id = try XCTUnwrap(created)
        hardware.finishError = PuddleError("Injected finalization failure")
        subject.startMeetingTranscription(id, source: .microphone)
        try await waitForTestEvent("Capture listening") { await subject.meetingCapture.status == .listening }
        hardware.emit("Retain provisional words")
        let lifecycle = PuddleLifecycle(); lifecycle.store = subject
        var prompted = false, reply: Bool?
        lifecycle.confirmQuit = { _, _ in prompted = true; return false }
        XCTAssertEqual(lifecycle.requestTermination { reply = $0 }, .terminateLater)
        await lifecycle.terminationTask?.value
        XCTAssertTrue(prompted); XCTAssertEqual(reply, false)
        XCTAssertTrue(disk.loadMeetingRecoveries().first?.text.contains("Retain provisional words") == true)
    }
    func testQuitWaitsForCompletionQueuedByAnAlreadyStoppedCapture() async throws {
        let disk = RaceDisk(), hardware = RaceCapture(), subject = store(disk, capture: hardware)
        subject.storageAvailable = true
        let created = await subject.createMeetingNote(), id = try XCTUnwrap(created)
        subject.startMeetingTranscription(id, source: .microphone)
        try await waitForTestEvent("Capture listening") { await subject.meetingCapture.status == .listening }
        hardware.emit("Just stopped words")
        subject.meetingCapture.stopImmediately()
        XCTAssertFalse(subject.meetingCapture.isActive)
        XCTAssertTrue(subject.isCompletingMeetingCapture)
        let lifecycle = PuddleLifecycle(); lifecycle.store = subject
        var reply: Bool?
        XCTAssertEqual(lifecycle.requestTermination { reply = $0 }, .terminateLater)
        await lifecycle.terminationTask?.value
        XCTAssertEqual(reply, true)
        XCTAssertTrue(disk.loadMeetingRecoveries().first?.text.contains("Just stopped words") == true)
    }
}
