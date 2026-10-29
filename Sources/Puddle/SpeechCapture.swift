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
            let message = error?.localizedDescription
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
}
