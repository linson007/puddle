import CryptoKit
import Foundation

public struct PuddleRelease: Codable, Sendable {
    public let version: String
    public let build: Int
    public let downloadURL: URL
    public let sha256: String
    public let minimumOSMajor: Int
    public let minimumOSMinor: Int
    public init(version: String, build: Int, downloadURL: URL, sha256: String, minimumOSMajor: Int = 14, minimumOSMinor: Int = 0) {
        self.version = version; self.build = build; self.downloadURL = downloadURL; self.sha256 = sha256
        self.minimumOSMajor = minimumOSMajor; self.minimumOSMinor = minimumOSMinor
    }
}
public struct SignedReleaseManifest: Codable, Sendable {
    public let payload: Data
    public let signature: Data
    public init(payload: Data, signature: Data) { self.payload = payload; self.signature = signature }
}
public enum ReleaseVerification {
    public static func release(_ data: Data, publicKey: Data, currentBuild: Int, os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) throws -> PuddleRelease? {
        guard data.count <= 64 * 1024 else { throw PuddleError("The update manifest is too large.") }
        let manifest = try JSONDecoder().decode(SignedReleaseManifest.self, from: data)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard key.isValidSignature(manifest.signature, for: manifest.payload) else { throw PuddleError("The update signature could not be verified. No download was started.") }
        let release = try JSONDecoder().decode(PuddleRelease.self, from: manifest.payload)
        guard release.downloadURL.scheme == "https", release.downloadURL.host != nil, release.downloadURL.user == nil, release.downloadURL.password == nil,
              ["zip", "dmg", "pkg"].contains(release.downloadURL.pathExtension.lowercased()),
              release.sha256.count == 64, release.sha256.allSatisfy(\.isHexDigit), release.build > 0,
              !release.version.isEmpty, release.version.count <= 100 else { throw PuddleError("The signed release contains invalid download details.") }
        guard os.majorVersion > release.minimumOSMajor || (os.majorVersion == release.minimumOSMajor && os.minorVersion >= release.minimumOSMinor) else { throw PuddleError("This update needs a newer macOS version.") }
        return release.build > currentBuild ? release : nil
    }
    public static func verifyDownload(_ data: Data, release: PuddleRelease) throws {
        var hash = SHA256()
        for offset in stride(from: 0, to: data.count, by: 1024 * 1024) {
            try Task.checkCancellation()
            hash.update(data: data.subdata(in: offset..<min(offset + 1024 * 1024, data.count)))
        }
        try Task.checkCancellation()
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(release.sha256) == .orderedSame else { throw PuddleError("The download failed its SHA-256 check. It was not opened.") }
    }
    public static func verifyDownload(at file: URL, release: PuddleRelease, maximumBytes: Int) throws {
        var hash = SHA256()
        try BoundedFile.chunks(file, maximumBytes: maximumBytes) { hash.update(data: $0) }
        try Task.checkCancellation()
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(release.sha256) == .orderedSame else { throw PuddleError("The download failed its SHA-256 check. It was not opened.") }
    }
}
