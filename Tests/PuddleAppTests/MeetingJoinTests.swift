import Foundation
import XCTest
@testable import Puddle

@MainActor private final class FakeURLOpener: ExternalURLOpening {
    var urls: [URL] = []
    var succeeds = true
    func open(_ url: URL) -> Bool { urls.append(url); return succeeds }
}

@MainActor final class MeetingJoinTests: XCTestCase {
    func testJoinOpensValidatedProviderLinkAndReportsPreJoinStateOnly() async {
        let opener = FakeURLOpener()
        let subject = PuddleStore(urlOpener: opener)
        await subject.openMeetingLink("https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(opener.urls.count, 1)
        XCTAssertTrue(subject.meetingLinkStatus?.contains("join screen") == true)
        XCTAssertNil(subject.errorMessage)
        await subject.openMeetingLink("https://evil.test/meeting")
        XCTAssertEqual(opener.urls.count, 1)
        XCTAssertNil(subject.meetingLinkStatus); XCTAssertNotNil(subject.errorMessage)
    }

    func testPastedMeetPrefixOpensTheDirectMeetingURL() async {
        let opener = FakeURLOpener()
        let subject = PuddleStore(urlOpener: opener)
        await subject.openMeetingLink("https://meet.google.com/meet/abc-defg-hij")
        XCTAssertEqual(opener.urls.map(\.absoluteString), ["https://meet.google.com/abc-defg-hij"])
        XCTAssertNotNil(subject.meetingLinkStatus)
        XCTAssertNil(subject.errorMessage)
    }

    func testDemoCannotOpenMeetingAndLaunchFailureIsVisible() async {
        let opener = FakeURLOpener(), store = PuddleStore(urlOpener: opener)
        opener.succeeds = false
        await store.openMeetingLink("https://zoom.us/j/123456789")
        XCTAssertNil(store.meetingLinkStatus); XCTAssertNotNil(store.errorMessage)
        await store.enterDemo(); await store.openMeetingLink("https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(opener.urls.count, 1)
    }
}
