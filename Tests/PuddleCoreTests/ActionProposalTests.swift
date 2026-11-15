import Foundation
import XCTest
@testable import PuddleCore

final class ActionProposalTests: XCTestCase {
    func testReviewBindsExactPayloadAndCannotReplay() throws {
        var action = ActionProposal(account: "me@example.com", payload: .email(MailDraft(to: "you@example.com", subject: "Hello", body: "Draft")))
        let reviewed = action.digest
        action.payload = .email(MailDraft(to: "other@example.com", subject: "Hello", body: "Draft"))
        XCTAssertThrowsError(try action.authorize(digest: reviewed))
        try action.authorize(digest: action.digest)
        XCTAssertEqual(action.status, .dispatching)
        XCTAssertThrowsError(try action.authorize(digest: action.digest))
    }
    func testMIMEPreservesUnicodeAndRejectsHeaderInjection() throws {
        var draft = MailDraft(to: "you@example.com", subject: "नमस्ते", body: "Hello\nनमस्ते", inReplyTo: "<original@example.com>")
        let id = UUID(), encoded = try draft.mime(from: "me@example.com", actionID: id)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("In-Reply-To: <original@example.com>"))
        XCTAssertTrue(text.contains("Message-ID: <puddle-\(id.uuidString.lowercased())@puddle.local>"))
        XCTAssertTrue(text.contains("Content-Transfer-Encoding: base64"))
        draft.subject = "Subject\r\nBcc: attacker@example.com"
        XCTAssertThrowsError(try draft.mime(from: "me@example.com", actionID: id))
    }
    func testCalendarRequiresValidDatesAndVersionForEdits() throws {
        var draft = CalendarDraft(); draft.title = "Review"; draft.end = draft.start.addingTimeInterval(1800)
        _ = try draft.apiBody(actionID: UUID())
        draft.eventID = "existing"; XCTAssertThrowsError(try draft.validate())
        draft.etag = "version"; try draft.validate()
        draft.end = draft.start; XCTAssertThrowsError(try draft.validate())
    }
    func testInterruptedActionsRecoverAndRestoreWithoutReplay() throws {
        var action = ActionProposal(account: "me@example.com", payload: .email(MailDraft(to: "you@example.com", subject: "Hello", body: "Draft")))
        try action.authorize(digest: action.digest)
        var snapshot = AppSnapshot(); snapshot.actionProposals = [action]
        let backup = try WorkspaceBackup.inspect(WorkspaceBackup.encode(snapshot))
        XCTAssertEqual(backup.actionsCount, 1)
        let (restored, report) = WorkspaceBackup.merging(backup, into: AppSnapshot())
        XCTAssertEqual(report.actionsAdded, 1); XCTAssertEqual(restored.actionProposals[0].status, .uncertain)
        XCTAssertNil(restored.actionProposals[0].authorizedDigest)
        snapshot.recoverInterruptedActions(); XCTAssertEqual(snapshot.actionProposals[0].status, .uncertain)
        let (again, _) = WorkspaceBackup.merging(backup, into: restored)
        XCTAssertEqual(again.actionProposals.count, 1)
    }
    func testWriteScopesImplyReadButReadDoesNotGrantWrites() {
        XCTAssertTrue(OAuthFlow.expandedScopes([OAuthFlow.mailModifyScope]).contains(OAuthFlow.scope))
        XCTAssertTrue(OAuthFlow.expandedScopes([OAuthFlow.calendarWriteScope]).contains(OAuthFlow.calendarScope))
        XCTAssertFalse(OAuthFlow.expandedScopes([OAuthFlow.scope]).contains(OAuthFlow.mailSendScope))
    }
    func testResolvedActionReceiptsAreBoundedWithoutDroppingDraftsOrUncertainWrites() {
        var snapshot = AppSnapshot()
        let base = Date(timeIntervalSince1970: 1_000_000)
        snapshot.actionProposals = (0..<800).map { index in
            var action = ActionProposal(account: "me@example.com", payload: .calendar(CalendarDraft()))
            action.createdAt = base.addingTimeInterval(Double(index))
            switch index % 4 {
            case 0: action.status = .draft
            case 1: action.status = .uncertain
            case 2: action.status = .completed; action.completedAt = action.createdAt
            default: action.status = .declined; action.completedAt = action.createdAt
            }
            return action
        }
        let drafts = snapshot.actionProposals.filter { $0.status == .draft }.map(\.id)
        let uncertain = snapshot.actionProposals.filter { $0.status == .uncertain }.map(\.id)
        let oldestResolved = snapshot.actionProposals.first { $0.status == .completed && $0.createdAt == base.addingTimeInterval(2) }
        XCTAssertNotNil(oldestResolved)
        snapshot.pruneResolvedActions(maximumResolved: 300)
        XCTAssertEqual(snapshot.actionProposals.filter { $0.status == .draft }.map(\.id), drafts)
        XCTAssertEqual(snapshot.actionProposals.filter { $0.status == .uncertain }.map(\.id), uncertain)
        XCTAssertEqual(snapshot.actionProposals.filter { $0.status == .completed || $0.status == .declined }.count, 300)
        XCTAssertFalse(snapshot.actionProposals.contains { $0.id == oldestResolved?.id }, "The oldest resolved receipt is dropped first")
    }
}
