import AVFoundation
import Foundation

@MainActor protocol SpeechPlaying: AnyObject {
    func speak(_ text: String, language: String, speed: Double, completion: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor final class SystemSpeechPlayer: NSObject, SpeechPlaying, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: ObjectIdentifier?
    private var completion: (@MainActor () -> Void)?

    override init() {
        super.init(); synthesizer.delegate = self
    }

    func speak(_ text: String, language: String, speed: Double, completion: @escaping @MainActor () -> Void) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(max(0.7, min(1.3, speed)))
        currentUtterance = ObjectIdentifier(utterance); self.completion = completion
        synthesizer.speak(utterance)
    }

    func stop() {
        currentUtterance = nil; completion = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finish(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finish(id) }
    }

    private func finish(_ id: ObjectIdentifier) {
        guard id == currentUtterance else { return }
        currentUtterance = nil
        let callback = completion; completion = nil; callback?()
    }
}
