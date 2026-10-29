import Foundation
import JavaScriptCore
import XCTest
@testable import PuddleCore

private actor FixtureChrome: ChromeCommanding {
    struct Call: Sendable { let method: String; let data: Data; let session: String? }
    var calls: [Call] = []; var closed = 0
    let existing: Bool, denyFailure: Bool, closeSuccess: Bool
    init(existing: Bool = false, denyFailure: Bool = false, closeSuccess: Bool = true) {
        self.existing = existing; self.denyFailure = denyFailure; self.closeSuccess = closeSuccess
    }
    func command(_ method: String, parameters: Data, sessionID: String?) async throws -> Data {
        try Task.checkCancellation(); calls.append(Call(method: method, data: parameters, session: sessionID))
        switch method {
        case "Target.getTargets": return try ChromeJSON.data(["targetInfos": existing ? [["type": "page", "url": "https://meet.google.com/abc-defg-hij", "targetId": "previous"]] : []])
        case "Browser.setPermission": if denyFailure { throw PuddleError("Fixture permissions rejected") }; return Data("{}".utf8)
        case "Target.createTarget": return try ChromeJSON.data(["targetId": "owned-target"])
        case "Target.attachToTarget": return try ChromeJSON.data(["sessionId": "owned-session"])
        case "Target.closeTarget": return try ChromeJSON.data(["success": closeSuccess])
        case "Runtime.evaluate": return try ChromeJSON.data(["result": ["value": #"{"stage":"waiting","clickedJoin":true}"#]])
        default: return Data("{}".utf8)
        }
    }
    func close() { closed += 1 }
}

final class GoogleMeetBrowserTests: XCTestCase {
    func testBrowserEndpointIsRestrictedToOwnedLoopbackPortFile() throws {
        let endpoint = try ChromeJSON.endpoint(portFile: "12345\n/devtools/browser/abc12345-6789\n")
        XCTAssertEqual(endpoint.host, "127.0.0.1"); XCTAssertEqual(endpoint.port, 12345)
        for value in ["80\n/devtools/browser/abc12345", "12345\nhttps://example.test", "12345\n/devtools/browser/../other", "12345\n/devtools/browser/abc12345?key=x"] {
            XCTAssertThrowsError(try ChromeJSON.endpoint(portFile: value))
        }
        XCTAssertThrowsError(try ChromeDevTools(endpoint: URL(string: "ws://example.test:12345/devtools/browser/abc12345")!))
    }
    func testMediaPermissionsAreDeniedBeforeNavigationAndOnlyOwnedTabIsClosed() async throws {
        let chrome = FixtureChrome()
        let subject = GoogleMeetBrowserSession(connection: chrome)
        try await subject.open(link: MeetingJoinLink("https://meet.google.com/abc-defg-hij"))
        let state = try await subject.inspect(join: true, guestName: "Puddle notes")
        XCTAssertEqual(state.stage, .waiting)
        let calls = await chrome.calls
        XCTAssertEqual(Array(calls.prefix(4).map(\.method)), ["Target.getTargets", "Browser.setPermission", "Browser.setPermission", "Target.createTarget"])
        for call in calls.filter({ $0.method == "Browser.setPermission" }) {
            XCTAssertEqual(try ChromeJSON.object(call.data)["setting"] as? String, "denied")
        }
        let navigation = try XCTUnwrap(calls.first { $0.method == "Page.navigate" })
        XCTAssertEqual(navigation.session, "owned-session")
        XCTAssertTrue((try ChromeJSON.object(navigation.data)["url"] as? String)?.contains("hl=en") == true)
        let left = await subject.leave(); XCTAssertTrue(left)
        let last = await chrome.calls.last; XCTAssertEqual(last?.method, "Target.closeTarget")
        XCTAssertEqual(try ChromeJSON.object(last!.data)["targetId"] as? String, "owned-target")
    }
    func testExistingMeetTabAndPermissionFailureNeverNavigateOrCloseAnotherTab() async throws {
        for chrome in [FixtureChrome(existing: true), FixtureChrome(denyFailure: true)] {
            let subject = GoogleMeetBrowserSession(connection: chrome)
            do { try await subject.open(link: MeetingJoinLink("https://meet.google.com/abc-defg-hij")); XCTFail("Expected refusal") } catch {}
            _ = await subject.leave()
            let calls = await chrome.calls
            XCTAssertFalse(calls.contains { ["Page.navigate", "Target.createTarget", "Target.closeTarget"].contains($0.method) })
        }
    }
    func testFailedLeaveIsNotReportedAsSuccessAndCancellationStillClosesOwnedTab() async throws {
        let chrome = FixtureChrome(closeSuccess: false)
        let failed = GoogleMeetBrowserSession(connection: chrome)
        try await failed.open(link: MeetingJoinLink("https://meet.google.com/abc-defg-hij"))
        let left = await failed.leave(); XCTAssertFalse(left)
        let working = FixtureChrome()
        let owned = GoogleMeetBrowserSession(connection: working)
        try await owned.open(link: MeetingJoinLink("https://meet.google.com/abc-defg-hij"))
        let task = Task { await owned.leave() }; task.cancel()
        let cancelledLeft = await task.value; XCTAssertTrue(cancelledLeft)
    }
    private func evaluate(host: String = "meet.google.com", body: String = "Ready to join?", buttons: [String], join: Bool) throws -> (GoogleMeetPageState, [String]) {
        let context = try XCTUnwrap(JSContext())
        let fixture = String(decoding: try ChromeJSON.data(["host": host, "body": body, "buttons": buttons]), as: UTF8.self)
        context.evaluateScript("""
        var fixture = \(fixture); var clicked = [];
        var location = {hostname: fixture.host, protocol: 'https:'};
        var getComputedStyle = () => ({visibility: 'visible'});
        var nodes = fixture.buttons.map(text => ({textContent: text, disabled: false,
          getClientRects: () => [1], getAttribute: key => key === 'aria-label' ? text : null, click: () => clicked.push(text)}));
        var document = {body: {innerText: fixture.body}, querySelectorAll: selector => selector === 'input' ? [] : nodes};
        """)
        let value = try XCTUnwrap(context.evaluateScript(GoogleMeetPage.script(join: join, guestName: "Name \"; throw Error('injected')")))
        XCTAssertNil(context.exception)
        let state = try JSONDecoder().decode(GoogleMeetPageState.self, from: Data(value.toString().utf8))
        return (state, context.objectForKeyedSubscript("clicked").toArray() as? [String] ?? [])
    }
    func testPageRulesInspectWithoutClickingAndRequireExplicitJoinMode() throws {
        let preview = try evaluate(buttons: ["Join now"], join: false)
        XCTAssertEqual(preview.0.stage, .prejoin); XCTAssertTrue(preview.1.isEmpty)
        let joining = try evaluate(buttons: ["Ask to join"], join: true)
        XCTAssertTrue(joining.0.clickedJoin); XCTAssertEqual(joining.1, ["Ask to join"])
        let joined = try evaluate(buttons: ["Leave call", "Join now"], join: true)
        XCTAssertEqual(joined.0.stage, .joined); XCTAssertTrue(joined.1.isEmpty)
    }
    func testPageRulesNeverClickSignInOrUnknownOriginsAndDistinguishWaitingFromJoined() throws {
        XCTAssertEqual(try evaluate(host: "accounts.google.com", buttons: ["Join now"], join: true).0.stage, .signIn)
        let other = try evaluate(host: "example.test", buttons: ["Join now"], join: true)
        XCTAssertEqual(other.0.stage, .unsupported); XCTAssertTrue(other.1.isEmpty)
        XCTAssertEqual(try evaluate(body: "Asking to join", buttons: [], join: true).0.stage, .waiting)
        XCTAssertEqual(try evaluate(body: "You were removed", buttons: [], join: false).0.stage, .ended)
        let signIn = try evaluate(body: "Sign in to continue", buttons: ["Sign in"], join: true)
        XCTAssertEqual(signIn.0.stage, .signIn); XCTAssertTrue(signIn.1.isEmpty)
    }
}
