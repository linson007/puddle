import Foundation
import XCTest
import PuddleCore
@testable import Puddle

@MainActor private final class FixtureMeetingCapture: MeetingAudioCapturing {
    var isSupported = true
    var starts = 0, installs = 0, finishes = 0, cancellations = 0
    var holdStart = false, holdFinish = false
    var cancelStart = false, cancelFinish = false
    var startGate: CheckedContinuation<Void, Never>?, finishGate: CheckedContinuation<Void, Never>?
    var segments: [@MainActor (MeetingTranscriptSegment) -> Void] = []
    var failures: [@MainActor (String) -> Void] = []
    func installLanguage(_ language: String) async throws { installs += 1 }
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
        await wait { hardware.startGate != nil }; controller.stop()
        hardware.startGate?.resume(); hardware.startGate = nil
        hardware.segments[0](.init(channel: .microphone, start: 0, end: 1, text: "Stale", isFinal: true))
        await Task.yield()
        XCTAssertEqual(controller.status, .idle); XCTAssertTrue(controller.timeline.segments.isEmpty)
    }
    func testFinishTimeoutRetainsTextAndLateFinalCannotOverwriteNextSession() async {
        let hardware = FixtureMeetingCapture(); hardware.holdFinish = true
        let controller = MeetingCaptureController(capture: hardware, finishTimeout: 0.02)
        var text = ""; controller.onCompletion = { _, value in text = value }
        controller.start(noteID: UUID(), language: "en-US", source: .microphone); await wait { controller.status == .listening }
        hardware.segments[0](.init(channel: .microphone, start: 1, end: 2, text: "Retain me", isFinal: false))
        controller.stop(); await wait { hardware.finishGate != nil }; await wait { controller.status == .idle }
        XCTAssertTrue(text.contains("Retain me")); XCTAssertTrue(controller.errorMessage?.contains("timed out") == true)
        controller.start(noteID: UUID(), language: "en-US", source: .microphone); await wait { hardware.starts == 2 && controller.status == .listening }
        hardware.finishGate?.resume(); hardware.finishGate = nil
        hardware.segments[0](.init(channel: .microphone, start: 1, end: 2, text: "Late text", isFinal: true))
        await Task.yield(); XCTAssertTrue(controller.timeline.segments.isEmpty); controller.cancel()
    }
    func testCaptureFailureAndDurationLimitRetainCollectedText() async {
        let hardware = FixtureMeetingCapture()
        let controller = MeetingCaptureController(capture: hardware, maximumSeconds: 0.02)
        var text = ""; controller.onCompletion = { _, value in text = value }
        controller.start(noteID: UUID(), language: "en-US", source: .microphone); await wait { controller.status == .listening }
        hardware.segments[0](.init(channel: .microphone, start: 0, end: 1, text: "Keep this", isFinal: true))
        await wait { controller.status == .idle }; XCTAssertTrue(text.contains("Keep this"))
        controller.start(noteID: UUID(), language: "en-US", source: .microphone); await wait { controller.status == .listening }
        hardware.segments[1](.init(channel: .microphone, start: 0, end: 1, text: "Also keep this", isFinal: true))
        hardware.failures[1]("Device removed"); await wait { controller.status == .idle }
        XCTAssertTrue(text.contains("Also keep this")); XCTAssertTrue(controller.errorMessage?.contains("Device removed") == true)
    }
    func testDemoCannotStartMeetingCaptureOrInstallLanguages() async {
        let hardware = FixtureMeetingCapture()
        let store = PuddleStore(meetingAudioCapture: hardware); store.enterDemo()
        let id = store.createMeetingNote()!
        store.startMeetingTranscription(id, source: .microphone); store.installMeetingSpeechLanguage()
        await Task.yield(); XCTAssertEqual(hardware.starts, 0); XCTAssertEqual(hardware.installs, 0)
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
    func testStoreRequiresExplicitApplyAndSaveAndPreservesExistingTranscript() async throws {
        let hardware = FixtureMeetingCapture()
        let disk = CaptureDisk()
        let store = PuddleStore(cache: disk, meetingAudioCapture: hardware); store.storageAvailable = true
        let id = try XCTUnwrap(store.createMeetingNote()), note = try XCTUnwrap(store.state.meetings.first)
        store.meetingWorkspace.edit(note) { $0.transcript = "Previously saved text" }; XCTAssertTrue(store.saveMeetingNote(id))
        store.startMeetingTranscription(id, source: .microphone); await wait { store.meetingCapture.status == .listening }
        hardware.segments[0](.init(channel: .microphone, start: 0, end: 1, text: "Captured words", isFinal: true))
        store.meetingCapture.stop(); await wait { store.meetingWorkspace.pendingImport != nil }
        XCTAssertEqual(disk.state.meetings[0].transcript, "Previously saved text")
        store.meetingWorkspace.cancelImport(preservePreview: true)
        XCTAssertNotNil(store.meetingWorkspace.pendingImport)
        XCTAssertTrue(store.useImportedTranscript(append: true))
        XCTAssertTrue(store.meetingWorkspace.draft(for: store.state.meetings[0]).transcript.contains("Captured words"))
        XCTAssertFalse(disk.state.meetings[0].transcript.contains("Captured words"))
        XCTAssertTrue(store.saveMeetingNote(id)); XCTAssertTrue(disk.state.meetings[0].transcript.contains("Captured words"))
        XCTAssertTrue(store.state.memories.isEmpty); XCTAssertTrue(store.state.tasks.isEmpty)
    }
    func testDeletingActiveNoteCancelsCaptureAndCannotResurrectIt() async throws {
        let hardware = FixtureMeetingCapture()
        let store = PuddleStore(cache: CaptureDisk(), meetingAudioCapture: hardware); store.storageAvailable = true
        let id = try XCTUnwrap(store.createMeetingNote())
        store.startMeetingTranscription(id, source: .microphone); await wait { store.meetingCapture.status == .listening }
        store.deleteMeetingNote(id)
        hardware.segments[0](.init(channel: .microphone, start: 0, end: 1, text: "Late result", isFinal: true))
        XCTAssertTrue(store.state.meetings.isEmpty); XCTAssertNil(store.meetingWorkspace.pendingImport)
        XCTAssertEqual(store.meetingCapture.status, .idle)
    }
}
