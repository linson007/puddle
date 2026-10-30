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
}
