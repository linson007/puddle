import Combine
import Foundation
import PuddleCore

struct ReleaseUpdateConfiguration {
    let manifestURL: URL
    let publicKey: Data
    let currentBuild: Int

    init(bundle: Bundle = .main) throws {
        guard let raw = bundle.object(forInfoDictionaryKey: "PuddleUpdateManifestURL") as? String,
              let url = URL(string: raw), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil,
              let encoded = bundle.object(forInfoDictionaryKey: "PuddleUpdatePublicKey") as? String,
              let key = Data(base64Encoded: encoded), key.count == 32,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let current = Int(build), current > 0 else {
            throw PuddleError("This build has no valid signed update feed configured. The app owner must supply its HTTPS manifest URL, Ed25519 public key and build number.")
        }
        manifestURL = url; publicKey = key; currentBuild = current
    }
}

/// Owns manual update work so dismissing Settings or pausing connections can cancel it.
@MainActor final class ReleaseUpdateController: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var release: PuddleRelease?
    @Published private(set) var downloaded: URL?
    private let transport: any HTTPTransport
    private let configuration: () throws -> ReleaseUpdateConfiguration
    private let canConnect: () -> Bool
    private let downloadRoot: URL
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private let maximumDownloadBytes = 128 * 1024 * 1024

    init(transport: any HTTPTransport, configuration: @escaping () throws -> ReleaseUpdateConfiguration = { try ReleaseUpdateConfiguration() },
         canConnect: @escaping () -> Bool, downloadRoot: URL? = nil) {
        self.transport = transport; self.configuration = configuration; self.canConnect = canConnect
        self.downloadRoot = downloadRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Puddle Updates", isDirectory: true)
    }

    private func start(_ message: String, work: @escaping (UUID) async throws -> Void) {
        guard !busy else { return }
        guard canConnect() else { cancel(message: "Updates are paused while external connections are unavailable."); return }
        let expected = UUID(); generation = expected; busy = true; status = message
        operation = Task {
            defer { if generation == expected { busy = false; operation = nil } }
            do { try await work(expected) }
            catch {
                guard generation == expected else { return }
                status = PuddleDiagnostics.isCancellation(error) ? "Update operation cancelled." : error.localizedDescription
            }
        }
    }
    private func checkCurrent(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard generation == expected, canConnect() else { throw CancellationError() }
    }
    func cancel(message: String = "Update operation cancelled.") {
        generation = UUID(); operation?.cancel(); operation = nil; busy = false
        release = nil; downloaded = nil; status = message
    }
    func check() {
        guard !busy else { return }
        release = nil; downloaded = nil
        start("Checking the signed update feed…") { [self] expected in
            let config = try configuration()
            let (data, response) = try await transport.sendBounded(URLRequest(url: config.manifestURL), maximumBytes: 64 * 1024, until: nil)
            try checkCurrent(expected)
            guard response.statusCode == 200 else { throw PuddleError("The update feed returned HTTP \(response.statusCode).") }
            let verified = try ReleaseVerification.release(data, publicKey: config.publicKey, currentBuild: config.currentBuild)
            try checkCurrent(expected)
            release = verified
            status = verified == nil ? "This build is up to date for the configured feed." : "Release signature verified."
        }
    }
    func download() {
        guard !busy, let release else { return }
        downloaded = nil
        start("Downloading and verifying…") { [self] expected in
            let (data, response) = try await transport.sendBounded(URLRequest(url: release.downloadURL, timeoutInterval: 180), maximumBytes: maximumDownloadBytes, until: nil)
            try checkCurrent(expected)
            guard response.statusCode == 200 else { throw PuddleError("Download returned HTTP \(response.statusCode).") }
            try await Task.detached { try ReleaseVerification.verifyDownload(data, release: release) }.value
            try checkCurrent(expected)
            let directory = downloadRoot.appendingPathComponent("\(release.build)-\(UUID())", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let file = directory.appendingPathComponent("Puddle-\(release.build)." + release.downloadURL.pathExtension)
                try data.write(to: file, options: [.atomic, .completeFileProtection])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                downloaded = file; status = "Signature and archive checksum verified. You can now open the installer."
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
    }
    func openInstaller(_ open: @escaping (URL) -> Bool) {
        guard !busy, let file = downloaded, let release else { return }
        start("Rechecking the downloaded installer…") { [self] expected in
            do {
                let limit = maximumDownloadBytes
                try await Task.detached {
                    let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= limit else {
                        throw PuddleError("The downloaded installer changed. Download a verified copy again.")
                    }
                    try ReleaseVerification.verifyDownload(Data(contentsOf: file), release: release)
                }.value
                try checkCurrent(expected)
                status = open(file) ? "Opened the verified installer. Installation stays under your control." : "The installer could not open. Locate it in Downloads → Puddle Updates."
            } catch {
                if generation == expected { downloaded = nil }
                throw error
            }
        }
    }
}
