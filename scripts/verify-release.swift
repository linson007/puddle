import CryptoKit
import Foundation
import Darwin

// Run after uploading the immutable archive and before promoting the feed.
struct Manifest: Decodable { let payload: Data; let signature: Data }
struct Release: Decodable { let version: String; let build: Int; let downloadURL: URL; let sha256: String }
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
func fail(_ text: String) -> Never { FileHandle.standardError.write(Data((text + "\n").utf8)); exit(1) }
let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 4, let publicKey = Data(base64Encoded: args[2]) else { fail("Usage: verify-release.swift ARCHIVE MANIFEST BASE64_PUBLIC_KEY ACCEPTANCE_JSON") }
let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
guard key.isValidSignature(manifest.signature, for: manifest.payload) else { fail("Manifest signature verification failed.") }
let release = try JSONDecoder().decode(Release.self, from: manifest.payload)
let acceptance = Process(); acceptance.executableURL = URL(fileURLWithPath: "/usr/bin/env")
let acceptanceScript = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("release-acceptance.py")
acceptance.arguments = ["python3", acceptanceScript.path, "check", "--archive", args[0], "--record", args[3],
                        "--expected-version", release.version, "--expected-build", String(release.build), "--public-key", args[2]]
try acceptance.run(); acceptance.waitUntilExit()
guard acceptance.terminationStatus == 0 else { fail("Release acceptance is incomplete or belongs to a different archive. The manifest must not be promoted.") }
let local = try Data(contentsOf: URL(fileURLWithPath: args[0]))
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
guard digest(local) == release.sha256, release.downloadURL.scheme == "https", release.downloadURL.host != nil,
      release.downloadURL.user == nil, release.downloadURL.password == nil, release.downloadURL.fragment == nil,
      local.count <= 128 * 1024 * 1024 else { fail("Invalid archive, URL or manifest hash.") }
let configuration = URLSessionConfiguration.ephemeral
configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 180
let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
defer { session.invalidateAndCancel() }
let (bytes, response) = try await session.bytes(from: release.downloadURL)
defer { bytes.task.cancel() }
guard let response = response as? HTTPURLResponse, response.statusCode == 200,
      response.url == release.downloadURL, response.expectedContentLength <= 128 * 1024 * 1024 else { fail("The immutable download URL did not return the expected archive.") }
var hash = SHA256(), count = 0, chunk = Data()
for try await byte in bytes {
    guard count < local.count else { fail("The remote archive is larger than the signed local archive.") }
    chunk.append(byte); count += 1
    if chunk.count == 65536 { hash.update(data: chunk); chunk.removeAll(keepingCapacity: true) }
}
hash.update(data: chunk)
guard count == local.count, hash.finalize().map({ String(format: "%02x", $0) }).joined() == release.sha256 else { fail("The remote archive does not match the signed manifest.") }
print("Verified remote archive for \(release.version), build \(release.build). The manifest may now be promoted through the release gate.")
