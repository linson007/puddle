import SwiftUI
import PuddleCore

struct ReleaseSettingsView: View {
    @ObservedObject var store: PuddleStore
    @StateObject private var updates: ReleaseUpdateController
    @State private var diagnostics: String?
    init(store: PuddleStore) {
        self.store = store
        _updates = StateObject(wrappedValue: ReleaseUpdateController(transport: store.transport,
            canConnect: { !store.isLocked && !store.privateSession && !store.state.settings.networkDisabled }))
    }
    private var updatesBlocked: Bool { store.isLocked || store.privateSession || store.state.settings.networkDisabled }
    var body: some View {
        Form {
            Section("Updates") {
                LabeledContent("Installed", value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") + ")")
                Text("Checks use a publisher-signed manifest and verify the downloaded archive before opening it. Installation stays under your control. Export a workspace backup before upgrading; older app versions may not read newer workspace schemas.").font(.caption).foregroundStyle(.secondary)
                Button("Check for Updates") { updates.check() }.disabled(updates.busy || updatesBlocked)
                if let release = updates.release {
                    Text("Version \(release.version), build \(release.build), is available.")
                    Button("Download Verified Update") { updates.download() }.disabled(updates.busy || updatesBlocked)
                }
                if updates.downloaded != nil { Button("Open Verified Installer") { updates.openInstaller { NSWorkspace.shared.open($0) } }.disabled(updates.busy || updatesBlocked) }
                if updates.busy {
                    HStack { ProgressView().controlSize(.small); Button("Cancel") { updates.cancel() } }
                }
                if !updates.status.isEmpty { Text(updates.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Section("Local diagnostics") {
                Button("Prepare Redacted Diagnostics") {
                    diagnostics = "Puddle \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nMemory: \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB\nWorkspace schema: \(AppSnapshot.currentSchemaVersion)\nLocal AI connected: \(store.inferenceModel != nil)\nCua connected: \(store.browserWorkspace.isConnected)\nExternal connections paused: \(store.state.settings.networkDisabled)\nNo conversation, document, account, address, token, URL, path, or transcript content is included."
                }
                if let diagnostics {
                    Text(diagnostics).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Copy Diagnostics") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(diagnostics, forType: .string) }
                }
                Text("Diagnostics stay here until you choose to copy and share them. Puddle does not upload them.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
            .onChange(of: updatesBlocked) { _, blocked in if blocked { updates.cancel(message: "Updates are paused while external connections are unavailable.") } }
            .onDisappear { updates.cancel() }
    }
}
