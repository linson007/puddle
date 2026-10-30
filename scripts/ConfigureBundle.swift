import Foundation

let path = CommandLine.arguments[1], url = URL(fileURLWithPath: path), environment = ProcessInfo.processInfo.environment
var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: Any]
func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
if let version = environment["PUDDLE_VERSION"] {
    let parts = version.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { fail("PUDDLE_VERSION needs three numeric components.") }
    info["CFBundleShortVersionString"] = version
}
if let build = environment["PUDDLE_BUILD_NUMBER"] {
    guard let value = Int(build), value > 0 else { fail("PUDDLE_BUILD_NUMBER must be a positive integer.") }
    info["CFBundleVersion"] = build
}
if let manifest = environment["PUDDLE_UPDATE_MANIFEST_URL"] {
    guard let url = URL(string: manifest), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { fail("Use an HTTPS update manifest URL without credentials.") }
    info["PuddleUpdateManifestURL"] = manifest
}
if let key = environment["PUDDLE_UPDATE_PUBLIC_KEY"] {
    guard Data(base64Encoded: key)?.count == 32 else { fail("PUDDLE_UPDATE_PUBLIC_KEY must be a base64 Ed25519 public key.") }
    info["PuddleUpdatePublicKey"] = key
}
if let client = environment["PUDDLE_MICROSOFT_CLIENT_ID"] {
    guard UUID(uuidString: client) != nil else { fail("PUDDLE_MICROSOFT_CLIENT_ID must be an application UUID.") }
    info["PuddleMicrosoftClientID"] = client
}
try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url, options: .atomic)
