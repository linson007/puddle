import Foundation
import XCTest
@testable import PuddleCore

final class MeetingLinkTests: XCTestCase {
    func testSupportedProviderLinksAndQueryPasscodesArePreserved() throws {
        for (address, provider) in [
            ("https://meet.google.com/abc-defg-hij", MeetingProvider.googleMeet),
            ("https://meet.google.com/lookup/standup", .googleMeet),
            ("https://us02web.zoom.us/j/12345678901?pwd=fixture", .zoom),
            ("https://zoom.us/my/example", .zoom),
            ("https://teams.microsoft.com/l/meetup-join/fixture/0?context=fixture", .teams),
            ("https://teams.live.com/meet/123456789", .teams),
            ("https://example.webex.com/meet/example", .webex),
            ("https://example.webex.com/example/j.php?MTID=fixture", .webex),
        ] {
            let link = try MeetingJoinLink(address)
            XCTAssertEqual(link.provider, provider)
            XCTAssertEqual(link.url.absoluteString, address)
        }
    }

    func testPastedMeetPrefixIsNormalizedBeforeOpeningAndDiscovery() throws {
        let pasted = "https://meet.google.com/meet/abc-defg-hij"
        let direct = "https://meet.google.com/abc-defg-hij"
        let link = try MeetingJoinLink(pasted)
        XCTAssertEqual(link.provider, .googleMeet)
        XCTAssertEqual(link.url.absoluteString, direct)
        let withQuery = try MeetingJoinLink(pasted + "/?authuser=1&hs=122")
        XCTAssertEqual(withQuery.url.absoluteString, direct + "/?authuser=1&hs=122")
        XCTAssertEqual(withQuery.url.query, "authuser=1&hs=122")
        XCTAssertEqual(MeetingJoinLink.discover(in: [pasted, direct]).map(\.url.absoluteString), [direct])
        for invalid in [
            "https://meet.google.com.evil.test/meet/abc-defg-hij",
            "https://evil.test/meet/abc-defg-hij",
            "https://meet.google.com/meet/abc-defg-hij/extra",
            "https://meet.google.com/meet/lookup/standup",
            "http://meet.google.com/meet/abc-defg-hij",
            "https://user:password@meet.google.com/meet/abc-defg-hij",
        ] { XCTAssertThrowsError(try MeetingJoinLink(invalid), invalid) }
    }

    func testLookalikesCredentialsNonMeetingPagesAndNonHTTPSAreRejected() {
        for address in [
            "http://meet.google.com/abc-defg-hij", "https://meet.google.com.evil.test/abc-defg-hij",
            "https://evil.test/meet/abc-defg-hij", "https://meet.google.com/new", "https://meet.google.com/",
            "https://zoom.us.evil.test/j/123456789", "https://user:password@zoom.us/j/123456789",
            "https://zoom.us:8443/j/123456789", "file:///tmp/meeting", "javascript:alert(1)",
            "https://evil.test/meet/teams.microsoft.com", "https://teams.microsoft.com/account",
        ] { XCTAssertThrowsError(try MeetingJoinLink(address), address) }
    }

    func testDiscoveryHandlesHTMLAndDeduplicates() {
        let address = "https://meet.google.com/abc-defg-hij"
        let links = MeetingJoinLink.discover(in: [address, "<a href=\"\(address)\">Join</a>", "Other: https://zoom.us/j/123456789?pwd=a&amp;mode=b."])
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].provider, .googleMeet)
        XCTAssertEqual(links[1].url.query, "pwd=a&mode=b")
    }

    func testCalendarConferenceEntryPointsArePreferredAndPhoneLinksIgnored() throws {
        let event: [String: Any] = ["id": "fixture", "summary": "Standup", "start": ["dateTime": "2026-10-29T12:00:00Z"],
            "hangoutLink": "https://meet.google.com/abc-defg-hij", "description": "<a href=\"https://zoom.us/j/123456789\">backup</a>",
            "conferenceData": ["entryPoints": [["entryPointType": "video", "uri": "https://meet.google.com/abc-defg-hij"],
                                                   ["entryPointType": "phone", "uri": "tel:+15555555555"]]]]
        let decoded = try GoogleCalendarClient.decode(JSONSerialization.data(withJSONObject: ["items": [event]]))
        XCTAssertEqual(decoded[0].joinLinks.map(\.provider), [.googleMeet, .zoom])
        let restored = try JSONDecoder().decode(CalendarEvent.self, from: JSONEncoder().encode(decoded[0]))
        XCTAssertEqual(restored.joinLinks, decoded[0].joinLinks)
    }

    func testLegacyCalendarCacheFindsPlainTextMeetingLink() throws {
        let legacy = Data(#"{"id":"event","title":"Review","start":"2026-10-29","end":"","location":"https://meet.google.com/abc-defg-hij","description":""}"#.utf8)
        let event = try JSONDecoder().decode(CalendarEvent.self, from: legacy)
        XCTAssertEqual(event.joinLinks.first?.provider, .googleMeet)
        XCTAssertThrowsError(try JSONDecoder().decode(MeetingJoinLink.self, from: Data(#"{"url":"https://evil.test/meet/fixture"}"#.utf8)))
    }
}
