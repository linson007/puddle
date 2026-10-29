import Foundation
import XCTest
import PuddleCore
@testable import Puddle

private actor AttendanceChrome: ChromeCommanding {
    var stage = GoogleMeetPageState.Stage.waiting
    var calls: [String] = []
    var closed = 0
    let closeSucceeds: Bool
    init(closeSucceeds: Bool = true) { self.closeSucceeds = closeSucceeds }
    func setStage(_ stage: GoogleMeetPageState.Stage) { self.stage = stage }
    func command(_ method: String, parameters: Data, sessionID: String?) async throws -> Data {
        try Task.checkCancellation(); calls.append(method)
        switch method {
        case "Target.getTargets": return try ChromeJSON.data(["targetInfos": []])
        case "Target.createTarget": return try ChromeJSON.data(["targetId": "test-meet-tab"])
        case "Target.attachToTarget": return try ChromeJSON.data(["sessionId": "test-session"])
        case "Target.closeTarget": return try ChromeJSON.data(["success": closeSucceeds])
        case "Runtime.evaluate": return try ChromeJSON.data(["result": ["value": String(decoding: JSONEncoder().encode(GoogleMeetPageState(stage: stage)), as: UTF8.self)]])
        default: return Data("{}".utf8)
        }
    }
    func close() { closed += 1 }
}
@MainActor private final class AttendanceLauncher: MeetBrowserLaunching {
    let chrome: AttendanceChrome
    var hold = false
    var calls = 0
    var gate: CheckedContinuation<Void, Never>?
    init(_ chrome: AttendanceChrome) { self.chrome = chrome }
    func connect() async throws -> any ChromeCommanding {
        calls += 1
        if hold { await withCheckedContinuation { gate = $0 } }
        return chrome
    }
}

@MainActor final class MeetAttendanceTests: XCTestCase {
    private func wait(_ predicate: () -> Bool) async {
        for _ in 0..<300 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(2)) }
        XCTFail("Attendance fixture did not reach the expected state")
    }
    private func link() throws -> MeetingJoinLink { try MeetingJoinLink("https://meet.google.com/abc-defg-hij") }
    func testAdmissionWaitIsNotJoinedAndLeaveClosesOnlyManagedTarget() async throws {
        let chrome = AttendanceChrome()
        let subject = MeetAttendanceController(launcher: AttendanceLauncher(chrome), pollSeconds: 0.005)
        subject.join(link: try link(), noteID: UUID(), guestName: "Fixture notes")
        await wait { subject.status == .waiting }
        XCTAssertNil(subject.joinedAt); XCTAssertTrue(subject.mayStillBeInCall)
        await chrome.setStage(.joined); await wait { subject.status == .joined }
        XCTAssertNotNil(subject.joinedAt)
        let left = await subject.leaveAndWait(); XCTAssertTrue(left); XCTAssertEqual(subject.status, .ended)
        let calls = await chrome.calls; XCTAssertEqual(calls.filter { $0 == "Target.closeTarget" }.count, 1)
    }
    func testCancellationDuringBrowserStartupNeverCreatesAJoinTarget() async throws {
        let chrome = AttendanceChrome()
        let paused = AttendanceLauncher(chrome); paused.hold = true
        let subject = MeetAttendanceController(launcher: paused, pollSeconds: 0.005)
        subject.join(link: try link(), noteID: nil, guestName: "Fixture")
        await wait { paused.gate != nil }
        subject.leave(); await wait { subject.status == .ended }
        paused.gate?.resume(); paused.gate = nil
        for _ in 0..<10 { await Task.yield() }
        let calls = await chrome.calls; XCTAssertTrue(calls.isEmpty)
        XCTAssertNil(subject.joinedAt); XCTAssertFalse(subject.mayStillBeInCall)
    }
    func testFailedLeaveRequiresManualAcknowledgementAndBlocksNewAttendance() async throws {
        let chrome = AttendanceChrome(closeSucceeds: false)
        let launcher = AttendanceLauncher(chrome)
        let subject = MeetAttendanceController(launcher: launcher, pollSeconds: 0.005)
        await chrome.setStage(.joined)
        subject.join(link: try link(), noteID: nil, guestName: "Fixture"); await wait { subject.status == .joined }
        let closed = await subject.leaveAndWait(); XCTAssertFalse(closed)
        XCTAssertEqual(subject.status, .failed); XCTAssertTrue(subject.mayStillBeInCall)
        subject.join(link: try link(), noteID: nil, guestName: "Retry")
        XCTAssertEqual(launcher.calls, 1)
        subject.confirmClosedManually(); XCTAssertFalse(subject.mayStillBeInCall)
    }
    func testAdmissionTimeoutAndNaturalEndCleanUpAndNotifyLinkedNote() async throws {
        let chrome = AttendanceChrome()
        let subject = MeetAttendanceController(launcher: AttendanceLauncher(chrome), pollSeconds: 0.005, admissionTimeout: 0.02)
        subject.join(link: try link(), noteID: nil, guestName: "Fixture"); await wait { subject.status == .failed }
        XCTAssertTrue(subject.message.contains("timed out")); XCTAssertFalse(subject.mayStillBeInCall)
        let next = AttendanceChrome(); await next.setStage(.ended)
        let completed = MeetAttendanceController(launcher: AttendanceLauncher(next), pollSeconds: 0.005)
        let id = UUID(); var ended: UUID?; completed.onEnded = { ended = $0 }
        completed.join(link: try link(), noteID: id, guestName: "Fixture"); await wait { completed.status == .ended }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(ended, id)
        let calls = await next.calls; XCTAssertTrue(calls.contains("Target.closeTarget"))
    }
    func testDemoCannotLaunchBrowserAndArgumentsUseDedicatedLoopbackProfile() async throws {
        let launcher = AttendanceLauncher(AttendanceChrome())
        let store = PuddleStore(meetBrowserLauncher: launcher); store.enterDemo()
        store.joinGoogleMeet(try link(), noteID: nil, guestName: "Fixture")
        await Task.yield(); XCTAssertEqual(launcher.calls, 0)
        let args = ManagedMeetBrowser.arguments(directory: URL(fileURLWithPath: "/tmp/puddle-fixture-profile"))
        XCTAssertTrue(args.contains("--remote-debugging-port=0")); XCTAssertTrue(args.contains("--remote-debugging-address=127.0.0.1"))
        XCTAssertTrue(args.contains("--user-data-dir=/tmp/puddle-fixture-profile"))
        XCTAssertFalse(args.contains("--no-sandbox")); XCTAssertFalse(args.contains("--disable-web-security"))
    }
}
