import Foundation
import XCTest
@testable import PuddleCore

final class ConversationHistoryTests: XCTestCase {
    func testConciseBrowserRequestKeepsItsFullContextAcrossArchiveAndBackup() throws {
        var line = ChatLine(role: "user", content: "Full reference: exact-current-ref and untrusted page context")
        line.kind = "external-reference"; line.displayText = "Summarize this page"
        var state = AppSnapshot(); state.chat = [line]
        state.startNewConversation()
        XCTAssertEqual(state.conversations.first?.title, "Summarize this page")
        let preview = try WorkspaceBackup.inspect(WorkspaceBackup.encode(state))
        let restored = WorkspaceBackup.merging(preview, into: AppSnapshot()).0
        let saved = try XCTUnwrap(restored.conversations.first?.lines.first)
        XCTAssertEqual(saved.visibleText, "Summarize this page")
        XCTAssertEqual(saved.content, line.content); XCTAssertEqual(saved.kind, "external-reference")
        let old = ChatLine(role: "user", content: "An older conversation")
        XCTAssertEqual(try JSONDecoder().decode(ChatLine.self, from: JSONEncoder().encode(old)).visibleText, old.content)
        line.displayText = String(repeating: "x", count: 4001)
        state.conversations[0].lines = [line]
        XCTAssertThrowsError(try WorkspaceBackup.inspect(WorkspaceBackup.encode(state)))
    }
    func testLegacyActiveTranscriptAppearsWithoutBeingArchived() throws {
        let message = ChatLine(role: "user", content: "Plan a weekend trip")
        let object: [String: Any] = ["chat": try JSONSerialization.jsonObject(with: JSONEncoder().encode([message])), "conversations": []]
        let data = try JSONSerialization.data(withJSONObject: object)
        let first = try JSONDecoder().decode(AppSnapshot.self, from: data)
        let second = try JSONDecoder().decode(AppSnapshot.self, from: data)
        XCTAssertTrue(first.conversations.isEmpty)
        XCTAssertEqual(first.conversationHistory.map(\.title), ["Plan a weekend trip"])
        XCTAssertEqual(first.currentConversationID, message.id)
        XCTAssertEqual(second.currentConversationID, first.currentConversationID)
        let restarted = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(restarted.conversationHistory, first.conversationHistory)
    }

    func testSearchIncludesCurrentAndArchivedMessageContents() {
        var state = AppSnapshot()
        state.chat = [ChatLine(role: "user", content: "Archived discussion"), ChatLine(role: "assistant", content: "Visit the museum")]
        let archivedID = state.currentConversationID
        state.startNewConversation()
        state.chat = [ChatLine(role: "user", content: "Current project planning")]
        XCTAssertEqual(state.conversationHistory.map(\.id), [state.currentConversationID, archivedID])
        XCTAssertEqual(state.matchingConversations("  PLANNING  ").first?.id, state.currentConversationID)
        XCTAssertEqual(state.matchingConversations("museum").first?.id, archivedID)
        XCTAssertTrue(state.matchingConversations("unmatched text").isEmpty)
        XCTAssertEqual(state.matchingConversations("  ").count, 2)
    }

    func testSwitchingAndRestartKeepStableIdentitiesWithoutDuplicates() throws {
        var state = AppSnapshot()
        state.chat = [ChatLine(role: "user", content: "First discussion")]
        let firstID = state.currentConversationID, firstDate = state.currentConversationCreatedAt
        state.startNewConversation()
        state.chat = [ChatLine(role: "user", content: "Second discussion")]
        let secondID = state.currentConversationID
        for _ in 0..<5 {
            state.openConversation(firstID)
            XCTAssertEqual(state.currentConversationID, firstID)
            XCTAssertEqual(state.currentConversationCreatedAt, firstDate)
            state.openConversation(secondID)
            XCTAssertEqual(state.currentConversationID, secondID)
            XCTAssertEqual(Set(state.conversationHistory.map(\.id)), [firstID, secondID])
            XCTAssertEqual(state.conversations.count, 1)
        }
        let restored = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.conversationHistory, state.conversationHistory)
    }

    func testOpeningCurrentDoesNotArchiveOrReplaceItsTranscript() {
        var state = AppSnapshot()
        state.chat = [ChatLine(role: "user", content: "Still active")]
        let id = state.currentConversationID, transcript = state.chat
        state.openConversation(id)
        XCTAssertEqual(state.currentConversationID, id)
        XCTAssertEqual(state.chat, transcript)
        XCTAssertTrue(state.conversations.isEmpty)
    }

    func testDeletingCurrentRetainsArchiveAndDeletingArchiveRetainsCurrent() {
        var state = AppSnapshot()
        state.chat = [ChatLine(role: "user", content: "Keep archived")]
        let archivedID = state.currentConversationID
        state.startNewConversation()
        state.chat = [ChatLine(role: "user", content: "Delete current")]
        let currentID = state.currentConversationID
        state.deleteConversation(currentID)
        XCTAssertTrue(state.chat.isEmpty)
        XCTAssertNotEqual(state.currentConversationID, currentID)
        XCTAssertEqual(state.conversationHistory.map(\.id), [archivedID])
        state.chat = [ChatLine(role: "user", content: "Keep current")]
        state.deleteConversation(archivedID)
        XCTAssertEqual(state.chat.first?.content, "Keep current")
        XCTAssertEqual(state.conversationHistory.count, 1)
        XCTAssertTrue(state.conversations.isEmpty)
    }
}
