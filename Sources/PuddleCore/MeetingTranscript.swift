import Foundation

public enum MeetingRecoveryLimits {
    public static let maximumCount = 128
    public static let maximumBytes = 16 * 1024 * 1024
    public static let maximumTextBytes = 1024 * 1024
    public static let maximumQuarantineCount = 5
    static func validate(_ values: [MeetingCaptureRecovery]) throws {
        guard values.count <= maximumCount, Set(values.map(\.noteID)).count == values.count,
              values.allSatisfy({ $0.text.utf8.count <= maximumTextBytes && $0.text.count <= TranscriptImport.maximumCharacters }),
              values.reduce(0, { $0 + $1.text.utf8.count }) <= maximumBytes else {
            throw PuddleError("Meeting recovery storage is full. Review and save or discard existing recoveries, then retry. Previous recovery files were preserved.")
        }
    }
}

public struct MeetingCaptureRecovery: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID { noteID }
    public let noteID: UUID
    public var text: String
    public var updatedAt: Date
    public init(noteID: UUID, text: String, updatedAt: Date = Date()) { self.noteID = noteID; self.text = text; self.updatedAt = updatedAt }
}

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
    private var renderedPayloadCharacters = 0
    public init() {}
    public mutating func receive(_ segment: MeetingTranscriptSegment) throws {
        guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end >= segment.start,
              segment.end <= 86_400, segment.text.count <= 12_000 else { throw PuddleError("The speech recognizer returned an invalid passage.") }
        let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some recognizers emit punctuation for silence. It must not create a
        // transcript/recovery or prevent a later real passage at the same time.
        let ignored = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).union(.controlCharacters)
        let text = trimmed.unicodeScalars.contains(where: { !ignored.contains($0) }) ? trimmed : ""
        if let final = segments.first(where: { $0.channel == segment.channel && $0.start == segment.start && $0.isFinal }) {
            guard !segment.isFinal || final.text == text else { throw PuddleError("The recognizer revised a finalized passage. Review the retained transcript.") }
            return
        }
        if !segment.isFinal, segments.contains(where: { $0.channel == segment.channel && $0.isFinal && $0.start < segment.end && $0.end > segment.start }) { return }
        let removed = segments.indices.filter { index in
            let value = segments[index]
            guard value.channel == segment.channel else { return false }
            return value.start == segment.start || (!value.isFinal && value.start < segment.end && value.end > segment.start)
        }
        let next = MeetingTranscriptSegment(channel: segment.channel, start: segment.start, end: segment.end, text: text, isFinal: segment.isFinal)
        let count = segments.count - removed.count + (text.isEmpty ? 0 : 1)
        let payload = renderedPayloadCharacters - removed.reduce(0) { $0 + Self.render(segments[$1]).count } + (text.isEmpty ? 0 : Self.render(next).count)
        guard count <= 5000, payload + max(0, count - 1) * 2 <= TranscriptImport.maximumCharacters else {
            throw PuddleError("The live transcript reached its size limit. Captured text was retained; continue in a new meeting note.")
        }
        for index in removed.reversed() { segments.remove(at: index) }
        if !text.isEmpty {
            var low = 0, high = segments.count
            while low < high {
                let middle = (low + high) / 2, value = segments[middle]
                if value.start < next.start || (value.start == next.start && value.channel.rawValue < next.channel.rawValue) { low = middle + 1 }
                else { high = middle }
            }
            segments.insert(next, at: low)
        }
        renderedPayloadCharacters = payload
    }
    public var text: String { Self.render(segments) }
    public var hasProvisionalText: Bool { segments.contains { !$0.isFinal } }
    private static func render(_ segments: [MeetingTranscriptSegment]) -> String {
        segments.map(render).joined(separator: "\n\n")
    }
    private static func render(_ segment: MeetingTranscriptSegment) -> String {
        "[\(timestamp(segment.start))] \(segment.channel.title)\(segment.isFinal ? "" : " (provisional)"): \(segment.text)"
    }
    public static func timestamp(_ seconds: Double) -> String {
        let value = Int(max(0, min(seconds.isFinite ? seconds : 0, 86_400)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", value / 3_600_000, value / 60_000 % 60, value / 1000 % 60, value % 1000)
    }
}
