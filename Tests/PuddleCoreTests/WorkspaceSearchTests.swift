import Foundation
import XCTest
@testable import PuddleCore

final class WorkspaceSearchTests: XCTestCase {
    func testSearchFindsLateMessagesAndCombinedFieldsWithoutJoiningWholeHistories() {
        var state = AppSnapshot()
        state.conversations = [Conversation(lines: (0..<5000).map { ChatLine(role: "user", content: "message \($0)") })]
        state.conversations[0].lines[4999].content = "café 日本語 final evidence"
        var task = AssistantTask(title: "Release"); task.owner = "Alex"; task.notes = "Approval"
        state.tasks = [task]
        XCTAssertEqual(WorkspaceSearch.search("Release Alex Approval", in: state).first?.kind, .task)
        let found = WorkspaceSearch.search("日本語 evidence", in: state)
        XCTAssertEqual(found.count, 1); XCTAssertEqual(found.first?.kind, .conversation)
        XCTAssertTrue(found.first?.preview.contains("日本語") == true)
    }
    func testSaturatedSearchIsBoundedAndCooperativeCancellationStopsWork() async throws {
        var state = AppSnapshot(); state.tasks = (0..<5000).map { AssistantTask(title: "Synthetic task \($0)") }
        XCTAssertEqual(WorkspaceSearch.search("Synthetic", in: state).count, 80)
        let snapshot = state
        let task = Task.detached { () -> [WorkspaceSearchResult] in
            while !Task.isCancelled { await Task.yield() }
            return WorkspaceSearch.search("Synthetic", in: snapshot)
        }
        task.cancel(); let found = await task.value; XCTAssertTrue(found.isEmpty)
    }
    func testConversationTermsCanMatchSeparateMessagesAndTheTitle() {
        var state = AppSnapshot()
        state.conversations = [Conversation(lines: [
            ChatLine(role: "user", content: "alpha on the first line"),
            ChatLine(role: "assistant", content: "beta on a later line"),
        ])]
        XCTAssertEqual(WorkspaceSearch.search("alpha beta", in: state).count, 1)
        XCTAssertEqual(WorkspaceSearch.search("beta missing", in: state).count, 0)
        state.conversations[0].lines[0].content = "Quarterly plan"
        XCTAssertEqual(WorkspaceSearch.search("plan beta", in: state).first?.kind, .conversation)
    }
    func testConversationScanIsBoundedWithoutCopyingTheWholeHistory() {
        var state = AppSnapshot()
        state.conversations = (0..<200).map { index in
            Conversation(lines: (0..<600).map { line in ChatLine(role: "user", content: "Conversation \(index) line \(line)") })
        }
        XCTAssertEqual(WorkspaceSearch.search("Conversation", in: state).count, 80)
        XCTAssertTrue(WorkspaceSearch.search("never-present-token", in: state).isEmpty)
        state.conversations[199].lines[599].content += " late-unique-sentinel"
        let last = WorkspaceSearch.search("late-unique-sentinel", in: state)
        XCTAssertEqual(last.count, 1)
        XCTAssertEqual(last.first?.locator, state.conversations[199].id.uuidString)
    }
}
