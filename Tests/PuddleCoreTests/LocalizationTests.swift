import Foundation
import XCTest
import PuddleCore

final class LocalizationTests: XCTestCase {
    func testPrimaryNavigationAndRecoveryMessagesHaveTurkishResources() {
        let locale = Locale(identifier: "tr")
        XCTAssertEqual(L10n.text("Today", locale: locale), "Bugün")
        XCTAssertEqual(L10n.text("Settings", locale: locale), "Ayarlar")
        XCTAssertEqual(L10n.text("Save Notes", locale: locale), "Notları kaydet")
        XCTAssertEqual(L10n.text("No speech was detected.", locale: locale), "Konuşma algılanmadı.")
    }
    func testEnglishAndUnknownKeysRetainReadableDefaults() {
        XCTAssertEqual(L10n.text("Today", locale: Locale(identifier: "en")), "Today")
        XCTAssertEqual(L10n.text("A provider-specific error", locale: Locale(identifier: "tr")), "A provider-specific error")
    }
}
