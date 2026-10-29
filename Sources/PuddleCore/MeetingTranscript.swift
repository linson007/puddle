import Foundation

public enum MeetingAudioChannel: String, Codable, Sendable, CaseIterable {
    case microphone, meetingAudio
    public var title: String { self == .microphone ? "Microphone" : "Meeting audio" }
}

public enum MeetingAudioSource: String, CaseIterable, Identifiable, Sendable {
    case microphone, meetingAudio, both
    public var id: Self { self }
    public var title: String {
        switch self { case .microphone: "Microphone"; case .meetingAudio: "Meeting app audio"; case .both: "Meeting app + microphone" }
    }
    public var usesMicrophone: Bool { self != .meetingAudio }
    public var usesMeetingAudio: Bool { self != .microphone }
}

public struct MeetingTranscriptSegment: Equatable, Sendable, Identifiable {
    public let channel: MeetingAudioChannel
    public let start: Double
    public let end: Double
    public let text: String
    public let isFinal: Bool
    public var id: String { "\(channel.rawValue):\(start)" }
    public init(channel: MeetingAudioChannel, start: Double, end: Double, text: String, isFinal: Bool) {
        self.channel = channel; self.start = start; self.end = end; self.text = text; self.isFinal = isFinal
    }
}

/// Revisions replace provisional results; finalized passages remain in chronological order.
public struct MeetingTranscriptTimeline: Equatable, Sendable {
    public private(set) var segments: [MeetingTranscriptSegment] = []
    public init() {}
    public mutating func receive(_ segment: MeetingTranscriptSegment) throws {
        guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end >= segment.start,
              segment.end <= 86_400, segment.text.count <= 12_000 else { throw PuddleError("The speech recognizer returned an invalid passage.") }
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let final = segments.first(where: { $0.channel == segment.channel && $0.start == segment.start && $0.isFinal }) {
            guard !segment.isFinal || final.text == text else { throw PuddleError("The recognizer revised a finalized passage. Review the retained transcript.") }
            return
        }
        if !segment.isFinal, segments.contains(where: { $0.channel == segment.channel && $0.isFinal && $0.start < segment.end && $0.end > segment.start }) { return }
        var next = segments
        next.removeAll {
            guard $0.channel == segment.channel else { return false }
            return $0.start == segment.start || (!$0.isFinal && $0.start < segment.end && $0.end > segment.start)
        }
        if !text.isEmpty {
            next.append(MeetingTranscriptSegment(channel: segment.channel, start: segment.start, end: segment.end, text: text, isFinal: segment.isFinal))
        }
        next.sort { $0.start == $1.start ? $0.channel.rawValue < $1.channel.rawValue : $0.start < $1.start }
        guard next.count <= 5000, Self.render(next).count <= TranscriptImport.maximumCharacters else {
            throw PuddleError("The live transcript reached its size limit. Captured text was retained; continue in a new meeting note.")
        }
        segments = next
    }
    public var text: String { Self.render(segments) }
    public var hasProvisionalText: Bool { segments.contains { !$0.isFinal } }
    private static func render(_ segments: [MeetingTranscriptSegment]) -> String {
        segments.map { "[\(timestamp($0.start))] \($0.channel.title)\($0.isFinal ? "" : " (provisional)"): \($0.text)" }.joined(separator: "\n\n")
    }
    public static func timestamp(_ seconds: Double) -> String {
        let value = Int(max(0, min(seconds.isFinite ? seconds : 0, 86_400)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", value / 3_600_000, value / 60_000 % 60, value / 1000 % 60, value % 1000)
    }
}
