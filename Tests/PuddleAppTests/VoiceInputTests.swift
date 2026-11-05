import Foundation
import XCTest
import PuddleCore
@testable import Puddle

@MainActor private final class FakeSpeechCapture: SpeechCapturing {
    var starts = 0
    var finishes = 0
    var cancelled = 0
    var holdPermission = false
    var permission: CheckedContinuation<Void, Never>?
    var texts: [@MainActor (String, Bool) -> Void] = []
    var failures: [@MainActor (String) -> Void] = []
    func start(language: String, onText: @escaping @MainActor (String, Bool) -> Void,
               onError: @escaping @MainActor (String) -> Void) async throws {
        starts += 1; texts.append(onText); failures.append(onError)
        if holdPermission { await withCheckedContinuation { permission = $0 } }
        try Task.checkCancellation()
    }
    func finish() { finishes += 1 }
    func cancel() { cancelled += 1 }
}

@MainActor final class VoiceInputTests: XCTestCase {
    func testImmediateCancellationDoesNotStartCaptureOrPermissionRequest() async {
        let capture = FakeSpeechCapture()
        let subject = VoiceInputController(capture: capture)
        subject.start(language: "en-US"); subject.cancel()
        await subject.startTask?.value
        XCTAssertEqual(capture.starts, 0)
        XCTAssertEqual(subject.status, .idle)
    }
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }; try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Voice fixture did not reach the expected state")
    }

    func testPartialAndFinalDictationRemainDraftUntilUserSends() async {
        let capture = FakeSpeechCapture()
        let subject = VoiceInputController(capture: capture)
        subject.start(language: "en-US")
        await waitUntil { subject.status == .listening }
        capture.texts[0]("A partial thought", false)
        XCTAssertEqual(subject.transcript, "A partial thought")
        XCTAssertNil(subject.completedTranscript)
        subject.finish(); XCTAssertEqual(capture.finishes, 1)
        capture.texts[0]("A completed thought", true)
        XCTAssertEqual(subject.status, .idle)
        XCTAssertEqual(subject.completedTranscript?.text, "A completed thought")
        XCTAssertNil(subject.errorMessage)
    }

    func testCancelWhilePermissionIsPendingNeverAcceptsLateResults() async {
        let capture = FakeSpeechCapture(); capture.holdPermission = true
        let voice = VoiceInputController(capture: capture)
        voice.start(language: "en-US")
        await waitUntil { capture.permission != nil }
        let pending = voice.startTask
        voice.cancel(); capture.permission?.resume(); capture.permission = nil
        capture.texts[0]("Must not appear", true)
        await pending?.value
        XCTAssertEqual(voice.status, .idle)
        XCTAssertNil(voice.completedTranscript); XCTAssertTrue(voice.transcript.isEmpty)
    }

    func testOldRecognitionCallbackCannotOverwriteNewSession() async {
        let capture = FakeSpeechCapture()
        let subject = VoiceInputController(capture: capture)
        subject.start(language: "en-US"); await waitUntil { subject.status == .listening }
        subject.cancel(); subject.start(language: "en-US"); await waitUntil { capture.starts == 2 && subject.status == .listening }
        capture.texts[0]("Stale text", true); capture.texts[1]("Current text", false)
        XCTAssertEqual(subject.transcript, "Current text"); XCTAssertNil(subject.completedTranscript)
        subject.cancel()
    }

    func testDurationAndFinishDeadlinesPreserveRecognizedText() async {
        let capture = FakeSpeechCapture()
        let duration = AsyncTestGate(), finishing = AsyncTestGate()
        let voice = VoiceInputController(capture: capture, sleep: { interval in
            if interval == .seconds(50) { await duration.pause() }
            else { await finishing.pause() }
            try Task.checkCancellation()
        })
        voice.start(language: "en-US")
        await fulfillment(of: [duration.entered], timeout: 5)
        XCTAssertEqual(voice.status, .listening)
        capture.texts[0]("Keep this draft", false)
        await duration.release()
        await fulfillment(of: [finishing.entered], timeout: 5)
        XCTAssertEqual(voice.status, .finishing)
        await finishing.release()
        await waitUntil { voice.status == .idle }
        XCTAssertEqual(capture.finishes, 1)
        XCTAssertEqual(voice.completedTranscript?.text, "Keep this draft")
    }

    func testFailurePreservesPartialTextAndDemoCannotStartMicrophone() async {
        let capture = FakeSpeechCapture()
        let subject = VoiceInputController(capture: capture)
        subject.start(language: "en-US"); await waitUntil { subject.status == .listening }
        capture.texts[0]("Useful fragment", false); capture.failures[0]("Fixture failure")
        XCTAssertEqual(subject.completedTranscript?.text, "Useful fragment")
        XCTAssertNotNil(subject.errorMessage)
        let store = PuddleStore(speechCapture: capture)
        await store.enterDemo(); store.toggleVoiceInput()
        XCTAssertEqual(capture.starts, 1)
    }
}
