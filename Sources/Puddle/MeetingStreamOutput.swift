import AVFoundation
import CoreMedia
import Foundation
import PuddleCore
@preconcurrency import ScreenCaptureKit

/// Receives audio only; no screen/video output is registered or stored.
@available(macOS 26, *)
final class MeetingStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let audio: AnalyzerAudioSink
    let microphone: AnalyzerAudioSink?
    let failure: @Sendable (String) -> Void
    #if DEBUG
    private let diagnostics = UITestWorkspace.enabled
    private var buffersSeen = 0
    private var maximumPeak: Float = 0
    #endif
    init(audio: AnalyzerAudioSink, microphone: AnalyzerAudioSink?, failure: @escaping @Sendable (String) -> Void) {
        self.audio = audio; self.microphone = microphone; self.failure = failure
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let sink: AnalyzerAudioSink
        switch type {
        case .audio: sink = audio
        case .microphone: guard let microphone else { return }; sink = microphone
        default: return
        }
        do {
            try Self.consume(sampleBuffer, into: sink) { pcm in
                #if DEBUG
                guard self.diagnostics else { return }
                self.buffersSeen += 1
                if let channels = pcm.floatChannelData {
                    let planes = pcm.format.isInterleaved ? 1 : Int(pcm.format.channelCount)
                    let samples = Int(pcm.frameLength) * (pcm.format.isInterleaved ? Int(pcm.format.channelCount) : 1)
                    for channel in 0..<planes {
                        for frame in 0..<samples { self.maximumPeak = max(self.maximumPeak, abs(channels[channel][frame])) }
                    }
                }
                if self.buffersSeen == 1 || self.buffersSeen % 50 == 0 {
                    UITestWorkspace.recordAudioDiagnostic("Buffers: \(self.buffersSeen), frames: \(pcm.frameLength), peak: \(self.maximumPeak), format: \(pcm.format)")
                }
                #endif
            }
        }
        catch { failure("Meeting audio stopped: \(error.localizedDescription)") }
    }
    static func consume(_ sample: CMSampleBuffer, into sink: AnalyzerAudioSink, observe: ((AVAudioPCMBuffer) -> Void)? = nil) throws {
        guard sample.isValid, sample.dataReadiness == .ready, let description = sample.formatDescription,
              CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio else { throw PuddleError("The selected application returned invalid audio.") }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        try sample.withAudioBufferList { buffers, _ in
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: buffers.unsafePointer) else { throw PuddleError("The meeting audio format is unsupported.") }
            observe?(pcm)
            sink.receive(pcm, hostSeconds: sample.presentationTimeStamp.seconds)
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { failure("The selected meeting app stopped sharing audio: \(error.localizedDescription)") }
}
