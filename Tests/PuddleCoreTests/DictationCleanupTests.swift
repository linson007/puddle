import XCTest
@testable import PuddleCore

final class DictationCleanupTests: XCTestCase {
    func testVocabularyMatchesWholePhrasesAndKeepsReplacementLiteral() throws {
        let words = try DictationCleanup.vocabulary("puddle=Puddle\nproject cost=Cost $1")
        XCTAssertEqual(DictationCleanup.apply("puddle project cost puddles", replacements: words, punctuation: false), "Puddle Cost $1 puddles")
        XCTAssertThrowsError(try DictationCleanup.vocabulary("missing separator"))
        XCTAssertEqual(DictationCleanup.apply("where are you?", replacements: [:], punctuation: true), "Where are you?")
    }
}
