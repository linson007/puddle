import Foundation
import os

/// Stable operation names are public. Error descriptions can contain URLs,
/// paths, provider responses or personal text and are always private.
public enum PuddleDiagnostics {
    public enum Category: String, Sendable { case persistence, network, speech, oauth }
    private static let persistence = Logger(subsystem: "app.puddle", category: "persistence")
    private static let network = Logger(subsystem: "app.puddle", category: "network")
    private static let speech = Logger(subsystem: "app.puddle", category: "speech")
    private static let oauth = Logger(subsystem: "app.puddle", category: "oauth")
    public static func failure(_ category: Category, _ operation: String, _ error: Error) {
        guard !(error is CancellationError) else { return }
        let logger: Logger
        switch category { case .persistence: logger = persistence; case .network: logger = network; case .speech: logger = speech; case .oauth: logger = oauth }
        logger.error("\(operation, privacy: .public): \(error.localizedDescription, privacy: .private)")
    }
    static func removeRecoveryFile(_ file: URL) {
        do { try FileManager.default.removeItem(at: file) }
        catch { failure(.persistence, "Remove obsolete recovery file", error) }
    }
}
