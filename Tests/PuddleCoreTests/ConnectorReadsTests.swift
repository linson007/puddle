import Foundation
import XCTest
@testable import PuddleCore

@MainActor final class ConnectorReadsTests: XCTestCase {
    func testIdenticalReadsShareWorkAndOneCancelledWaiterDoesNotCancelOthers() async throws {
        let reads = ConnectorReads<Int>(), gate = AsyncTestGate(), key = Data("same-query".utf8)
        let first = Task { try await reads.run(key: key) { await gate.pause(); return 42 } }
        await fulfillment(of: [gate.entered], timeout: 5)
        let second = Task { try await reads.run(key: key) { XCTFail("Duplicate request dispatched"); return 0 } }
        try await waitForTestEvent("second read coalesced") { await reads.coalescedReadCount == 1 }
        first.cancel(); await gate.release()
        do { _ = try await first.value; XCTFail("Cancelled result was published") } catch is CancellationError {}
        let value = try await second.value; XCTAssertEqual(value, 42)
    }
    func testProviderConcurrencyIsBounded() async throws {
        let reads = ConnectorReads<Int>(), gates = (0..<4).map { _ in AsyncTestGate() }
        let tasks = gates.enumerated().map { index, gate in
            Task { try await reads.run(key: Data("query-\(index)".utf8)) { await gate.pause(); return index } }
        }
        await fulfillment(of: gates.map(\.entered), timeout: 5)
        do { _ = try await reads.run(key: Data("fifth".utf8)) { 5 }; XCTFail("Unbounded provider work") } catch {}
        for gate in gates { await gate.release() }
        for task in tasks { _ = try await task.value }
    }
}
