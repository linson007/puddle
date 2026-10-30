import SwiftUI
import PuddleCore

struct ReleaseSettingsView: View {
    @ObservedObject var store: PuddleStore
    @State private var busy = false
    @State private var status = ""
    @State private var release: PuddleRelease?
    @State private var downloaded: URL?
    @State private var diagnostics: String?
    var body: some View {
        Form {
            Section("Updates") {
                LabeledContent("Installed", value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") + ")")
                Text("Checks use a publisher-signed manifest and verify the downloaded archive before opening it. Installation stays under your control. Export a workspace backup before upgrading; older app versions may not read newer workspace schemas.").font(.caption).foregroundStyle(.secondary)
                Button("Check for Updates") { Task { await check() } }.disabled(busy || store.state.settings.networkDisabled)
                if let release {
                    Text("Version \(release.version), build \(release.build), is available.")
                    Button("Download Verified Update") { Task { await download(release) } }.disabled(busy)
                }
                if let downloaded { Button("Open Verified Installer") { if !NSWorkspace.shared.open(downloaded) { status = "The installer could not open. Locate it in Downloads → Puddle Updates." } } }
                if busy { ProgressView().controlSize(.small) }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Section("Local diagnostics") {
                Button("Prepare Redacted Diagnostics") {
                    let hardware = store.splashSetup.hardware
                    diagnostics = "Puddle \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nChip: \(hardware?.chip ?? "Not inspected")\nMemory: \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB\nWorkspace schema: \(AppSnapshot.currentSchemaVersion)\nLocal AI connected: \(store.splashModel != nil)\nCua connected: \(store.browserWorkspace.isConnected)\nExternal connections paused: \(store.state.settings.networkDisabled)\nNo conversation, document, account, address, token, URL, path, or transcript content is included."
                }
                if let diagnostics {
                    Text(diagnostics).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Copy Diagnostics") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(diagnostics, forType: .string) }
                }
                Text("Diagnostics stay here until you choose to copy and share them. Puddle does not upload them.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).onAppear { store.splashSetup.inspect() }
    }
    private func check() async {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PuddleUpdateManifestURL") as? String, let url = URL(string: raw), url.scheme == "https",
              let encoded = Bundle.main.object(forInfoDictionaryKey: "PuddleUpdatePublicKey") as? String, let key = Data(base64Encoded: encoded) else {
            status = "This development build has no signed update feed configured. The app owner must supply its HTTPS manifest URL and Ed25519 public key."; return
        }
        busy = true; defer { busy = false }; status = "Checking the signed update feed…"
        do {
            let (data, response) = try await store.transport.sendBounded(URLRequest(url: url), maximumBytes: 64 * 1024, until: nil)
            guard response.statusCode == 200 else { throw PuddleError("The update feed returned HTTP \(response.statusCode).") }
            let current = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
            release = try ReleaseVerification.release(data, publicKey: key, currentBuild: current)
            status = release == nil ? "This build is up to date for the configured feed." : "Release signature verified."
        } catch { status = error.localizedDescription }
    }
    private func download(_ release: PuddleRelease) async {
        busy = true; defer { busy = false }; status = "Downloading and verifying…"; downloaded = nil
        do {
            let (data, response) = try await store.transport.sendBounded(URLRequest(url: release.downloadURL, timeoutInterval: 180), maximumBytes: 128 * 1024 * 1024, until: nil)
            guard response.statusCode == 200 else { throw PuddleError("Download returned HTTP \(response.statusCode).") }
            try await Task.detached { try ReleaseVerification.verifyDownload(data, release: release) }.value
            let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Puddle Updates/\(release.build)-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("Puddle-\(release.build)." + release.downloadURL.pathExtension)
            try data.write(to: file, options: [.atomic, .completeFileProtection]); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            downloaded = file; status = "Signature and archive checksum verified. You can now open the installer."
        } catch { status = error.localizedDescription }
    }
}
