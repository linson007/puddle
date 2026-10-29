import Foundation
import XCTest
@testable import PuddleCore

final class SpeechTextTests: XCTestCase {
    func testSpokenTextKeepsLinkLabelsAndOmitsCodeAndDestinations() {
        let text = """
        # A useful **reply**
        - Read [the guide](https://example.test/private?token=fixture).
        ```swift
        print("Never read this code")
        ```
        ![diagram](https://example.test/image.png)
        """
        let prepared = SpeechText.prepare(text)
        XCTAssertTrue(prepared.contains("A useful reply"))
        XCTAssertTrue(prepared.contains("the guide"))
        XCTAssertTrue(prepared.contains("Code block omitted"))
        XCTAssertFalse(prepared.contains("Never read")); XCTAssertFalse(prepared.contains("https"))
        XCTAssertFalse(prepared.contains("token")); XCTAssertFalse(prepared.contains("diagram"))
    }

    func testUnfinishedCodeBlockAndUnicodeBudgetAreHandled() {
        XCTAssertFalse(SpeechText.prepare("Explanation.\n```swift\nprivate code").contains("private code"))
        XCTAssertEqual(SpeechText.prepare(String(repeating: "🌊", count: 100), maximumCharacters: 7), String(repeating: "🌊", count: 7))
        XCTAssertEqual(SpeechText.prepare("**", maximumCharacters: 7), "")
        XCTAssertEqual(SpeechText.prepare("hello", maximumCharacters: -1), "")
    }

    func testVoicePreferencesMigrateAndRoundTrip() throws {
        let legacy = try JSONDecoder().decode(PuddleSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(legacy.readRepliesAloud)
        var settings = legacy; settings.readRepliesAloud = true; settings.speechLanguage = "en-IN"; settings.speechSpeed = 1.2
        let restored = try JSONDecoder().decode(PuddleSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(restored.readRepliesAloud); XCTAssertEqual(restored.speechLanguage, "en-IN")
        XCTAssertEqual(restored.speechSpeed, 1.2)
    }
}
