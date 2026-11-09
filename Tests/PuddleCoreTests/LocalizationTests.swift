import Foundation
import XCTest
import PuddleCore

final class LocalizationTests: XCTestCase {
    func testUnshippedTurkishLocaleFallsBackToReadableEnglish() {
        XCTAssertEqual(L10n.text("Today", locale: Locale(identifier: "tr")), "Today")
        XCTAssertEqual(L10n.text("Settings", locale: Locale(identifier: "tr")), "Settings")
    }
    func testEnglishAndUnknownKeysRetainReadableDefaults() {
        XCTAssertEqual(L10n.text("Today", locale: Locale(identifier: "en")), "Today")
        XCTAssertEqual(L10n.text("A provider-specific error", locale: Locale(identifier: "tr")), "A provider-specific error")
    }
}
