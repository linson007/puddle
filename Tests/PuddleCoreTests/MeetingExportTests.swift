import Foundation
import XCTest
@testable import PuddleCore

final class MeetingExportTests: XCTestCase {
    private func note() throws -> MeetingNote {
        var note = MeetingNote(title: "Planning review", joinLink: try MeetingJoinLink("https://zoom.us/j/123456789?pwd=fixture-passcode"))
        note.participants = "Mira, Li"; note.agenda = "Readiness"; note.notes = "Keep the first version small."
        note.transcript = "Li: I will send the report by Friday."
        note.summary = MeetingSummary(model: "fixture", sourceDigest: MeetingSummary.digest(notes: note.notes, transcript: note.transcript),
            decisions: [MeetingExcerpt(quote: "Keep the first version small.")], actions: [MeetingAction(quote: note.transcript, owner: "Li", timing: "Friday")])
        return note
    }
    func testJsonExportContainsCurrentDraftAndExcludesJoinLinkByDefault() throws {
        let original = try note(); var draft = MeetingDraft(original); draft.notes = "Unsaved correction"
        let data = try MeetingExport.data(note: original, draft: draft, format: .json)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(MeetingExportDocument.self, from: data)
        XCTAssertEqual(document.exportVersion, 1); XCTAssertTrue(document.includesUnsavedEdits)
        XCTAssertEqual(document.note.notes, "Unsaved correction"); XCTAssertEqual(document.note.id, original.id)
        XCTAssertNil(document.note.joinLink); XCTAssertEqual(document.summarySourceStatus, "out of date")
        XCTAssertEqual(document.note.summary?.actions[0].owner, "Li")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fixture-passcode"))
        XCTAssertEqual(original.notes, "Keep the first version small.")
    }
    func testTranscriptExclusionRetainsSummaryQuotesAndExplicitLinkChoice() throws {
        let original = try note()
        let data = try MeetingExport.data(note: original, format: .json, includeTranscript: false, includeJoinLink: true)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(MeetingExportDocument.self, from: data)
        XCTAssertTrue(document.note.transcript.isEmpty); XCTAssertFalse(document.includesFullTranscript)
        XCTAssertEqual(document.note.summary?.actions[0].quote, original.transcript)
        XCTAssertEqual(document.note.joinLink, original.joinLink); XCTAssertEqual(document.summarySourceStatus, "current")
        let transcript = try MeetingExport.data(note: original, format: .transcript)
        XCTAssertEqual(String(decoding: transcript, as: UTF8.self), original.transcript)
    }
    func testMarkdownEscapesReferenceTextAndUsesUnbreakableTranscriptFence() throws {
        var note = try note(); note.title = "A [link](https://example.test)"
        note.notes = "![remote image](https://example.test/pixel)\n# Injected heading"
        note.transcript = "````\n![another image](https://example.test/image)\n````"
        let markdown = String(decoding: try MeetingExport.data(note: note, format: .markdown), as: UTF8.self)
        XCTAssertTrue(markdown.contains("\\!\\[remote image\\]"))
        XCTAssertTrue(markdown.contains("\\# Injected heading"))
        XCTAssertTrue(markdown.contains("`````text\n" + note.transcript + "\n`````"))
        XCTAssertFalse(markdown.contains("fixture-passcode"))
    }
    func testPlainTextExportAndFilenameAreSafeForUnicodeAndPathCharacters() throws {
        let text = String(decoding: try MeetingExport.data(note: note(), format: .text, includeTranscript: false), as: UTF8.self)
        XCTAssertTrue(text.contains("Planning review")); XCTAssertTrue(text.contains("Timing: Friday"))
        XCTAssertFalse(text.contains("\nTranscript\n"))
        XCTAssertEqual(MeetingExport.filename(title: "../../नमस्ते/Review: next\u{0}", format: .markdown), "नमस्ते Review  next.md")
        XCTAssertEqual(MeetingExport.filename(title: ".. /\n", format: .json), "Meeting notes.json")
        XCTAssertLessThanOrEqual(MeetingExport.filename(title: String(repeating: "x", count: 1000), format: .text).count, 84)
    }
    func testExportWriteIsAtomicPrivateAndDoesNotMutateSource() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("meeting.txt"), data = try MeetingExport.data(note: note(), format: .text)
        try Data("previous".utf8).write(to: destination)
        try MeetingExport.write(data, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), data)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try MeetingExport.write(data, to: URL(string: "https://example.test/export")!))
        XCTAssertThrowsError(try MeetingExport.write(data, to: folder))
    }
}
