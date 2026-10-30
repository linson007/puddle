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
}
