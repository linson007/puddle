import Foundation
import XCTest
@testable import PuddleCore

private actor FixtureChromeWire: ChromeWire {
    var sent: [Data] = []
    private var responses: [Data] = []
    private var waiting: CheckedContinuation<Data, Error>?
    private var closed = false
    func send(_ message: String) async throws { guard !closed else { throw CancellationError() }; sent.append(Data(message.utf8)) }
    func receive() async throws -> Data {
        if !responses.isEmpty { return responses.removeFirst() }
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func respond(_ object: [String: String], id: Int) throws {
        let data = try ChromeJSON.data(["id": id, "result": object])
        enqueue(data)
    }
    func enqueue(_ data: Data) {
        if let waiting { self.waiting = nil; waiting.resume(returning: data) } else { responses.append(data) }
    }
    func close() { closed = true; waiting?.resume(throwing: CancellationError()); waiting = nil }
}

final class ChromeDevToolsTests: XCTestCase {
    private func wait(_ wire: FixtureChromeWire, count: Int) async throws -> [[String: Any]] {
        for _ in 0..<200 {
            let sent = await wire.sent
            if sent.count >= count { return try sent.map(ChromeJSON.object) }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Browser command fixture timed out"); return []
    }
    func testOutOfOrderResponsesAndEventsAreMatchedToTheirCommand() async throws {
        let wire = FixtureChromeWire()
        let subject = ChromeDevTools(wire: wire)
        let first = Task { try await subject.command("First") }
        let a = try await wait(wire, count: 1)
        let second = Task { try await subject.command("Second") }
        let b = try await wait(wire, count: 2)
        await wire.enqueue(try ChromeJSON.data(["method": "Page.loadEventFired", "params": [:]]))
        try await wire.respond(["value": "second"], id: b[1]["id"] as! Int)
        try await wire.respond(["value": "first"], id: a[0]["id"] as! Int)
        let firstData = try await first.value, secondData = try await second.value
        XCTAssertEqual(try ChromeJSON.object(firstData)["value"] as? String, "first")
        XCTAssertEqual(try ChromeJSON.object(secondData)["value"] as? String, "second")
        await subject.close()
    }
    func testTimeoutAndCancellationCompletePromptlyAndIgnoreLateResponses() async throws {
        let wire = FixtureChromeWire()
        let subject = ChromeDevTools(wire: wire, timeout: 0.02)
        let timed = Task { try await subject.command("Timed") }
        let sent = try await wait(wire, count: 1)
        do { _ = try await timed.value; XCTFail("Expected timeout") } catch { XCTAssertTrue(error.localizedDescription.contains("did not respond")) }
        try await wire.respond(["value": "late"], id: sent[0]["id"] as! Int)
        let cancelled = Task { try await subject.command("Cancelled") }
        _ = try await wait(wire, count: 2); cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        await subject.close()
    }
    func testMalformedResponseAndCloseResolveAllWaitingCommands() async throws {
        let wire = FixtureChromeWire()
        let subject = ChromeDevTools(wire: wire)
        let operation = Task { try await subject.command("Malformed") }
        _ = try await wait(wire, count: 1); await wire.enqueue(Data("not json".utf8))
        do { _ = try await operation.value; XCTFail("Expected response failure") } catch {}
        await subject.close()
        let fresh = FixtureChromeWire()
        let waiting = ChromeDevTools(wire: fresh)
        let task = Task { try await waiting.command("Waiting") }
        _ = try await wait(fresh, count: 1); await waiting.close()
        do { _ = try await task.value; XCTFail("Expected close failure") } catch {}
    }
    func testProtocolErrorIdentifiesCommandAndCodeWithoutItsParametersAndKeepsConnectionUsable() async throws {
        let wire = FixtureChromeWire()
        let subject = ChromeDevTools(wire: wire)
        let operation = Task { try await subject.command("Runtime.evaluate", parameters: ChromeJSON.data(["expression": "private-source-text"])) }
        let sent = try await wait(wire, count: 1)
        await wire.enqueue(try ChromeJSON.data(["id": sent[0]["id"]!, "error": ["code": -32602, "message": "Invalid parameters\nCheck session"]]))
        do { _ = try await operation.value; XCTFail("Expected protocol error") }
        catch let error as ChromeProtocolError {
            XCTAssertEqual(error.method, "Runtime.evaluate"); XCTAssertEqual(error.code, -32602)
            XCTAssertTrue(error.localizedDescription.contains("Invalid parameters"))
            XCTAssertFalse(error.localizedDescription.contains("private-source-text"))
            XCTAssertFalse(error.localizedDescription.contains("\n"))
            XCTAssertFalse(error.localizedDescription.contains("Update Chrome"))
        }
        let next = Task { try await subject.command("Target.getTargets") }
        let commands = try await wait(wire, count: 2)
        try await wire.respond(["value": "still connected"], id: commands[1]["id"] as! Int)
        let value = try await next.value
        XCTAssertEqual(try ChromeJSON.object(value)["value"] as? String, "still connected")
        await subject.close()
    }
}
