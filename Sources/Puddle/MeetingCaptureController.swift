import Combine
import Foundation
import PuddleCore

enum MeetingCaptureStatus: Equatable { case idle, installingLanguage, preparing, listening, finishing }

@MainActor final class MeetingCaptureController: ObservableObject {
    @Published private(set) var status = MeetingCaptureStatus.idle
    @Published private(set) var noteID: UUID?
    @Published private(set) var timeline = MeetingTranscriptTimeline()
    @Published private(set) var message = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var startedAt: Date?
    @Published private(set) var sourceDescription: String?
    var isActive: Bool { status != .idle }
    var isSupported: Bool { capture.isSupported }
    var onCompletion: (@MainActor (UUID, String) -> Void)?
    var onCheckpoint: (@MainActor (UUID, String) async -> Void)?
    // Periodic snapshots include provisional text, even if speech then goes
    // quiet. Completion flushes immediately; unchanged text is skipped by store.
    nonisolated static let checkpointInterval: Duration = .seconds(30)
    private var checkpoints: Task<Void, Never>?
    private let capture: any MeetingAudioCapturing
    private let maximumSeconds: Double
    private let finishTimeout: Double
    private let sleep: @Sendable (Duration) async throws -> Void
    private var generation = UUID()
    private(set) var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?

    init(capture: any MeetingAudioCapturing, maximumSeconds: Double = 7200, finishTimeout: Double = 15,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.capture = capture; self.maximumSeconds = maximumSeconds; self.finishTimeout = finishTimeout; self.sleep = sleep
    }
    func installLanguage(_ language: String) {
        guard !isActive else { return }
        status = .installingLanguage; errorMessage = nil; message = "Installing Apple's speech language model…"
        let expected = generation
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation(); try await capture.installLanguage(language); try Task.checkCancellation()
                guard generation == expected else { return }; message = "Speech language ready."
            } catch is CancellationError { if generation == expected { message = "Speech language setup was cancelled." } }
            catch { if generation == expected { errorMessage = error.localizedDescription } }
            if generation == expected { status = .idle; work = nil }
        }
    }
    func start(noteID: UUID, language: String, source: MeetingAudioSource) {
        guard !isActive else { return }
        generation = UUID(); let expected = generation
        self.noteID = noteID; status = .preparing; timeline = MeetingTranscriptTimeline()
        errorMessage = nil; message = "Preparing on-device transcription…"; startedAt = nil; sourceDescription = nil
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await capture.start(language: language, source: source, onSegment: { [weak self] segment in
                    guard let self, self.generation == expected else { return }
                    do { try self.timeline.receive(segment) }
                    catch { self.stop(notice: error.localizedDescription) }
                }, onStatus: { [weak self] message in
                    guard let self, self.generation == expected else { return }; self.message = message
                }, onError: { [weak self] message in
                    guard let self, self.generation == expected else { return }; self.stop(notice: message)
                })
                try Task.checkCancellation()
                guard generation == expected, status == .preparing else { return }
                sourceDescription = capture.sourceDescription
                status = .listening; startedAt = Date(); message = "Transcribing on this Mac."
                checkpoints = Task { [weak self, sleep] in
                    while !Task.isCancelled {
                        do { try await sleep(Self.checkpointInterval); try Task.checkCancellation() }
                        catch { return }
                        guard let self, self.generation == expected else { return }
                        let text = self.timeline.text
                        if !text.isEmpty { await self.onCheckpoint?(noteID, text) }
                    }
                }
                deadline = Task { [weak self, sleep, maximumSeconds] in
                    do { try await sleep(.seconds(maximumSeconds)) } catch { return }
                    guard let self, self.generation == expected else { return }
                    self.stop(notice: "The two-hour capture limit was reached. Review and save this transcript, then start another session.")
                }
            } catch is CancellationError { if generation == expected { complete(notice: "Transcription was cancelled before recording.") } }
            catch { if generation == expected { complete(notice: error.localizedDescription) } }
        }
    }
    func stop(notice: String? = nil) {
        guard isActive, status != .finishing else { if let notice { errorMessage = notice }; return }
        if status == .installingLanguage { cancel(); return }
        if status == .preparing { complete(notice: notice); return }
        status = .finishing; errorMessage = notice; message = "Finishing transcription…"; deadline?.cancel()
        let expected = generation
        work = Task { [weak self] in
            guard let self else { return }
            do { try await capture.finish(); try Task.checkCancellation(); if generation == expected { complete(notice: errorMessage) } }
            catch is CancellationError { if generation == expected { complete(notice: "Finalization was cancelled. Review any provisional text.") } }
            catch { if generation == expected { complete(notice: [errorMessage, error.localizedDescription].compactMap { $0 }.joined(separator: " ")) } }
        }
        deadline = Task { [weak self, sleep, finishTimeout] in
            do { try await sleep(.seconds(finishTimeout)) } catch { return }
            guard let self, self.generation == expected else { return }
            self.complete(notice: [self.errorMessage, "Finalization timed out. Any provisional text is labeled for review."].compactMap { $0 }.joined(separator: " "))
        }
    }
    /// Used for note deletion or switching between demo and personal state.
    func cancel() {
        generation = UUID(); work?.cancel(); deadline?.cancel(); checkpoints?.cancel(); checkpoints = nil; capture.cancel()
        status = .idle; noteID = nil; startedAt = nil; sourceDescription = nil; message = ""; errorMessage = nil; timeline = MeetingTranscriptTimeline()
    }
    private func complete(notice: String?) {
        let id = noteID, text = timeline.text
        generation = UUID(); work?.cancel(); deadline?.cancel(); checkpoints?.cancel(); checkpoints = nil; capture.cancel(); status = .idle; startedAt = nil; sourceDescription = nil
        errorMessage = notice ?? (text.isEmpty ? "No speech was detected." : nil)
        message = text.isEmpty ? "Transcription stopped." : "Review the captured text, apply it to the transcript, and save your notes."
        if let id, !text.isEmpty { onCompletion?(id, text) }
        noteID = nil
    }
}
