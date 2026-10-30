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
      let keyFile = ProcessInfo.processInfo.environment["PUDDLE_UPDATE_SIGNING_KEY_FILE"] else { fail("Usage: PUDDLE_UPDATE_SIGNING_KEY_FILE=/private/key swift scripts/release-manifest.swift ARCHIVE VERSION BUILD HTTPS_URL OUTPUT_JSON") }
guard !FileManager.default.fileExists(atPath: args[4]) else { fail("The manifest output already exists; it was preserved.") }
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: URL(fileURLWithPath: keyFile)))
let archive = try Data(contentsOf: URL(fileURLWithPath: args[0]))
struct Release: Codable { let version: String; let build: Int; let downloadURL: URL; let sha256: String; let minimumOSMajor = 14; let minimumOSMinor = 0 }
struct Manifest: Codable { let payload: Data; let signature: Data }
let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
let payload = try encoder.encode(Release(version: args[1], build: build, downloadURL: download, sha256: SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()))
let manifest = try encoder.encode(Manifest(payload: payload, signature: key.signature(for: payload)))
try manifest.write(to: URL(fileURLWithPath: args[4]), options: [.atomic, .completeFileProtection])
print("Signed manifest written. Public key: " + key.publicKey.rawRepresentation.base64EncodedString())
