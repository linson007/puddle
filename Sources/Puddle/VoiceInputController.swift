import Combine
import Foundation

enum VoiceInputStatus: Equatable { case idle, requestingPermission, listening, finishing }

struct DictationDraft: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

@MainActor final class VoiceInputController: ObservableObject {
    @Published private(set) var status = VoiceInputStatus.idle
    @Published private(set) var transcript = ""
    @Published private(set) var completedTranscript: DictationDraft?
    @Published private(set) var errorMessage: String?
    var isActive: Bool { status != .idle }
    private let capture: any SpeechCapturing
    private let maximumSeconds: Double
    private let finishTimeout: Double
    private var generation = UUID()
    private var startTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    init(capture: any SpeechCapturing, maximumSeconds: Double = 50, finishTimeout: Double = 2) {
        self.capture = capture; self.maximumSeconds = maximumSeconds; self.finishTimeout = finishTimeout
    }

    func toggle(language: String) {
        if status == .listening { finish() }
        else if isActive { cancel() }
        else { start(language: language) }
    }

    func start(language: String) {
        cancel(); status = .requestingPermission
        let expected = generation
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await capture.start(language: language, onText: { [weak self] text, final in
                    guard let self, self.generation == expected else { return }
                    self.transcript = String(text.prefix(12_000))
                    if final { self.complete() }
                    else if text.count >= 12_000 { self.finish() }
                }, onError: { [weak self] message in
                    guard let self, self.generation == expected else { return }
                    self.complete(notice: "Speech input stopped: \(message). Review any captured text before sending.")
                })
                try Task.checkCancellation()
                guard generation == expected, status == .requestingPermission else { return }
                status = .listening
                deadlineTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(self?.maximumSeconds ?? 50)) } catch { return }
                    guard let self, self.generation == expected else { return }
                    self.finish()
                }
            } catch is CancellationError {}
            catch { if generation == expected { complete(notice: error.localizedDescription) } }
        }
    }

    func finish() {
        guard status == .listening else { if status == .requestingPermission { cancel() }; return }
        status = .finishing; deadlineTask?.cancel(); capture.finish()
        let expected = generation
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(self?.finishTimeout ?? 2)) } catch { return }
            guard let self, self.generation == expected else { return }
            self.complete()
        }
    }

    func cancel() {
        generation = UUID(); startTask?.cancel(); deadlineTask?.cancel(); capture.cancel()
        status = .idle; transcript = ""; completedTranscript = nil; errorMessage = nil
    }

    func dismissError() { errorMessage = nil }

    private func complete(notice: String? = nil) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        generation = UUID(); deadlineTask?.cancel(); capture.cancel(); status = .idle
        errorMessage = notice ?? (text.isEmpty ? "No speech was detected. Try again, or type your message." : nil)
        if !text.isEmpty { completedTranscript = DictationDraft(text: text) }
    }
}
