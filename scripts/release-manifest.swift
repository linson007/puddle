import Foundation
import CryptoKit
import Darwin

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--generate-key" {
    guard args.count == 2 else { fail("Usage: release-manifest.swift --generate-key /private/path/to/key") }
    let url = URL(fileURLWithPath: args[1])
    let key = Curve25519.Signing.PrivateKey()
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { fail("Could not create a new private key file. Any existing file was preserved.") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    try handle.write(contentsOf: key.rawRepresentation); try handle.synchronize(); try handle.close()
    print("Public key: " + key.publicKey.rawRepresentation.base64EncodedString()); exit(0)
}
guard args.count == 5, let build = Int(args[2]), build > 0, let download = URL(string: args[3]), download.scheme == "https",
      download.host != nil, download.user == nil, download.password == nil, download.fragment == nil,
      let keyFile = ProcessInfo.processInfo.environment["PUDDLE_UPDATE_SIGNING_KEY_FILE"] else { fail("Usage: PUDDLE_UPDATE_SIGNING_KEY_FILE=/private/key swift scripts/release-manifest.swift ARCHIVE VERSION BUILD HTTPS_URL OUTPUT_JSON") }
guard !FileManager.default.fileExists(atPath: args[4]) else { fail("The manifest output already exists; it was preserved.") }
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: URL(fileURLWithPath: keyFile)))
let archive = try Data(contentsOf: URL(fileURLWithPath: args[0]))
let extracted = FileManager.default.temporaryDirectory.appendingPathComponent("puddle-manifest-\(UUID())", isDirectory: true)
try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
defer { try? FileManager.default.removeItem(at: extracted) }
let unpack = Process(); unpack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
unpack.arguments = ["-x", "-k", URL(fileURLWithPath: args[0]).standardizedFileURL.path, extracted.path]
try unpack.run(); unpack.waitUntilExit()
guard unpack.terminationStatus == 0 else { fail("The final release archive could not be inspected.") }
let app = extracted.appendingPathComponent("Puddle.app")
let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
guard info?["CFBundleShortVersionString"] as? String == args[1], info?["CFBundleVersion"] as? String == String(build),
      info?["PuddleUpdatePublicKey"] as? String == key.publicKey.rawRepresentation.base64EncodedString() else {
    fail("Archive version, build or pinned update key does not match the manifest. Nothing was signed.")
}
let verify = Process(); verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
verify.arguments = ["--verify", "--deep", "--strict", app.path]
try verify.run(); verify.waitUntilExit()
guard verify.terminationStatus == 0 else { fail("The archived app failed code-signature verification.") }
struct Release: Encodable { let version: String; let build: Int; let downloadURL: URL; let sha256: String; let minimumOSMajor = 14; let minimumOSMinor = 0 }
struct Manifest: Codable { let payload: Data; let signature: Data }
let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
let payload = try encoder.encode(Release(version: args[1], build: build, downloadURL: download, sha256: SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()))
let manifest = try encoder.encode(Manifest(payload: payload, signature: key.signature(for: payload)))
let signed = try JSONDecoder().decode(Manifest.self, from: manifest)
guard key.publicKey.isValidSignature(signed.signature, for: signed.payload), signed.payload == payload else { fail("Manifest signature verification failed.") }
try manifest.write(to: URL(fileURLWithPath: args[4]), options: [.atomic, .completeFileProtection])
print("Signed manifest written. Public key: " + key.publicKey.rawRepresentation.base64EncodedString())
