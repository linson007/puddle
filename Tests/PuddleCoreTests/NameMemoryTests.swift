import Foundation
import XCTest
@testable import PuddleCore

final class NameMemoryTests: XCTestCase {
    func testIntroductionsProduceANameProposalWithoutRequiringRemember() {
        for (message, name) in [
            ("My name is Mira", "Mira"),
            ("my name is Mira Rao.", "Mira Rao"),
            ("Hello, my name is Mira!", "Mira"),
            ("Please call me Jean-Luc", "Jean-Luc"),
            ("Remember that my name is O’Connor", "O’Connor"),
            ("My name is Mira, please remember it.", "Mira"),
            ("My preferred name: Élodie", "Élodie"),
            ("My name is actually അനു", "അനു"),
        ] {
            XCTAssertEqual(NameMemoryProposal.from(message)?.name, name, message)
        }
    }

    func testQuestionsNegationsQuotesAndOtherRequestsDoNotProposeAnIdentity() {
        for message in [
            "What is my name?", "My name is not John", "Call me later",
            "Call me at five", "Don't remember my name is Mira",
            "Write a story where my name is Mira", "\"My name is Mira\"",
            "My name is a secret", "My name is Mira and I work in design",
            "My name is password123", "My name is Mira?",
        ] {
            XCTAssertNil(NameMemoryProposal.from(message), message)
        }
    }

    func testKnownNamesAreNotProposedAgainAndCorrectionsUpdateTheSameNote() throws {
        var state = AppSnapshot()
        state.remember(title: NameMemoryProposal.title, content: "Mira")
        let id = state.memories[0].id
        XCTAssertNil(NameMemoryProposal.from("My name is mira.", memories: state.memories))
        let corrected = try XCTUnwrap(NameMemoryProposal.from("Call me Élodie", memories: state.memories))
        state.remember(title: NameMemoryProposal.title, content: corrected.name)
        XCTAssertEqual(state.memories.count, 1)
        XCTAssertEqual(state.memories[0].id, id)
        XCTAssertEqual(state.memories[0].content, "Élodie")
    }

    func testNewConversationAndRestartRetainTheNameAndOtherDurableState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SnapshotStore(directory: directory)
        var state = AppSnapshot()
        let proposal = try XCTUnwrap(NameMemoryProposal.from("My name is Mira"))
        state.remember(title: NameMemoryProposal.title, content: proposal.name)
        state.chat = [ChatLine(role: "user", content: "My name is Mira")]
        state.tasks = [AssistantTask(title: "Review draft")]
        try cache.save(state)
        state.startNewConversation()
        try cache.save(state)
        let restored = try cache.load()
        XCTAssertTrue(restored.chat.isEmpty)
        XCTAssertEqual(restored.memories.first?.content, "Mira")
        XCTAssertEqual(restored.tasks.first?.title, "Review draft")
        XCTAssertTrue(AgentContext(memories: restored.memories).systemPrompt.contains("Mira"))
    }

    func testNameIsIncludedEvenWhenOlderThanThePromptMemoryLimit() {
        var name = MemoryNote(title: NameMemoryProposal.title, content: "Mira Rao")
        name.updatedAt = .distantPast
        let otherNotes = (0..<50).map { MemoryNote(title: "Fact \($0)", content: String(repeating: "x", count: 1000)) }
        let prompt = AgentContext(memories: otherNotes + [name]).systemPrompt
        XCTAssertTrue(prompt.contains("Mira Rao"))
        XCTAssertLessThan(prompt.count, 18_000)
    }
}
