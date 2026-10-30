import Foundation
import XCTest
@testable import PuddleCore

private actor CleanupChrome: ChromeCommanding {
    enum Mode: CaseIterable { case emptyCloseReply, alreadyClosed, stillOpen, malformedListing, disconnectedListing, delayedClosure }
    let mode: Mode
    var calls: [String] = []
    var closed = 0
    var targetOpen = false
    var closeAttempts = 0
    var checks = 0
    var holdCreation = false
    var creationGate: CheckedContinuation<Void, Never>?
    var navigationError = false
    var creationError = false
    init(_ mode: Mode = .emptyCloseReply) { self.mode = mode }
    func pauseCreation() { holdCreation = true }
    func resumeCreation() { creationGate?.resume(); creationGate = nil }
    func failNavigation() { navigationError = true }
    func failCreation() { creationError = true }
    func command(_ method: String, parameters: Data, sessionID: String?) async throws -> Data {
        try Task.checkCancellation(); calls.append(method)
        switch method {
        case "Target.getTargets":
            if closeAttempts > 0 {
                checks += 1
                if mode == .disconnectedListing { throw PuddleError("Fixture disconnected") }
                if mode == .malformedListing { return Data("{}".utf8) }
                if mode == .delayedClosure && checks >= 2 { targetOpen = false }
            }
            var targets: [[String: Any]] = [["targetId": "unrelated-tab", "type": "page", "url": "https://example.test/"]]
            if targetOpen { targets.append(["targetId": "owned", "type": "page"]) }
            return try ChromeJSON.data(["targetInfos": targets])
        case "Target.createTarget":
            if holdCreation { await withCheckedContinuation { creationGate = $0 } }
            if creationError { throw PuddleError("Fixture lost the creation reply") }
            targetOpen = true; return try ChromeJSON.data(["targetId": "owned"])
        case "Target.attachToTarget": return try ChromeJSON.data(["sessionId": "owned-session"])
        case "Page.navigate": return try ChromeJSON.data(navigationError ? ["errorText": "net::ERR_BLOCKED_BY_CLIENT"] : [:])
        case "Target.closeTarget":
            XCTAssertEqual(try ChromeJSON.object(parameters)["targetId"] as? String, "owned")
            XCTAssertNil(sessionID)
            closeAttempts += 1
            if mode != .stillOpen && mode != .delayedClosure { targetOpen = false }
            if mode == .alreadyClosed { throw ChromeProtocolError(method: method, code: -32602, reason: "No target with given id found") }
            return try ChromeJSON.data(mode == .emptyCloseReply ? [:] : ["success": true])
        default: return Data("{}".utf8)
        }
    }
    func close() { closed += 1 }
}

final class GoogleMeetCleanupTests: XCTestCase {
    private func link() throws -> MeetingJoinLink { try MeetingJoinLink("https://meet.google.com/abc-defg-hij") }
    func testMissingDeprecatedFieldOrAlreadyClosedTargetSucceedsOnlyAfterFreshAbsenceCheck() async throws {
        for mode in [CleanupChrome.Mode.emptyCloseReply, .alreadyClosed, .delayedClosure] {
            let chrome = CleanupChrome(mode), session: GoogleMeetBrowserSession
            session = GoogleMeetBrowserSession(connection: chrome)
            try await session.open(link: link())
            let verified = await session.leave()
            XCTAssertTrue(verified)
            let calls = await chrome.calls
            XCTAssertEqual(calls.last, "Target.getTargets")
            let owned = await session.hasOwnedTarget; XCTAssertFalse(owned)
        }
    }
    func testSuccessReplyIsInsufficientWhenTargetRemainsOrFreshEvidenceIsUnavailable() async throws {
        for mode in [CleanupChrome.Mode.stillOpen, .malformedListing, .disconnectedListing] {
            let chrome = CleanupChrome(mode)
            let session = GoogleMeetBrowserSession(connection: chrome)
            try await session.open(link: link())
            let verified = await session.leave(); XCTAssertFalse(verified)
            let closed = await chrome.closed; XCTAssertEqual(closed, 1)
            let owned = await session.hasOwnedTarget; XCTAssertTrue(owned)
        }
    }
    func testConcurrentLeaveUsesOneCleanupAndCannotReportSuccessFromClearedIdentity() async throws {
        let chrome = CleanupChrome(.stillOpen)
        let session = GoogleMeetBrowserSession(connection: chrome)
        try await session.open(link: link())
        async let first = session.leave()
        async let second = session.leave()
        let results = await [first, second]
        XCTAssertEqual(results, [false, false])
        let attempts = await chrome.closeAttempts; XCTAssertEqual(attempts, 1)
    }
    func testCancellationWhileCreatingTabWaitsForIdentityAndClosesItWithoutNavigating() async throws {
        let chrome = CleanupChrome(); await chrome.pauseCreation()
        let session = GoogleMeetBrowserSession(connection: chrome)
        let opening = Task { try await session.open(link: link()) }
        for _ in 0..<300 {
            if await chrome.creationGate != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let waiting = await chrome.creationGate != nil; XCTAssertTrue(waiting)
        opening.cancel()
        let leaving = Task { await session.leave() }
        await chrome.resumeCreation()
        do { try await opening.value; XCTFail("Expected cancelled opening") } catch { XCTAssertTrue(error is CancellationError) }
        let verified = await leaving.value; XCTAssertTrue(verified)
        let calls = await chrome.calls
        XCTAssertFalse(calls.contains("Page.navigate")); XCTAssertFalse(calls.contains("Target.attachToTarget"))
        XCTAssertEqual(calls.filter { $0 == "Target.closeTarget" }.count, 1)
    }
    func testLostCreationReplyStaysUncertainInsteadOfClaimingNoTabOpened() async throws {
        let chrome = CleanupChrome(); await chrome.failCreation()
        let session = GoogleMeetBrowserSession(connection: chrome)
        do { try await session.open(link: link()); XCTFail("Expected lost reply") } catch {}
        let verified = await session.leave(); XCTAssertFalse(verified)
        let calls = await chrome.calls; XCTAssertFalse(calls.contains("Target.closeTarget"))
    }
    func testNavigationFailureIsReportedAndOwnedTabCanBeVerifiedClosed() async throws {
        let chrome = CleanupChrome(); await chrome.failNavigation()
        let session = GoogleMeetBrowserSession(connection: chrome)
        do { try await session.open(link: link()); XCTFail("Expected navigation error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("net::ERR_BLOCKED_BY_CLIENT")) }
        let verified = await session.leave(); XCTAssertTrue(verified)
    }
}
