import AVFoundation
import Foundation
import PuddleCore
import XCTest
@testable import Puddle

@MainActor private final class RoutingSpeechFixture: SpeechCapturing {
    var languages: [String] = []
    var failure: Error?
    var texts: [@MainActor (String, Bool) -> Void] = []
    var errors: [@MainActor (String) -> Void] = []
    func start(language: String, onText: @escaping @MainActor (String, Bool) -> Void,
               onError: @escaping @MainActor (String) -> Void) async throws {
        languages.append(language); texts.append(onText); errors.append(onError)
        if let failure { throw failure }
    }
    func finish() {}
    func cancel() {}
}

@MainActor private final class AnalyzerMicrophoneFixture: MeetingAudioCapturing {
    var isSupported = true
    var sources: [MeetingAudioSource] = []
    var installs = 0
    var finishGate: CheckedContinuation<Void, Never>?
    var segments: [@MainActor @Sendable (MeetingTranscriptSegment) -> Void] = []
    var errors: [@MainActor @Sendable (String) -> Void] = []
    var finishError: Error?
    func installLanguage(_ language: String) async throws { installs += 1 }
    func start(language: String, source: MeetingAudioSource,
               onSegment: @escaping @MainActor @Sendable (MeetingTranscriptSegment) -> Void,
               onStatus: @escaping @MainActor @Sendable (String) -> Void,
               onError: @escaping @MainActor @Sendable (String) -> Void) async throws {
        sources.append(source); segments.append(onSegment); errors.append(onError)
    }
    func finish() async throws {
        await withCheckedContinuation { finishGate = $0 }
        if let finishError { throw finishError }
    }
    func cancel() {}
    func drain() { finishGate?.resume(); finishGate = nil }
}

@MainActor final class SpeechCaptureTests: XCTestCase {
    private func waitUntil(seconds: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }; try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Speech capture did not reach the expected state")
    }

    func testSupportedLanguageUsesAnalyzerAndUnsupportedLanguageUsesLegacy() async throws {
        let analyzer = RoutingSpeechFixture(), legacy = RoutingSpeechFixture()
        let capture = SystemSpeechCapture(analyzer: analyzer, legacy: legacy, supportsAnalyzer: { $0 == "en-US" })
        var text = ""
        try await capture.start(language: "en-US", onText: { text = $0; _ = $1 }, onError: { _ in })
        XCTAssertEqual(analyzer.languages, ["en-US"]); XCTAssertTrue(legacy.languages.isEmpty)
        try await capture.start(language: "hi-IN", onText: { text = $0; _ = $1 }, onError: { _ in })
        analyzer.texts[0]("Old session", true); legacy.texts[0]("Current session", true)
        XCTAssertEqual(text, "Current session"); XCTAssertEqual(legacy.languages, ["hi-IN"])
        capture.cancel(); legacy.texts[0]("Late result", true); XCTAssertEqual(text, "Current session")
    }

    func testMissingAnalyzerModelDoesNotRetryThroughSiri() async {
        let analyzer = RoutingSpeechFixture(), legacy = RoutingSpeechFixture()
        analyzer.failure = PuddleError("Install the selected speech language in Settings → Voice.")
        let capture = SystemSpeechCapture(analyzer: analyzer, legacy: legacy, supportsAnalyzer: { _ in true })
        do {
            try await capture.start(language: "en-US", onText: { _, _ in }, onError: { _ in })
            XCTFail("Missing speech model must be reported")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Settings → Voice")) }
        XCTAssertTrue(legacy.languages.isEmpty)
    }

    func testCancellationWhileChoosingEngineNeverStartsMicrophone() async {
        let analyzer = RoutingSpeechFixture(), legacy = RoutingSpeechFixture()
        var gate: CheckedContinuation<Bool, Never>?
        let capture = SystemSpeechCapture(analyzer: analyzer, legacy: legacy, supportsAnalyzer: { _ in
            await withCheckedContinuation { gate = $0 }
        })
        let voice = VoiceInputController(capture: capture)
        voice.start(language: "en-US"); await waitUntil { gate != nil }
        voice.cancel(); gate?.resume(returning: true); gate = nil
        await Task.yield(); await Task.yield()
        XCTAssertTrue(analyzer.languages.isEmpty); XCTAssertTrue(legacy.languages.isEmpty)
        XCTAssertEqual(voice.status, .idle)
    }

    func testAnalyzerMergesRevisionsAndPassagesAndWaitsForDoneToDrain() async {
        let microphone = AnalyzerMicrophoneFixture()
        let voice = VoiceInputController(capture: AnalyzerSpeechCapture(capture: microphone))
        voice.start(language: "en-US"); await waitUntil { voice.status == .listening }
        XCTAssertEqual(microphone.sources, [.microphone]); XCTAssertEqual(microphone.installs, 0)
        microphone.segments[0](.init(channel: .microphone, start: 0, end: 1, text: "A rough thought", isFinal: false))
        microphone.segments[0](.init(channel: .microphone, start: 0, end: 1, text: "A complete thought.", isFinal: true))
        microphone.segments[0](.init(channel: .microphone, start: 1, end: 2, text: "Keep listening", isFinal: false))
        XCTAssertEqual(voice.transcript, "A complete thought. Keep listening")
        XCTAssertEqual(voice.status, .listening); XCTAssertNil(voice.completedTranscript)
        voice.finish(); await waitUntil { microphone.finishGate != nil }
        XCTAssertEqual(voice.status, .finishing); XCTAssertNil(voice.completedTranscript)
        microphone.segments[0](.init(channel: .microphone, start: 1, end: 2, text: "Keep listening, please.", isFinal: true))
        microphone.drain(); await waitUntil { voice.status == .idle }
        XCTAssertEqual(voice.completedTranscript?.text, "A complete thought. Keep listening, please.")
        XCTAssertNil(voice.errorMessage)
    }

    func testInterruptedAnalyzerKeepsDraftAndIgnoresOldCallbacks() async {
        let microphone = AnalyzerMicrophoneFixture()
        let voice = VoiceInputController(capture: AnalyzerSpeechCapture(capture: microphone))
        voice.start(language: "en-US"); await waitUntil { voice.status == .listening }
        microphone.segments[0](.init(channel: .microphone, start: 0, end: 1, text: "Keep this fragment", isFinal: false))
        microphone.errors[0]("The microphone changed.")
        XCTAssertEqual(voice.completedTranscript?.text, "Keep this fragment")
        XCTAssertEqual(voice.errorMessage, "Speech input stopped: The microphone changed. Review any captured text before sending.")
        voice.start(language: "en-US"); await waitUntil { microphone.sources.count == 2 && voice.status == .listening }
        microphone.segments[0](.init(channel: .microphone, start: 0, end: 1, text: "Old draft", isFinal: true))
        microphone.errors[0]("Old error")
        XCTAssertEqual(voice.transcript, ""); XCTAssertNil(voice.errorMessage)
        voice.cancel()
    }

    func testCancelDuringFinalizationCannotCompleteTheNextCapture() async {
        let microphone = AnalyzerMicrophoneFixture()
        let voice = VoiceInputController(capture: AnalyzerSpeechCapture(capture: microphone))
        voice.start(language: "en-US"); await waitUntil { voice.status == .listening }
        voice.finish(); await waitUntil { microphone.finishGate != nil }; voice.cancel()
        voice.start(language: "en-US"); await waitUntil { microphone.sources.count == 2 && voice.status == .listening }
        microphone.segments[1](.init(channel: .microphone, start: 0, end: 1, text: "New draft", isFinal: false))
        microphone.drain(); await Task.yield(); await Task.yield()
        XCTAssertEqual(voice.status, .listening); XCTAssertEqual(voice.transcript, "New draft")
        XCTAssertNil(voice.completedTranscript); voice.cancel()
    }

    func testFinalizationFailureRetainsProvisionalText() async {
        let microphone = AnalyzerMicrophoneFixture(); microphone.finishError = PuddleError("Finalization failed.")
        let voice = VoiceInputController(capture: AnalyzerSpeechCapture(capture: microphone))
        voice.start(language: "en-US"); await waitUntil { voice.status == .listening }
        microphone.segments[0](.init(channel: .microphone, start: 0, end: 1, text: "Retained draft", isFinal: false))
        voice.finish(); await waitUntil { microphone.finishGate != nil }; microphone.drain()
        await waitUntil { voice.status == .idle }
        XCTAssertEqual(voice.completedTranscript?.text, "Retained draft")
        XCTAssertTrue(voice.errorMessage?.contains("Finalization failed.") == true)
    }

    func testEmptyFailureDoesNotAskToReviewNonexistentTextAndLegacyErrorExplainsRecovery() async {
        let microphone = AnalyzerMicrophoneFixture()
        let voice = VoiceInputController(capture: AnalyzerSpeechCapture(capture: microphone))
        voice.start(language: "en-US"); await waitUntil { voice.status == .listening }
        microphone.segments[0](.init(channel: .microphone, start: 0, end: 1, text: ".", isFinal: true))
        microphone.errors[0]("Recognition unavailable.")
        XCTAssertNil(voice.completedTranscript)
        XCTAssertEqual(voice.errorMessage, "Speech input stopped: Recognition unavailable.")
        let disabled = NSError(domain: "kLSRErrorDomain", code: 201, userInfo: [NSLocalizedDescriptionKey: "Siri and Dictation are disabled"])
        XCTAssertTrue(LegacySpeechCapture.errorMessage(for: disabled).contains("System Settings → Keyboard → Dictation"))
        let other = NSError(domain: "OtherDomain", code: 201, userInfo: [NSLocalizedDescriptionKey: "Other failure"])
        XCTAssertEqual(LegacySpeechCapture.errorMessage(for: other), "Other failure")
    }

    func testInstalledAnalyzerProducesVoiceDraftFromSyntheticAudioWithoutLegacyRecognizer() async throws {
        guard #available(macOS 26, *), let audioPath = ProcessInfo.processInfo.environment["PUDDLE_LIVE_AUDIO_FILE"] else {
            throw XCTSkip("Set PUDDLE_LIVE_AUDIO_FILE to a synthetic 'orange folder' audio fixture on macOS 26+")
        }
        let file = AnalyzerFileFixture(url: URL(fileURLWithPath: audioPath)), legacy = RoutingSpeechFixture()
        // Use production engine selection and real installed model/conversion;
        // replace only the microphone with a deterministic audio source.
        let capture = SystemSpeechCapture(analyzer: AnalyzerSpeechCapture(capture: file), legacy: legacy)
        let voice = VoiceInputController(capture: capture)
        voice.start(language: "en-US")
        await waitUntil(seconds: 30) { voice.status == .listening || voice.errorMessage != nil }
        XCTAssertEqual(voice.status, .listening, voice.errorMessage ?? "")
        voice.finish(); await waitUntil(seconds: 30) { voice.status == .idle }
        XCTAssertNil(voice.errorMessage)
        XCTAssertTrue(voice.completedTranscript?.text.lowercased().contains("orange folder") == true, voice.completedTranscript?.text ?? "No draft")
        XCTAssertTrue(legacy.languages.isEmpty)
    }
}

@available(macOS 26, *)
@MainActor private final class AnalyzerFileFixture: MeetingAudioCapturing {
    let url: URL
    var isSupported = true
    private var track: AnalyzerAudioTrack?
    init(url: URL) { self.url = url }
    func installLanguage(_ language: String) async throws { XCTFail("Voice input must not download assets") }
    func start(language: String, source: MeetingAudioSource,
               onSegment: @escaping @MainActor @Sendable (MeetingTranscriptSegment) -> Void,
               onStatus: @escaping @MainActor @Sendable (String) -> Void,
               onError: @escaping @MainActor @Sendable (String) -> Void) async throws {
        XCTAssertEqual(source, .microphone)
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.length < 480_000 else { throw PuddleError("Use a short synthetic audio fixture.") }
        let audio = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: audio)
        let transcriber = try await AnalyzerMeetingAudioCapture().installedModule(language)
        let track = try await AnalyzerAudioTrack.make(transcriber: transcriber, channel: .microphone, origin: 0, onSegment: onSegment, onError: onError)
        self.track = track; track.sink.receive(audio)
    }
    func finish() async throws { try await track?.finish() }
    func cancel() { track?.cancel(); track = nil }
}
