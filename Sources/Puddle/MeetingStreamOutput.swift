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
        do { try Self.consume(sampleBuffer, into: sink) }
        catch { failure("Meeting audio stopped: \(error.localizedDescription)") }
    }
    static func consume(_ sample: CMSampleBuffer, into sink: AnalyzerAudioSink) throws {
        guard sample.isValid, sample.dataReadiness == .ready, let description = sample.formatDescription,
              CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio else { throw PuddleError("The selected application returned invalid audio.") }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        try sample.withAudioBufferList { buffers, _ in
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: buffers.unsafePointer) else { throw PuddleError("The meeting audio format is unsupported.") }
            sink.receive(pcm, hostSeconds: sample.presentationTimeStamp.seconds)
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { failure("The selected meeting app stopped sharing audio: \(error.localizedDescription)") }
}
