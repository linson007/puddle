import AVFoundation
import Foundation
import PuddleCore
import Speech
@preconcurrency import ScreenCaptureKit

@MainActor protocol MeetingAudioCapturing: AnyObject {
    var isSupported: Bool { get }
    var sourceDescription: String? { get }
    func installLanguage(_ language: String) async throws
    func start(language: String, source: MeetingAudioSource,
               onSegment: @escaping @MainActor @Sendable (MeetingTranscriptSegment) -> Void,
               onStatus: @escaping @MainActor @Sendable (String) -> Void,
               onError: @escaping @MainActor @Sendable (String) -> Void) async throws
    func finish() async throws
    func cancel()
}

extension MeetingAudioCapturing {
    var sourceDescription: String? { nil }
}

@MainActor final class SystemMeetingAudioCapture: MeetingAudioCapturing {
    private var implementation: (any MeetingAudioCapturing)?
    var isSupported: Bool { if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }; return false }
    var sourceDescription: String? { implementation?.sourceDescription }
    private func backend() throws -> any MeetingAudioCapturing {
        guard #available(macOS 26, *) else { throw PuddleError("Live meeting transcription requires macOS 26 or later. You can still import a transcript on this Mac.") }
        if let implementation { return implementation }
        let result = AnalyzerMeetingAudioCapture(); implementation = result; return result
    }
    func installLanguage(_ language: String) async throws { try await backend().installLanguage(language) }
    func start(language: String, source: MeetingAudioSource, onSegment: @escaping @MainActor @Sendable (MeetingTranscriptSegment) -> Void,
               onStatus: @escaping @MainActor @Sendable (String) -> Void, onError: @escaping @MainActor @Sendable (String) -> Void) async throws {
        try await backend().start(language: language, source: source, onSegment: onSegment, onStatus: onStatus, onError: onError)
    }
    func finish() async throws { try await implementation?.finish() }
    func cancel() { implementation?.cancel(); implementation = nil }
}

@available(macOS 26, *)
@MainActor final class AnalyzerMeetingAudioCapture: MeetingAudioCapturing {
    var isSupported: Bool { SpeechTranscriber.isAvailable }
    private(set) var sourceDescription: String?
    private var engine: AVAudioEngine?
    private var microphone: AnalyzerAudioTrack?
    private var meetingAudio: AnalyzerAudioTrack?
    private var stream: SCStream?
    private var streamOutput: MeetingStreamOutput?
    private var picker: MeetingContentPicker?
    private var tapInstalled = false
    private var engineObserver: NSObjectProtocol?
    private var generation = UUID()

    private func module(_ language: String) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw PuddleError("Long-form on-device transcription is unavailable for this Mac or language. Choose another voice language or import a transcript.")
        }
        try Task.checkCancellation()
        // Reservation claims an already installed shared asset for this app. It
        // does not download; installation stays behind the explicit control.
        try await AssetInventory.reserve(locale: locale)
        try Task.checkCancellation()
        return SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
    }
    func installedModule(_ language: String) async throws -> SpeechTranscriber {
        let transcriber = try await module(language)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw PuddleError("Install the selected speech language in Settings → Voice → Install speech language, then try again. This downloads Apple's on-device model; audio stays on this Mac.")
        }
        try Task.checkCancellation()
        return transcriber
    }
    func installLanguage(_ language: String) async throws {
        try Task.checkCancellation()
        let transcriber = try await module(language)
        if let download = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let progress = download.progress
            try await withTaskCancellationHandler {
                try Task.checkCancellation(); try await download.downloadAndInstall()
            } onCancel: { progress.cancel() }
        }
        try Task.checkCancellation()
    }
    func start(language: String, source: MeetingAudioSource, onSegment: @escaping @MainActor @Sendable (MeetingTranscriptSegment) -> Void,
               onStatus: @escaping @MainActor @Sendable (String) -> Void, onError: @escaping @MainActor @Sendable (String) -> Void) async throws {
        try Task.checkCancellation(); cancel()
        let expected = generation
        let transcriber = try await installedModule(language)
        try Task.checkCancellation(); guard generation == expected else { throw CancellationError() }
        if source.usesMicrophone {
            guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else { throw PuddleError("Run the built Puddle.app for microphone transcription.") }
            onStatus("Waiting for microphone permission…")
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            try Task.checkCancellation(); guard generation == expected else { throw CancellationError() }
            guard allowed else { throw PuddleError("Enable Puddle under System Settings → Privacy & Security → Microphone, then try again.") }
        }
        let filter: SCContentFilter?
        if source.usesMeetingAudio {
            onStatus("Choose the meeting application in the macOS sharing picker…")
            let picker = MeetingContentPicker(); self.picker = picker
            filter = try await picker.select()
            try Task.checkCancellation(); guard generation == expected else { throw CancellationError() }
        } else { filter = nil }
        onStatus("Preparing on-device speech model…")
        let origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        if let filter {
            try await startMeetingStream(filter: filter, source: source, language: language, transcriber: transcriber,
                origin: origin, expected: expected, onSegment: onSegment, onError: onError)
            return
        }
        let track = try await AnalyzerAudioTrack.make(transcriber: transcriber, channel: .microphone, origin: origin, onSegment: onSegment, onError: onError)
        guard !Task.isCancelled, generation == expected else { track.cancel(); throw CancellationError() }
        microphone = track
        let engine = AVAudioEngine(), input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { cancel(); throw PuddleError("No working microphone was found. Check the macOS input device.") }
        self.engine = engine
        let sink = track.sink
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            sink.receive(buffer, hostSeconds: time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil)
        }
        tapInstalled = true; engine.prepare()
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected else { return }
                onError("The microphone configuration changed. Review the retained text, check the input device, and start again.")
            }
        }
        sink.startClock(at: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
        do { try engine.start() } catch { cancel(); throw error }
        sourceDescription = "Microphone"
    }
    func finish() async throws {
        stopMicrophone()
        if let stream { self.stream = nil; try await stream.stopCapture() }
        picker?.cancel(); picker = nil; streamOutput = nil
        // Drain both channels concurrently so one cannot starve the other's result queue.
        async let mic: Void = microphone?.finish() ?? ()
        async let app: Void = meetingAudio?.finish() ?? ()
        _ = try await (mic, app); microphone = nil; meetingAudio = nil
    }
    func cancel() {
        generation = UUID(); sourceDescription = nil; stopMicrophone(); microphone?.cancel(); microphone = nil
        meetingAudio?.cancel(); meetingAudio = nil; picker?.cancel(); picker = nil
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil; streamOutput = nil
    }
    private func startMeetingStream(filter: SCContentFilter, source: MeetingAudioSource, language: String, transcriber: SpeechTranscriber,
                                    origin: Double, expected: UUID, onSegment: @escaping @MainActor @Sendable (MeetingTranscriptSegment) -> Void,
                                    onError: @escaping @MainActor @Sendable (String) -> Void) async throws {
        let selectedSource = try Self.selectedApplicationDescription(filter.includedApplications.map {
            $0.applicationName.isEmpty ? $0.bundleIdentifier : $0.applicationName
        }, includingMicrophone: source.usesMicrophone)
        #if DEBUG
        if UITestWorkspace.enabled {
            UITestWorkspace.recordAudioDiagnostic("Scope: " + filter.includedApplications.map { "\($0.applicationName):\($0.bundleIdentifier):\($0.processID)" }.joined(separator: "|"))
        }
        #endif
        let audio = try await AnalyzerAudioTrack.make(transcriber: transcriber, channel: .meetingAudio, origin: origin, onSegment: onSegment, onError: onError)
        guard !Task.isCancelled, generation == expected else { audio.cancel(); throw CancellationError() }
        meetingAudio = audio
        if source.usesMicrophone {
            let module = try await module(language)
            let mic = try await AnalyzerAudioTrack.make(transcriber: module, channel: .microphone, origin: origin, onSegment: onSegment, onError: onError)
            guard !Task.isCancelled, generation == expected else { mic.cancel(); throw CancellationError() }
            microphone = mic
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true; configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = source.usesMicrophone; configuration.sampleRate = 48_000; configuration.channelCount = 1
        configuration.width = 2; configuration.height = 2; configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let output = MeetingStreamOutput(audio: audio.sink, microphone: microphone?.sink) { message in Task { @MainActor in onError(message) } }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        let queue = DispatchQueue(label: "app.puddle.meeting-audio", qos: .userInitiated)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
        if source.usesMicrophone { try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: queue) }
        self.stream = stream; streamOutput = output
        let started = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        audio.sink.startClock(at: started); microphone?.sink.startClock(at: started)
        do { try await stream.startCapture(); try Task.checkCancellation() }
        catch { cancel(); throw error }
        guard generation == expected else { cancel(); throw CancellationError() }
        sourceDescription = selectedSource
    }
    static func selectedApplicationDescription(_ names: [String], includingMicrophone: Bool) throws -> String {
        guard names.count == 1, let name = names.first?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw PuddleError("Select exactly one meeting application in the macOS sharing picker, then try again.")
        }
        return includingMicrophone ? "\(name) + microphone" : name
    }
    private func stopMicrophone() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver); self.engineObserver = nil }
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine = nil
    }
}

@available(macOS 26, *)
@MainActor final class AnalyzerAudioTrack {
    let sink: AnalyzerAudioSink
    private let analyzer: SpeechAnalyzer
    private var results: Task<Void, Never>?
    private var cancelled = false
    private init(sink: AnalyzerAudioSink, analyzer: SpeechAnalyzer) { self.sink = sink; self.analyzer = analyzer }

    static func make(transcriber: SpeechTranscriber, channel: MeetingAudioChannel, origin: Double,
                     onSegment: @escaping @MainActor @Sendable (MeetingTranscriptSegment) -> Void,
                     onError: @escaping @MainActor @Sendable (String) -> Void) async throws -> AnalyzerAudioTrack {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw PuddleError("No compatible on-device audio format is available.") }
        let (sequence, builder) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let sink = AnalyzerAudioSink(format: format, builder: builder, origin: origin) { message in Task { @MainActor in onError(message) } }
        let track = AnalyzerAudioTrack(sink: sink, analyzer: analyzer)
        track.results = Task { [weak track] in
            do {
                for try await result in transcriber.results {
                    guard let track, !track.cancelled, !Task.isCancelled else { return }
                    onSegment(MeetingTranscriptSegment(channel: channel, start: result.range.start.seconds,
                        end: result.range.end.seconds, text: String(result.text.characters), isFinal: result.isFinal))
                }
            } catch { if !Task.isCancelled, track?.cancelled == false { onError("Speech recognition stopped: \(error.localizedDescription)") } }
        }
        do { try await analyzer.prepareToAnalyze(in: format); try await analyzer.start(inputSequence: sequence); try Task.checkCancellation() }
        catch { track.cancel(); throw error }
        return track
    }
    func finish() async throws {
        sink.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await results?.value
    }
    func cancel() {
        cancelled = true; sink.finish(); results?.cancel(); results = nil
        let analyzer = analyzer; Task { await analyzer.cancelAndFinishNow() }
    }
}

/// Serializes callback conversion and bounds queued audio; overload stops capture visibly.
@available(macOS 26, *)
final class AnalyzerAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AudioBufferConverter
    private let builder: AsyncStream<AnalyzerInput>.Continuation
    private let failure: @Sendable (String) -> Void
    private var closed = false
    private var frames: Int64 = 0
    private var origin: Double
    init(format: AVAudioFormat, builder: AsyncStream<AnalyzerInput>.Continuation, origin: Double, failure: @escaping @Sendable (String) -> Void) {
        converter = AudioBufferConverter(outputFormat: format); self.builder = builder; self.failure = failure
        self.origin = origin
    }
    func receive(_ buffer: AVAudioPCMBuffer, hostSeconds: Double? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        do {
            let output = try converter.convert(buffer)
            guard output.frameLength > 0 else { return }
            let clock = hostSeconds.map { $0 - origin }
            if let clock {
                guard clock.isFinite, abs(clock) <= 86_400 else { throw PuddleError("The audio source returned an invalid timestamp.") }
                frames = max(frames, Int64(max(0, clock) * output.format.sampleRate))
            }
            let start = CMTime(value: frames, timescale: CMTimeScale(output.format.sampleRate))
            frames += Int64(output.frameLength)
            switch builder.yield(AnalyzerInput(buffer: output, bufferStartTime: start)) {
            case .dropped: closed = true; builder.finish(); failure("Audio processing could not keep up. Transcription stopped; review the retained text for gaps.")
            case .terminated: closed = true
            case .enqueued: break
            @unknown default: break
            }
        } catch { closed = true; builder.finish(); failure("Audio processing stopped: \(error.localizedDescription)") }
    }
    func finish() { lock.lock(); defer { lock.unlock() }; closed = true; builder.finish() }
    func startClock(at seconds: Double) { lock.lock(); defer { lock.unlock() }; if frames == 0 { origin = seconds } }
}
