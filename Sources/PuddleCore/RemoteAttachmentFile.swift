import CoreServices
import Darwin
import Foundation

/// Publish downloaded bytes only after their untrusted origin is recorded.
public enum RemoteAttachmentFile {
    public static func write(_ data: Data, to destination: URL, origin: URL) throws {
        try write(data, to: destination) { file in
            var values = URLResourceValues()
            values.quarantineProperties = [
                kLSQuarantineTypeKey as String: kLSQuarantineTypeEmailAttachment,
                kLSQuarantineOriginURLKey as String: origin as NSURL,
                kLSQuarantineAgentNameKey as String: "Puddle",
                kLSQuarantineAgentBundleIdentifierKey as String: "app.puddle.mac"
            ]
            var file = file
            try file.setResourceValues(values)
            // Launch Services' origin database is not always available (for
            // example in an unsigned test host). Retain origin on the file too.
            let provenance = try PropertyListSerialization.data(fromPropertyList: [origin.absoluteString], format: .binary, options: 0)
            let saved = provenance.withUnsafeBytes { setxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, $0.count, 0, 0) }
            let quarantine = try URL(fileURLWithPath: file.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
            guard saved == 0, quarantine?[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeEmailAttachment as String else {
                throw PuddleError("The attachment's quarantine protection could not be saved. No attachment was published.")
            }
        }
    }
    static func write(_ data: Data, to destination: URL, quarantine: (URL) throws -> Void) throws {
        guard destination.isFileURL else { throw PuddleError("Choose a local attachment destination.") }
        try Task.checkCancellation()
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".puddle-attachment-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let file = staging.appendingPathComponent("attachment")
        guard fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw PuddleError("The attachment could not be saved.") }
        try quarantine(file)
        try Task.checkCancellation()
        // Rename on the same filesystem preserves metadata and never exposes an
        // unquarantined intermediate destination, even when replacing a file.
        guard rename(file.path, destination.path) == 0 else { throw PuddleError("The quarantined attachment could not be moved to its destination.") }
    }
}
