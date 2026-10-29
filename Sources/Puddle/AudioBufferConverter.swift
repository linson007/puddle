import AVFoundation
import PuddleCore

/// Used on one audio callback queue. Every output owns its PCM storage.
final class AudioBufferConverter {
    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    init(outputFormat: AVAudioFormat) { self.outputFormat = outputFormat }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0, outputFormat.sampleRate > 0 else { throw PuddleError("An audio source returned an empty or invalid buffer.") }
        if buffer.format == outputFormat {
            guard let copy = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: buffer.frameLength) else { throw PuddleError("Audio buffer allocation failed.") }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            guard source.count == destination.count else { throw PuddleError("Audio channel conversion failed.") }
            for (original, target) in zip(source, destination) {
                guard let from = original.mData, let to = target.mData, original.mDataByteSize <= target.mDataByteSize else { throw PuddleError("Audio buffer copy failed.") }
                memcpy(to, from, Int(original.mDataByteSize))
            }
            return copy
        }
        if inputFormat != buffer.format {
            guard let next = AVAudioConverter(from: buffer.format, to: outputFormat) else { throw PuddleError("The audio format is unsupported for on-device transcription.") }
            next.primeMethod = .none; converter = next; inputFormat = buffer.format
        }
        guard let converter else { throw PuddleError("The audio converter is unavailable.") }
        let frames = AVAudioFrameCount(ceil(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate)) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames) else { throw PuddleError("Audio buffer allocation failed.") }
        var delivered = false, failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, state in
            if delivered { state.pointee = .noDataNow; return nil }
            delivered = true; state.pointee = .haveData; return buffer
        }
        if let failure { throw failure }
        guard status != .error else { throw PuddleError("Audio conversion failed.") }
        return output
    }
}
