import AVFoundation
import CoreMedia
import Speech
import XCTest
@testable import Puddle

private final class AudioFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}

final class MeetingAudioPipelineTests: XCTestCase {
    private func format() throws -> AVAudioFormat { try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)) }
    private func pcm(_ format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)); buffer.frameLength = 100
        for index in 0..<100 { buffer.floatChannelData![0][index] = Float(index) / 100 }
        return buffer
    }
    func testBoundedQueueStopsOnOverloadAndRetainsAlreadyQueuedAudio() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer requires macOS 26") }
        let format = try format(), failure = AudioFailures()
        let (sequence, builder) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let sink = AnalyzerAudioSink(format: format, builder: builder, origin: 100) { failure.append($0) }
        let input = try pcm(format)
        sink.receive(input, hostSeconds: 103.5); sink.receive(input, hostSeconds: 104); sink.receive(input, hostSeconds: 105)
        XCTAssertEqual(failure.count, 1)
        var times: [Double] = []
        for await input in sequence { times.append(input.bufferStartTime!.seconds) }
        XCTAssertEqual(times, [3.5])
        sink.finish(); sink.receive(input); XCTAssertEqual(failure.count, 1)
    }
    func testScreenAudioSampleIsConvertedWithinItsBufferLifetimeAndUsesSharedClock() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer requires macOS 26") }
        let format = try format(), failure = AudioFailures()
        let (sequence, builder) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(8))
        let sink = AnalyzerAudioSink(format: format, builder: builder, origin: 100) { failure.append($0) }
        let sample = try sampleBuffer(pcm(format), at: 105.25)
        try MeetingStreamOutput.consume(sample, into: sink)
        CMSampleBufferInvalidate(sample)
        sink.finish()
        var times: [Double] = []
        for await input in sequence { times.append(input.bufferStartTime!.seconds) }
        XCTAssertEqual(times, [5.25]); XCTAssertEqual(failure.count, 0)
        XCTAssertThrowsError(try MeetingStreamOutput.consume(sample, into: sink))
    }
    func testInvalidClockStopsWithoutUnsafeTimestampConversion() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer requires macOS 26") }
        let format = try format(), failure = AudioFailures()
        let (_, builder) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let sink = AnalyzerAudioSink(format: format, builder: builder, origin: 100) { failure.append($0) }
        sink.receive(try pcm(format), hostSeconds: Double.infinity)
        XCTAssertEqual(failure.count, 1)
    }
    private func sampleBuffer(_ buffer: AVAudioPCMBuffer, at time: Double) throws -> CMSampleBuffer {
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: buffer.format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description), noErr)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 16_000), presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 16_000), decodeTimeStamp: .invalid)
        XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: Int(buffer.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        let result = try XCTUnwrap(sample)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: buffer.audioBufferList), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(result), noErr)
        return result
    }
}
