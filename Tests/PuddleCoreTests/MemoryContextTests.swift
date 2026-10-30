import Foundation
import XCTest
@testable import PuddleCore

final class MemoryContextTests: XCTestCase {
    func testThousandsOfMemoriesRemainQueryableWithoutDumpingThemIntoAToolReply() throws {
        let memories = (0..<5000).map { MemoryNote(title: "Preference \($0)", content: "Saved synthetic detail \($0)") }
        let all = try MemoryContext.encode(query: "", memories: memories)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(all.utf8)) as? [String: Any])
        XCTAssertEqual(object["total_matches"] as? Int, 5000)
        XCTAssertEqual(object["has_more"] as? Bool, true)
        XCTAssertLessThanOrEqual((object["memories"] as? [Any])?.count ?? 999, 20)
        let exact = try MemoryContext.encode(query: "detail 4999", memories: memories)
        let found = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(exact.utf8)) as? [String: Any])
        XCTAssertEqual(found["total_matches"] as? Int, 1)
        XCTAssertTrue(exact.contains("Saved synthetic detail 4999"))
    }
    func testUnicodeExcerptsStayValidJSONWithinTheActualRemainingContextBudget() throws {
        let text = try MemoryContext.encode(query: "", memories: [MemoryNote(title: "Long preference", content: String(repeating: "日本語", count: 1000))])
        let shortened = try XCTUnwrap(MemoryContext.fitting(text, characters: 1000, tokens: 500))
        XCTAssertLessThanOrEqual(shortened.count, 1000); XCTAssertLessThanOrEqual(PromptBudget.tokens(shortened), 500)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(shortened.utf8)) as? [String: Any])
        XCTAssertEqual(object["total_matches"] as? Int, 1)
        let notes = try XCTUnwrap(object["memories"] as? [[String: Any]])
        XCTAssertTrue(notes.isEmpty || notes[0]["content_truncated"] as? Bool == true)
        XCTAssertFalse(shortened.contains("[Tool result shortened]"))
    }
    func testMemorySearchMatchesTitleContentAndEvidenceAcrossTerms() {
        var snapshot = AppSnapshot()
        snapshot.memories = [MemoryNote(title: "Response style", content: "Concise", source: "I prefer concise answers"), MemoryNote(title: "Other", content: "Coffee")]
        XCTAssertEqual(snapshot.matchingMemories("style answers").map(\.title), ["Response style"])
        XCTAssertTrue(snapshot.matchingMemories("missing").isEmpty)
        XCTAssertEqual(snapshot.matchingMemories("  ").count, 2)
    }
    func testIdentityBeyondThousandsOfRecentMemoriesSurvivesSmallPromptBudget() {
        var memories = [MemoryNote(title: "Your name", content: "Older Identity")]
        memories += (0..<5000).map { MemoryNote(title: "Preference \($0)", content: String(repeating: "Recent detail ", count: 100)) }
        let prompt = AgentContext(memories: memories).prompt(memoryBudget: 1024)
        XCTAssertTrue(prompt.contains("Older Identity"))
        XCTAssertLessThan(prompt.count, 15_000)
    }
}
