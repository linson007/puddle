import AVFoundation
import Foundation
import PuddleCore
import Speech

@MainActor protocol SpeechCapturing: AnyObject {
    func start(language: String, onText: @escaping @MainActor (String, Bool) -> Void,
               onError: @escaping @MainActor (String) -> Void) async throws
    func finish()
    func cancel()
}

@MainActor final class SystemSpeechCapture: SpeechCapturing {
    private let analyzer: any SpeechCapturing
    private let legacy: any SpeechCapturing
    private let supportsAnalyzer: @MainActor (String) async -> Bool
    private var active: (any SpeechCapturing)?
    private var session = UUID()

    init(analyzer: (any SpeechCapturing)? = nil, legacy: (any SpeechCapturing)? = nil,
         supportsAnalyzer: (@MainActor (String) async -> Bool)? = nil) {
        self.analyzer = analyzer ?? AnalyzerSpeechCapture()
        self.legacy = legacy ?? LegacySpeechCapture()
        self.supportsAnalyzer = supportsAnalyzer ?? Self.hasAnalyzerSupport
    }

    static func hasAnalyzerSupport(language: String) async -> Bool {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable else { return false }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) != nil
    }

    func start(language: String, onText: @escaping @MainActor (String, Bool) -> Void,
               onError: @escaping @MainActor (String) -> Void) async throws {
        try Task.checkCancellation(); cancel()
        let expected = session
        let useAnalyzer = await supportsAnalyzer(language)
        try Task.checkCancellation()
        guard session == expected else { throw CancellationError() }
        let capture = useAnalyzer ? analyzer : legacy
        active = capture
        do {
            try await capture.start(language: language, onText: { [weak self] text, final in
                guard self?.session == expected else { return }; onText(text, final)
            }, onError: { [weak self] message in
                guard self?.session == expected else { return }; onError(message)
            })
        } catch {
            if session == expected { cancel() }
            throw error
        }
    }

    func finish() { active?.finish() }
    func cancel() { session = UUID(); active?.cancel(); active = nil }
}

/// Adapts the local microphone analyzer to a single, editable dictation draft.
/// A finalized passage is only part of the utterance; completion waits for Done.
@MainActor final class AnalyzerSpeechCapture: SpeechCapturing {
    private let capture: any MeetingAudioCapturing
    private var timeline = MeetingTranscriptTimeline()
    private var session = UUID()
    private var finishTask: Task<Void, Never>?
    private var onText: (@MainActor (String, Bool) -> Void)?
    private var onError: (@MainActor (String) -> Void)?
    private var text: String { timeline.segments.map(\.text).joined(separator: " ") }

    init(capture: (any MeetingAudioCapturing)? = nil) { self.capture = capture ?? SystemMeetingAudioCapture() }

    func start(language: String, onText: @escaping @MainActor (String, Bool) -> Void,
               onError: @escaping @MainActor (String) -> Void) async throws {
        try Task.checkCancellation(); cancel()
        self.onText = onText; self.onError = onError
        let expected = session
        do {
            try await capture.start(language: language, source: .microphone, onSegment: { [weak self] segment in
                guard let self, self.session == expected else { return }
                do { try self.timeline.receive(segment); self.onText?(self.text, false) }
                catch { self.onError?(error.localizedDescription) }
            }, onStatus: { _ in }, onError: { [weak self] message in
                guard let self, self.session == expected else { return }; self.onError?(message)
            })
            try Task.checkCancellation()
            guard session == expected else { throw CancellationError() }
        } catch {
            if session == expected { cancel() }
            throw error
        }
    }

    func finish() {
        guard onText != nil, finishTask == nil else { return }
        let expected = session
        finishTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation(); try await capture.finish(); try Task.checkCancellation()
                guard session == expected else { return }; onText?(text, true)
            } catch is CancellationError {}
            catch { if session == expected { onError?(error.localizedDescription) } }
        }
    }

    func cancel() {
        session = UUID(); finishTask?.cancel(); finishTask = nil; capture.cancel()
        timeline = MeetingTranscriptTimeline(); onText = nil; onError = nil
    }
}

@MainActor final class LegacySpeechCapture: SpeechCapturing {
    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var session = UUID()

    func start(language: String, onText: @escaping @MainActor (String, Bool) -> Void,
               onError: @escaping @MainActor (String) -> Void) async throws {
        try Task.checkCancellation()
        cancel()
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil,
              Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            throw PuddleError("Run the built Puddle.app to use microphone input.")
        }
        let authorization: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
        guard authorization == .authorized else {
            throw PuddleError("Speech recognition permission is required. Enable Puddle under System Settings → Privacy & Security → Speech Recognition.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.supportsOnDeviceRecognition else {
            throw PuddleError("On-device speech recognition is unavailable for this language. Choose another voice language or install its macOS dictation language pack. Audio was not sent to a cloud service.")
        }
        guard recognizer.isAvailable else { throw PuddleError("Speech recognition is temporarily unavailable. Try again shortly.") }
        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        try Task.checkCancellation()
        guard microphoneAllowed else {
            throw PuddleError("Microphone access is required. Enable Puddle under System Settings → Privacy & Security → Microphone.")
        }
        let engine = AVAudioEngine(), request = SFSpeechAudioBufferRecognitionRequest()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw PuddleError("No working microphone was found. Check your macOS sound input device.") }
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true; request.taskHint = .dictation
        self.engine = engine; self.recognizer = recognizer; self.request = request
        let expected = session
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        tapInstalled = true
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString, isFinal = result?.isFinal ?? false
            let message = error.map(Self.errorMessage)
            Task { @MainActor in
                guard let self, self.session == expected else { return }
                if let text { onText(text, isFinal) }
                if let message, !isFinal { onError(message) }
            }
        }
        engine.prepare()
        do { try engine.start() }
        catch { cancel(); throw PuddleError("The microphone could not start: \(error.localizedDescription)") }
    }

    func finish() { stopAudio(); request?.endAudio() }
    func cancel() {
        session = UUID(); stopAudio(); request?.endAudio(); recognitionTask?.cancel()
        request = nil; recognitionTask = nil; recognizer = nil; engine = nil
    }
    private func stopAudio() {
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
    }

    static func errorMessage(for error: Error) -> String {
        let error = error as NSError
        if error.domain == "kLSRErrorDomain", error.code == 201 {
            return "macOS Dictation is disabled for this speech language. Enable Dictation in System Settings → Keyboard → Dictation, then try again."
        }
        return error.localizedDescription
    }
}
