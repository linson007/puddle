import Foundation
import XCTest
import PuddleCore
@testable import Puddle

@MainActor private final class FakeSpeechPlayer: SpeechPlaying {
    var texts: [String] = []
    var completions: [@MainActor () -> Void] = []
    var stopped = 0
    func speak(_ text: String, language: String, speed: Double, completion: @escaping @MainActor () -> Void) {
        texts.append(text); completions.append(completion)
    }
    func stop() { stopped += 1 }
}

@MainActor final class SpeechPlaybackTests: XCTestCase {
    func testReadingTogglesAndIgnoresCompletionFromOldUtterance() {
        let player = FakeSpeechPlayer()
        // The store below uses only in-memory demo state and an injected speech engine.
        let subject = PuddleStore(speechPlayer: player)
        subject.enterDemo()
        let first = ChatLine(role: "assistant", content: "First reply"), second = ChatLine(role: "assistant", content: "Second reply")
        subject.readAloud(first); XCTAssertEqual(subject.speakingMessageID, first.id)
        subject.readAloud(second); player.completions[0]()
        XCTAssertEqual(subject.speakingMessageID, second.id)
        player.completions[1](); XCTAssertNil(subject.speakingMessageID)
        subject.readAloud(first); subject.readAloud(first)
        XCTAssertNil(subject.speakingMessageID)
        XCTAssertEqual(player.texts, ["First reply", "Second reply", "First reply"])
    }

    func testUserTextCannotTriggerPlaybackAndNewConversationStopsIt() {
        let player = FakeSpeechPlayer(), store = PuddleStore(speechPlayer: player)
        store.enterDemo()
        store.readAloud(ChatLine(role: "user", content: "Do not speak"))
        XCTAssertTrue(player.texts.isEmpty)
        store.readAloud(ChatLine(role: "assistant", content: "**Useful** [label](https://example.test)"))
        XCTAssertEqual(player.texts.last, "Useful label")
        store.clearChat()
        XCTAssertNil(store.speakingMessageID)
        XCTAssertGreaterThan(player.stopped, 0)
    }

    func testAutomaticPlaybackIsOptInAndStopsWhenDisabled() async throws {
        let player = FakeSpeechPlayer(), store = PuddleStore(speechPlayer: player)
        store.enterDemo()
        XCTAssertFalse(store.state.settings.readRepliesAloud)
        store.setReadRepliesAloud(true); store.ask("Explain a planning method")
        for _ in 0..<200 {
            if !store.isThinking { break }; try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(store.isThinking)
        XCTAssertEqual(player.texts.count, 1)
        XCTAssertNotNil(store.speakingMessageID)
        store.setReadRepliesAloud(false)
        XCTAssertNil(store.speakingMessageID)
        XCTAssertFalse(store.state.settings.readRepliesAloud)
    }
}
