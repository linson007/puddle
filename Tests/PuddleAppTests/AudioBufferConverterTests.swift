import AVFoundation
import XCTest
@testable import Puddle

final class AudioBufferConverterTests: XCTestCase {
    func testMatchingFloatFormatCopiesStorageInsteadOfQueuingReusedTapMemory() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)); input.frameLength = 100
        input.floatChannelData![0][0] = 0.75
        let copy = try AudioBufferConverter(outputFormat: format).convert(input)
        input.floatChannelData![0][0] = -0.5
        XCTAssertEqual(copy.frameLength, 100); XCTAssertEqual(copy.floatChannelData![0][0], 0.75)
    }
    func testInterleavedIntegerFormatAlsoOwnsCopiedStorage() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 2, interleaved: true))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 20)); input.frameLength = 20
        input.int16ChannelData![0][0] = 1234; input.int16ChannelData![0][1] = -4321
        let copy = try AudioBufferConverter(outputFormat: format).convert(input)
        input.int16ChannelData![0][0] = 0
        XCTAssertEqual(copy.int16ChannelData![0][0], 1234); XCTAssertEqual(copy.int16ChannelData![0][1], -4321)
    }
    func testResamplingAndInputDeviceFormatChangesProduceNonemptyMonoBuffers() throws {
        let output = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = AudioBufferConverter(outputFormat: output)
        for rate in [48_000.0, 44_100.0, 32_000.0] {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
            let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)); input.frameLength = 4096
            for channel in 0..<2 { for frame in 0..<4096 { input.floatChannelData![channel][frame] = Float(sin(Double(frame) / 20)) } }
            let converted = try converter.convert(input)
            XCTAssertGreaterThan(converted.frameLength, 1000); XCTAssertEqual(converted.format.channelCount, 1)
            XCTAssertEqual(converted.format.sampleRate, 16_000)
        }
    }
}
