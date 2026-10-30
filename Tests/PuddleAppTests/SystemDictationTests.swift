import Foundation
import XCTest
@testable import Puddle
import PuddleCore

@MainActor private final class DictationFixtureCapture: SpeechCapturing {
    var callback: (@MainActor (String, Bool) -> Void)?
    var cancelled = false
    func start(language: String, onText: @escaping @MainActor (String, Bool) -> Void, onError: @escaping @MainActor (String) -> Void) async throws { callback = onText }
    func finish() { callback?("puddle is ready", true) }
    func cancel() { cancelled = true; callback = nil }
}
@MainActor private final class DictationFixtureTarget: DictationTargeting {
    var isAuthorized = true
    var changed = false
    var inserted: [String] = []
    func requestAuthorization() {}
    func captureTarget() throws {}
    func insert(_ text: String) throws { if changed { throw PuddleError("Focus changed") }; inserted.append(text) }
}
@MainActor final class SystemDictationTests: XCTestCase {
    func testHoldReleaseInsertsOnceAndUsesVocabulary() async throws {
        let capture = DictationFixtureCapture(), target = DictationFixtureTarget()
        let controller = SystemDictationController(capture: capture, target: target, displaysOverlay: false)
        var settings = PuddleSettings(); settings.systemDictationEnabled = true; settings.dictationVocabulary = ["puddle": "Puddle"]
        controller.configure(settings, registerShortcut: false); controller.press(); controller.press()
        for _ in 0..<100 where controller.voice.status != .listening { try await Task.sleep(for: .milliseconds(5)) }
        controller.release(); controller.release()
        XCTAssertEqual(target.inserted, ["Puddle is ready."])
        controller.stop(); XCTAssertFalse(controller.enabled)
    }
    func testFocusChangeRetainsTranscriptWithoutInserting() async throws {
        let capture = DictationFixtureCapture(), target = DictationFixtureTarget()
        let controller = SystemDictationController(capture: capture, target: target, displaysOverlay: false)
        var settings = PuddleSettings(); settings.systemDictationEnabled = true
        controller.configure(settings, registerShortcut: false); controller.press()
        for _ in 0..<100 where controller.voice.status != .listening { try await Task.sleep(for: .milliseconds(5)) }
        target.changed = true; controller.release()
        XCTAssertTrue(target.inserted.isEmpty); XCTAssertFalse(controller.retainedText.isEmpty)
        XCTAssertTrue(controller.status.contains("Focus changed")); controller.stop()
    }
    func testUnavailablePermissionsAndCapturePolicyBlockRecording() {
        let capture = DictationFixtureCapture(), target = DictationFixtureTarget(); target.isAuthorized = false
        let controller = SystemDictationController(capture: capture, target: target, displaysOverlay: false)
        var settings = PuddleSettings(); settings.systemDictationEnabled = true
        controller.configure(settings, registerShortcut: false); controller.press()
        XCTAssertFalse(controller.voice.isActive)
        target.isAuthorized = true; controller.configure(settings, registerShortcut: false); controller.canStart = { false }; controller.press()
        XCTAssertFalse(controller.voice.isActive); controller.stop()
    }
}
