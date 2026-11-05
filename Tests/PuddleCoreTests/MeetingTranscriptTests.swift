import XCTest
@testable import PuddleCore

final class MeetingTranscriptTests: XCTestCase {
    func testLargeTimelineKeepsOrderAndBudgetWithoutRenderingEveryUpdate() throws {
        var timeline = MeetingTranscriptTimeline()
        let started = ContinuousClock.now
        for index in 0..<4_000 {
            try timeline.receive(.init(channel: .microphone, start: Double(index), end: Double(index + 1), text: "Word", isFinal: true))
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
        XCTAssertEqual(timeline.segments.count, 4_000)
        XCTAssertEqual(timeline.segments.map(\.start), (0..<4_000).map(Double.init))
        XCTAssertLessThanOrEqual(timeline.text.count, TranscriptImport.maximumCharacters)
        try timeline.receive(.init(channel: .meetingAudio, start: 0.5, end: 1, text: "Earlier source", isFinal: false))
        XCTAssertEqual(timeline.segments[1].text, "Earlier source")
    }
    func testPunctuationFromSilenceDoesNotCreatePassagesAndRealSpeechStillReplacesIt() throws {
        var timeline = MeetingTranscriptTimeline()
        for value in [".", "...", "?!", "—", "\n"] {
            try timeline.receive(.init(channel: .meetingAudio, start: 0, end: 1, text: value, isFinal: true))
            XCTAssertTrue(timeline.text.isEmpty)
        }
        try timeline.receive(.init(channel: .meetingAudio, start: 0, end: 2, text: "नमस्ते 🙂 +1", isFinal: false))
        XCTAssertTrue(timeline.text.contains("नमस्ते 🙂 +1"))
        try timeline.receive(.init(channel: .meetingAudio, start: 0, end: 2, text: "...", isFinal: false))
        XCTAssertTrue(timeline.text.isEmpty)
    }
    func testRevisionsReplaceProvisionalPassagesAndLatePartialsCannotChangeFinalText() throws {
        var timeline = MeetingTranscriptTimeline()
        try timeline.receive(.init(channel: .microphone, start: 0, end: 2, text: "We plan", isFinal: false))
        try timeline.receive(.init(channel: .microphone, start: 0, end: 3, text: "We plan to review.", isFinal: true))
        try timeline.receive(.init(channel: .microphone, start: 0, end: 3, text: "Late partial", isFinal: false))
        XCTAssertEqual(timeline.segments.count, 1); XCTAssertFalse(timeline.hasProvisionalText)
        XCTAssertTrue(timeline.text.contains("We plan to review.")); XCTAssertFalse(timeline.text.contains("Late partial"))
        XCTAssertThrowsError(try timeline.receive(.init(channel: .microphone, start: 0, end: 3, text: "Conflicting final", isFinal: true)))
    }
    func testSeparateChannelsSortChronologicallyAndAreNotClaimedAsSpeakerIdentities() throws {
        var timeline = MeetingTranscriptTimeline()
        try timeline.receive(.init(channel: .meetingAudio, start: 10.25, end: 12, text: "Remote update", isFinal: true))
        try timeline.receive(.init(channel: .microphone, start: 1, end: 2, text: "Local question", isFinal: false))
        XCTAssertEqual(timeline.segments.map(\.channel), [.microphone, .meetingAudio])
        XCTAssertTrue(timeline.text.contains("[00:00:10.250] Meeting audio: Remote update"))
        XCTAssertTrue(timeline.text.contains("Microphone (provisional): Local question"))
    }
    func testInvalidAndOversizedUpdatesLeavePreviouslyCapturedTextIntact() throws {
        var timeline = MeetingTranscriptTimeline()
        try timeline.receive(.init(channel: .microphone, start: 0, end: 1, text: "Keep this", isFinal: true))
        let original = timeline
        for value in [Double.nan, -Double.infinity, -1.0] {
            XCTAssertThrowsError(try timeline.receive(.init(channel: .microphone, start: value, end: 2, text: "Invalid", isFinal: true)))
        }
        XCTAssertThrowsError(try timeline.receive(.init(channel: .microphone, start: 2, end: 1, text: "Invalid", isFinal: true)))
        XCTAssertThrowsError(try timeline.receive(.init(channel: .microphone, start: 2, end: 3, text: String(repeating: "x", count: 12_001), isFinal: true)))
        XCTAssertEqual(timeline, original)
    }
    func testEmptyRevisionRemovesProvisionalTextAndUnicodeIsPreserved() throws {
        var timeline = MeetingTranscriptTimeline()
        try timeline.receive(.init(channel: .microphone, start: 1, end: 2, text: "गलत", isFinal: false))
        try timeline.receive(.init(channel: .microphone, start: 1, end: 2, text: " ", isFinal: false))
        XCTAssertTrue(timeline.segments.isEmpty)
        try timeline.receive(.init(channel: .microphone, start: 3661.5, end: 3663, text: "नमस्ते दुनिया", isFinal: true))
        XCTAssertEqual(timeline.text, "[01:01:01.500] Microphone: नमस्ते दुनिया")
    }
}
