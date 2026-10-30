import Foundation
import XCTest
@testable import PuddleCore

final class LocalKnowledgeTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testIndexingUpdatesChangesRemovesDeletedFilesAndSkipsSymlinks() throws {
        let folder = try folder(), file = folder.appendingPathComponent("plan.txt")
        try Data("Launch review is Monday.\nUse the blue design.".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked.txt"), withDestinationURL: file)
        let source = try KnowledgeSource(url: folder), first = try LocalKnowledge.refresh(source, previous: [])
        XCTAssertEqual(first.1.count, 1)
        let matches = LocalKnowledge.search("blue design", documents: first.1)
        XCTAssertEqual(matches.count, 1); XCTAssertEqual(matches[0].url.resolvingSymlinksInPath(), file.resolvingSymlinksInPath())
        try Data("Changed launch plan: Tuesday now.".utf8).write(to: file)
        let next = try LocalKnowledge.refresh(source, previous: first.1)
        XCTAssertEqual(next.1[0].id, first.1[0].id); XCTAssertNotEqual(next.1[0].sha256, first.1[0].sha256)
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(try LocalKnowledge.refresh(source, previous: next.1).1.isEmpty)
    }
    func testExtractionIsBoundedAndHTMLDoesNotLoadScriptsOrImages() throws {
        let folder = try folder(), html = folder.appendingPathComponent("example.html")
        try Data("<p>Visible text</p><script>secret script</script><img src='https://tracker.example/pixel'>".utf8).write(to: html)
        XCTAssertEqual(try LocalKnowledge.extract(html).0, "Visible text")
        let text = folder.appendingPathComponent("long.txt"); try Data(String(repeating: "a", count: 210_000).utf8).write(to: text)
        let extracted = try LocalKnowledge.extract(text); XCTAssertEqual(extracted.0.count, 200_000); XCTAssertTrue(extracted.1)
    }
    func testWorkRecordsValidateAndMailAttentionHasExplicitReasons() throws {
        var person = PersonContext(); person.name = "Maya"; person.email = "maya@example.com"; person.isVIP = true
        _ = try person.validated()
        let mail = MailMessage(id: "fixture", subject: "Review", sender: "Maya <maya@example.com>", body: "Hello", labels: ["UNREAD"])
        let attention = MailAttention.assess(mail, people: [person]); XCTAssertEqual(attention.rank, 5); XCTAssertTrue(attention.reasons.contains("VIP sender: Maya"))
        var decision = WorkDecision(); decision.title = "Pick design"; decision.status = .decided
        XCTAssertThrowsError(try decision.validated()); decision.rationale = "Matches the agreed brief"; _ = try decision.validated()
    }
}
