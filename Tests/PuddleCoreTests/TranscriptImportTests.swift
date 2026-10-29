import Foundation
import XCTest
@testable import PuddleCore

final class TranscriptImportTests: XCTestCase {
    func testUTF8AndUTF16TranscriptsKeepUnicodeAndNormalizeLineEndings() throws {
        let utf8 = try TranscriptImport.decode(Data("\u{FEFF}Hello café\r\nSecond line".utf8), filename: "notes.txt")
        XCTAssertEqual(utf8.text, "Hello café\nSecond line"); XCTAssertEqual(utf8.format, .text)
        let text = "Meeting: നമസ്കാരം"
        var data = Data([0xff, 0xfe]); data.append(try XCTUnwrap(text.data(using: .utf16LittleEndian)))
        XCTAssertEqual(try TranscriptImport.decode(data, filename: "notes.md").text, text)
    }

    func testWebVTTPreservesTimestampsAndSpeakerNames() throws {
        let content = """
        WEBVTT

        NOTE Private cue metadata is not speech

        00:00:01.000 --> 00:00:03.000
        <v Mira>We agreed to <b>ship</b> Friday.</v>
         
        00:00:03.000 --> 00:00:05.000 align:start
        <v Li>I will write the tests.</v>
        """
        let result = try TranscriptImport.decode(Data(content.utf8), filename: "captions.vtt")
        XCTAssertEqual(result.cueCount, 2)
        XCTAssertTrue(result.text.contains("[00:00:01.000] Mira: We agreed to ship Friday."))
        XCTAssertTrue(result.text.contains("Li: I will write the tests."))
        XCTAssertFalse(result.text.contains("Private cue")); XCTAssertFalse(result.text.contains("align:start"))
    }

    func testSubRipRemovesCueNumbersAndConvertsCommaTimestamps() throws {
        let source = "1\n00:00:01,500 --> 00:00:04,000\nFirst sentence.\n\n2\n00:00:04,000 --> 00:00:06,000\nSecond &amp; final."
        let result = try TranscriptImport.decode(Data(source.utf8), filename: "meeting.srt")
        XCTAssertEqual(result.text, "[00:00:01.500] First sentence.\n[00:00:04.000] Second & final.")
        XCTAssertEqual(result.cueCount, 2)
    }

    func testUnreadableEmptyUnsupportedAndOversizedInputsAreRejected() {
        XCTAssertThrowsError(try TranscriptImport.decode(Data(), filename: "empty.txt"))
        XCTAssertThrowsError(try TranscriptImport.decode(Data([0, 1, 2]), filename: "binary.txt"))
        XCTAssertThrowsError(try TranscriptImport.decode(Data("hello".utf8), filename: "document.pdf"))
        XCTAssertThrowsError(try TranscriptImport.decode(Data("not captions".utf8), filename: "bad.srt"))
        XCTAssertThrowsError(try TranscriptImport.decode(Data(repeating: 65, count: TranscriptImport.maximumBytes + 1), filename: "large.txt"))
        XCTAssertThrowsError(try TranscriptImport.decode(Data(repeating: 65, count: TranscriptImport.maximumCharacters + 1), filename: "long.txt"))
    }

    func testFileReaderBoundsActualBytesAndRejectsDirectories() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture.txt")
        try Data("A local transcript".utf8).write(to: file)
        XCTAssertEqual(try TranscriptImport.read(from: file).text, "A local transcript")
        try Data(repeating: 65, count: TranscriptImport.maximumBytes + 50).write(to: file)
        XCTAssertThrowsError(try TranscriptImport.read(from: file))
        XCTAssertThrowsError(try TranscriptImport.read(from: directory))
    }
}
