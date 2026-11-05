import Foundation
import XCTest
import PuddleCore
@testable import Puddle

@MainActor private final class FixtureMeetingCapture: MeetingAudioCapturing {
    var isSupported = true
    var sourceDescription: String?
    var starts = 0, installs = 0, finishes = 0, cancellations = 0
    var holdStart = false, holdFinish = false, holdInstall = false
    var cancelStart = false, cancelFinish = false
    var startGate: CheckedContinuation<Void, Never>?, finishGate: CheckedContinuation<Void, Never>?, installGate: CheckedContinuation<Void, Never>?
    var segments: [@MainActor (MeetingTranscriptSegment) -> Void] = []
    var failures: [@MainActor (String) -> Void] = []
    func installLanguage(_ language: String) async throws {
        installs += 1
        if holdInstall { await withCheckedContinuation { installGate = $0 } }
    }
    func start(language: String, source: MeetingAudioSource, onSegment: @escaping @MainActor @Sendable (MeetingTranscriptSegment) -> Void,
               onStatus: @escaping @MainActor @Sendable (String) -> Void, onError: @escaping @MainActor @Sendable (String) -> Void) async throws {
        starts += 1; segments.append(onSegment); failures.append(onError)
        if cancelStart { throw CancellationError() }
        if holdStart { await withCheckedContinuation { startGate = $0 } }
    }
    func finish() async throws {
        finishes += 1; if cancelFinish { throw CancellationError() }
        if holdFinish { await withCheckedContinuation { finishGate = $0 } }
    }
    func cancel() { cancellations += 1 }
}

private final class CaptureDisk: SnapshotPersistence, @unchecked Sendable {
    var state = AppSnapshot()
    func load() throws -> AppSnapshot { state }
    func save(_ state: AppSnapshot) throws { self.state = state }
}

@MainActor final class MeetingCaptureTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async {
        for _ in 0..<200 { if condition() { return }; try? await Task.sleep(for: .milliseconds(2)) }
        XCTFail("Meeting capture fixture did not reach expected state")
    }
    func testAppAudioRequiresOneIdentifiedApplicationAndNamesMicrophoneSeparately() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("App audio requires macOS 26") }
        XCTAssertThrowsError(try AnalyzerMeetingAudioCapture.selectedApplicationDescription([], includingMicrophone: false))
        XCTAssertThrowsError(try AnalyzerMeetingAudioCapture.selectedApplicationDescription(["Audio A", "Audio B"], includingMicrophone: false))
        XCTAssertThrowsError(try AnalyzerMeetingAudioCapture.selectedApplicationDescription(["  "], includingMicrophone: false))
        XCTAssertEqual(try AnalyzerMeetingAudioCapture.selectedApplicationDescription(["Audio A"], includingMicrophone: false), "Audio A")
        XCTAssertEqual(try AnalyzerMeetingAudioCapture.selectedApplicationDescription(["Audio A"], includingMicrophone: true), "Audio A + microphone")
    }
    func testDisplayedSourceMatchesActiveCaptureAndCannotLeakFromAnEarlierSession() async {
        let hardware = FixtureMeetingCapture(); hardware.sourceDescription = "Audio A"
        let controller = MeetingCaptureController(capture: hardware)
        controller.start(noteID: UUID(), language: "en-US", source: .meetingAudio)
        await wait { controller.status == .listening }
        XCTAssertEqual(controller.sourceDescription, "Audio A")
        controller.stop(); await wait { controller.status == .idle }
        XCTAssertNil(controller.sourceDescription)
        hardware.holdStart = true; hardware.sourceDescription = "Audio B"
        controller.start(noteID: UUID(), language: "en-US", source: .meetingAudio)
        await wait { hardware.startGate != nil }
        XCTAssertNil(controller.sourceDescription)
        controller.cancel(); hardware.startGate?.resume(); hardware.startGate = nil
        await Task.yield(); await Task.yield()
        XCTAssertEqual(controller.status, .idle); XCTAssertNil(controller.sourceDescription)
    }
    func testImmediateCancellationDoesNotRequestCaptureOrLanguageInstallation() async {
        let hardware = FixtureMeetingCapture()
        let subject = MeetingCaptureController(capture: hardware)
        subject.start(noteID: UUID(), language: "en-US", source: .microphone); subject.cancel()
        subject.installLanguage("en-US"); subject.cancel()
        await Task.yield(); await Task.yield()
        XCTAssertEqual(hardware.starts, 0); XCTAssertEqual(hardware.installs, 0)
    }
    func testStopKeepsFinalAndProvisionalPassagesForExplicitReview() async {
        let hardware = FixtureMeetingCapture()
        let controller = MeetingCaptureController(capture: hardware)
        var completed: (UUID, String)?; controller.onCompletion = { completed = ($0, $1) }
        let id = UUID(); controller.start(noteID: id, language: "en-US", source: .microphone)
        await wait { controller.status == .listening }
        hardware.segments[0](.init(channel: .microphone, start: 0, end: 2, text: "A useful passage", isFinal: false))
        XCTAssertNil(completed)
        controller.stop(); await wait { controller.status == .idle }
        XCTAssertEqual(completed?.0, id); XCTAssertTrue(completed?.1.contains("provisional") == true)
        XCTAssertEqual(hardware.finishes, 1)
    }
    func testCancellingPendingPermissionIgnoresLateStartAndCallbacks() async {
        let hardware = FixtureMeetingCapture(); hardware.holdStart = true
        let controller = MeetingCaptureController(capture: hardware)
        controller.start(noteID: UUID(), language: "en-US", source: .microphone)
        await wait { hardware.startGate != nil }
        let starting = controller.work; controller.stop()
        hardware.startGate?.resume(); hardware.startGate = nil
        hardware.segments[0](.init(channel: .microphone, start: 0, end: 1, text: "Stale", isFinal: true))
        await starting?.value
        XCTAssertEqual(controller.status, .idle); XCTAssertTrue(controller.timeline.segments.isEmpty)
    }
    func testFinishTimeoutRetainsTextAndLateFinalCannotOverwriteNextSession() async {
        let hardware = FixtureMeetingCapture(); hardware.holdFinish = true
        let timeout = AsyncTestGate()
        let controller = MeetingCaptureController(capture: hardware, sleep: { interval in
            if interval == .seconds(15) { await timeout.pause(); try Task.checkCancellation() }
            else { try await Task.sleep(for: interval) }
        })
        var text = ""; controller.onCompletion = { _, value in text = value }
        controller.start(noteID: UUID(), language: "en-US", source: .microphone); await wait { controller.status == .listening }
        hardware.segments[0](.init(channel: .microphone, start: 1, end: 2, text: "Retain me", isFinal: false))
        controller.stop(); let finalizing = controller.work
        await wait { hardware.finishGate != nil }
        await fulfillment(of: [timeout.entered], timeout: 5)
        await timeout.release(); await wait { controller.status == .idle }
        XCTAssertTrue(text.contains("Retain me")); XCTAssertTrue(controller.errorMessage?.contains("timed out") == true)
        controller.start(noteID: UUID(), language: "en-US", source: .microphone); await wait { hardware.starts == 2 && controller.status == .listening }
        hardware.finishGate?.resume(); hardware.finishGate = nil
        hardware.segments[0](.init(channel: .microphone, start: 1, end: 2, text: "Late text", isFinal: true))
        await finalizing?.value; XCTAssertTrue(controller.timeline.segments.isEmpty); controller.cancel()
    }
    func testCaptureFailureAndDurationLimitRetainCollectedText() async {
        let hardware = FixtureMeetingCapture()
        let duration = AsyncTestGate()
        let controller = MeetingCaptureController(capture: hardware, sleep: { interval in
            if interval == .seconds(7200) { await duration.pause(); try Task.checkCancellation() }
            else { try await Task.sleep(for: interval) }
        })
        var text = ""; controller.onCompletion = { _, value in text = value }
        controller.start(noteID: UUID(), language: "en-US", source: .microphone); await wait { controller.status == .listening }
        await fulfillment(of: [duration.entered], timeout: 5)
        hardware.segments[0](.init(channel: .microphone, start: 0, end: 1, text: "Keep this", isFinal: true))
        await duration.release()
        await wait { controller.status == .idle }; XCTAssertTrue(text.contains("Keep this"))
        let failing = MeetingCaptureController(capture: hardware)
        failing.onCompletion = { _, value in text = value }
        failing.start(noteID: UUID(), language: "en-US", source: .microphone); await wait { failing.status == .listening }
        hardware.segments[1](.init(channel: .microphone, start: 0, end: 1, text: "Also keep this", isFinal: true))
        hardware.failures[1]("Device removed"); await wait { failing.status == .idle }
        XCTAssertTrue(text.contains("Also keep this")); XCTAssertTrue(failing.errorMessage?.contains("Device removed") == true)
    }
    func testDemoCannotStartMeetingCaptureOrInstallLanguages() async {
        let hardware = FixtureMeetingCapture()
        let store = PuddleStore(meetingAudioCapture: hardware); await store.enterDemo()
        let id = await store.createMeetingNote()!
        store.startMeetingTranscription(id, source: .microphone); store.installMeetingSpeechLanguage()
        await Task.yield(); XCTAssertEqual(hardware.starts, 0); XCTAssertEqual(hardware.installs, 0)
    }
    func testSpeechLanguageInstallationHonorsPausePrivateSessionAndLock() async {
        let hardware = FixtureMeetingCapture()
        let store = PuddleStore(cache: CaptureDisk(), meetingAudioCapture: hardware); store.storageAvailable = true
        await store.setExternalConnectionsPaused(true)
        XCTAssertFalse(store.canInstallMeetingSpeechLanguage); store.installMeetingSpeechLanguage()
        await store.setExternalConnectionsPaused(false); await store.beginPrivateSession()
        XCTAssertFalse(store.canInstallMeetingSpeechLanguage); store.installMeetingSpeechLanguage()
        await store.endPrivateSession(); await store.lockWorkspace()
        XCTAssertFalse(store.canInstallMeetingSpeechLanguage); store.installMeetingSpeechLanguage()
        await Task.yield(); XCTAssertEqual(hardware.installs, 0)
        store.unlockWorkspace()
        XCTAssertTrue(store.canInstallMeetingSpeechLanguage); store.installMeetingSpeechLanguage()
        await wait { hardware.installs == 1 && store.meetingCapture.status == .idle }
        await store.suspendConnectionWork()
    }
    func testPauseCancelsLanguageDownloadAndIgnoresLateCompletionWithoutStoppingLocalCapture() async throws {
        let hardware = FixtureMeetingCapture(); hardware.holdInstall = true
        let store = PuddleStore(cache: CaptureDisk(), meetingAudioCapture: hardware); store.storageAvailable = true
        store.installMeetingSpeechLanguage(); await wait { hardware.installGate != nil }
        let cancellations = hardware.cancellations
        await store.setExternalConnectionsPaused(true)
        XCTAssertEqual(store.meetingCapture.status, .idle); XCTAssertGreaterThan(hardware.cancellations, cancellations)
        hardware.installGate?.resume(); hardware.installGate = nil
        await Task.yield(); await Task.yield()
        XCTAssertEqual(store.meetingCapture.status, .idle); XCTAssertFalse(store.meetingCapture.message.contains("ready"))
        let result1 = await store.createMeetingNote()
        let id = try XCTUnwrap(result1)
        store.startMeetingTranscription(id, source: .microphone); await wait { store.meetingCapture.status == .listening }
        await store.setExternalConnectionsPaused(true)
        XCTAssertEqual(store.meetingCapture.status, .listening)
        store.meetingCapture.cancel(); await store.suspendConnectionWork()
    }
    func testCancelledSystemPickerAndCancelledFinalizationNeverLeaveControlsStuck() async {
        let hardware = FixtureMeetingCapture(); hardware.cancelStart = true
        let controller = MeetingCaptureController(capture: hardware)
        controller.start(noteID: UUID(), language: "en-US", source: .meetingAudio)
        await wait { controller.status == .idle }
        XCTAssertEqual(hardware.starts, 1); XCTAssertTrue(controller.errorMessage?.contains("cancelled") == true)
        hardware.cancelStart = false; hardware.cancelFinish = true
        var captured = ""; controller.onCompletion = { _, text in captured = text }
        controller.start(noteID: UUID(), language: "en-US", source: .both); await wait { controller.status == .listening }
        hardware.segments[1](.init(channel: .meetingAudio, start: 0, end: 1, text: "Retained after cancellation", isFinal: false))
        controller.stop(); await wait { controller.status == .idle }
        XCTAssertTrue(captured.contains("Retained after cancellation"))
        XCTAssertTrue(controller.errorMessage?.contains("Finalization was cancelled") == true)
    }
    func testCheckpointSurvivesRestartUntilReviewedAndSavedAndDeletionRemovesIt() async throws {
        let disk = CaptureDisk(), store = PuddleStore(cache: disk)
        store.storageAvailable = true
        let result2 = await store.createMeetingNote()
        let id = try XCTUnwrap(result2)
        await store.checkpointMeetingCapture(id, text: "[00:02] Microphone\nRecovered words")
        XCTAssertEqual(disk.state.meetingCaptureRecoveries.count, 1)
        let restarted = PuddleStore(cache: disk); restarted.state = try disk.load(); restarted.storageAvailable = true
        restarted.reviewMeetingCapture(id)
        XCTAssertEqual(restarted.meetingWorkspace.pendingImport?.result.text, "[00:02] Microphone\nRecovered words")
        XCTAssertTrue(restarted.useImportedTranscript(append: true)); let result3 = await restarted.saveMeetingNote(id)
        XCTAssertTrue(result3)
        XCTAssertTrue(disk.state.meetingCaptureRecoveries.isEmpty)
        await restarted.checkpointMeetingCapture(id, text: "Another checkpoint")
        await restarted.deleteMeetingNote(id); XCTAssertTrue(disk.state.meetingCaptureRecoveries.isEmpty)
    }
    func testStoreRequiresExplicitApplyAndSaveAndPreservesExistingTranscript() async throws {
        let hardware = FixtureMeetingCapture()
        let disk = CaptureDisk()
        let store = PuddleStore(cache: disk, meetingAudioCapture: hardware); store.storageAvailable = true
        let result4 = await store.createMeetingNote()
        let id = try XCTUnwrap(result4), note = try XCTUnwrap(store.state.meetings.first)
        store.meetingWorkspace.edit(note) { $0.transcript = "Previously saved text" }; let result5 = await store.saveMeetingNote(id)
        XCTAssertTrue(result5)
        store.startMeetingTranscription(id, source: .microphone); await wait { store.meetingCapture.status == .listening }
        hardware.segments[0](.init(channel: .microphone, start: 0, end: 1, text: "Captured words", isFinal: true))
        store.meetingCapture.stop(); await wait { store.meetingWorkspace.pendingImport != nil }
        XCTAssertEqual(disk.state.meetings[0].transcript, "Previously saved text")
        store.meetingWorkspace.cancelImport(preservePreview: true)
        XCTAssertNotNil(store.meetingWorkspace.pendingImport)
        XCTAssertTrue(store.useImportedTranscript(append: true))
        XCTAssertTrue(store.meetingWorkspace.draft(for: store.state.meetings[0]).transcript.contains("Captured words"))
        XCTAssertFalse(disk.state.meetings[0].transcript.contains("Captured words"))
        let result6 = await store.saveMeetingNote(id)
        XCTAssertTrue(result6); XCTAssertTrue(disk.state.meetings[0].transcript.contains("Captured words"))
        XCTAssertTrue(store.state.memories.isEmpty); XCTAssertTrue(store.state.tasks.isEmpty)
    }
    func testDeletingActiveNoteCancelsCaptureAndCannotResurrectIt() async throws {
        let hardware = FixtureMeetingCapture()
        let store = PuddleStore(cache: CaptureDisk(), meetingAudioCapture: hardware); store.storageAvailable = true
        let result7 = await store.createMeetingNote()
        let id = try XCTUnwrap(result7)
        store.startMeetingTranscription(id, source: .microphone); await wait { store.meetingCapture.status == .listening }
        await store.deleteMeetingNote(id)
        hardware.segments[0](.init(channel: .microphone, start: 0, end: 1, text: "Late result", isFinal: true))
        XCTAssertTrue(store.state.meetings.isEmpty); XCTAssertNil(store.meetingWorkspace.pendingImport)
        XCTAssertEqual(store.meetingCapture.status, .idle)
    }
    func testCheckpointTimerIncludesQuietProvisionalTextAndCompletionFlushesImmediately() async throws {
        let hardware = FixtureMeetingCapture(), tick = AsyncTestGate(), nextTick = AsyncTestGate()
        let clock = CheckpointClock(first: tick, next: nextTick)
        let controller = MeetingCaptureController(capture: hardware, sleep: { interval in
            if interval == MeetingCaptureController.checkpointInterval { await clock.wait(); try Task.checkCancellation() }
            else { try await Task.sleep(for: interval) }
        })
        var checkpoints: [String] = [], completion = ""
        controller.onCheckpoint = { _, text in checkpoints.append(text) }
        controller.onCompletion = { _, text in completion = text }
        controller.start(noteID: UUID(), language: "en-US", source: .microphone)
        await wait { controller.status == .listening }
        await fulfillment(of: [tick.entered], timeout: 5)
        for index in 0..<100 {
            hardware.segments[0](.init(channel: .microphone, start: Double(index), end: Double(index + 1), text: "Final passage \(index)", isFinal: true))
        }
        hardware.segments[0](.init(channel: .microphone, start: 101, end: 102, text: "Quiet provisional text", isFinal: false))
        XCTAssertTrue(checkpoints.isEmpty, "Segment callbacks must not trigger full-file writes")
        await tick.release()
        await fulfillment(of: [nextTick.entered], timeout: 5)
        XCTAssertEqual(checkpoints.count, 1)
        XCTAssertTrue(checkpoints[0].contains("Quiet provisional text"))
        hardware.segments[0](.init(channel: .microphone, start: 103, end: 104, text: "Flush on stop", isFinal: true))
        controller.stop(); await wait { controller.status == .idle }
        XCTAssertTrue(completion.contains("Flush on stop"))
        await nextTick.release()
    }
}

private actor CheckpointClock {
    let first: AsyncTestGate, next: AsyncTestGate
    private var waits = 0
    init(first: AsyncTestGate, next: AsyncTestGate) { self.first = first; self.next = next }
    func wait() async { waits += 1; await (waits == 1 ? first : next).pause() }
}
