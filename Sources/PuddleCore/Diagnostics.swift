import Foundation
import os

/// Stable operation names are public. Error descriptions can contain URLs,
/// paths, provider responses or personal text and are always private.
public enum PuddleDiagnostics {
    public enum Category: String, Codable, Sendable { case persistence, network, speech, oauth }
    public struct SupportEvent: Codable, Sendable {
        public let id: UUID
        public let occurredAt: Date
        public let category: Category
        public let domain: String
        public let code: Int
    }
    private static let support = OSAllocatedUnfairLock(initialState: [SupportEvent]())
    public static func supportEvents() -> [SupportEvent] { support.withLock { $0 } }
    private static let persistence = Logger(subsystem: "app.puddle", category: "persistence")
    private static let network = Logger(subsystem: "app.puddle", category: "network")
    private static let speech = Logger(subsystem: "app.puddle", category: "speech")
    private static let oauth = Logger(subsystem: "app.puddle", category: "oauth")
    static func meetingRecoveryPruned() { persistence.notice("Pruned obsolete unreadable meeting recovery") }
    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }
    @discardableResult public static func failure(_ category: Category, _ operation: String, _ error: Error) -> Bool {
        guard !isCancellation(error) else { return false }
        let value = error as NSError
        let domains = [NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain]
        let event = SupportEvent(id: UUID(), occurredAt: Date(), category: category,
                                 domain: domains.contains(value.domain) ? value.domain : "application", code: value.code)
        support.withLock { $0.append(event); if $0.count > 50 { $0.removeFirst($0.count - 50) } }
        let logger: Logger
        switch category { case .persistence: logger = persistence; case .network: logger = network; case .speech: logger = speech; case .oauth: logger = oauth }
        logger.error("\(operation, privacy: .public): \(error.localizedDescription, privacy: .private)")
        return true
    }
    static func removeRecoveryFile(_ file: URL) {
        do { try FileManager.default.removeItem(at: file) }
        catch { failure(.persistence, "Remove obsolete recovery file", error) }
    }
}
