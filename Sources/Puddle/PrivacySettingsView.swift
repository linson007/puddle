import SwiftUI
import LocalAuthentication
import PuddleCore

struct PrivacySettingsView: View {
    @ObservedObject var store: PuddleStore
    @State private var confirmPurge = false
    var body: some View {
        Form {
            Section("Private session") {
                Text("New work stays in memory and is discarded when ended. External APIs, external actions, and memory learning pause. Starting ends the Cua browser session. Your saved workspace returns afterward.").font(.callout).foregroundStyle(.secondary)
                Button(store.privateSession ? "End Private Session" : "Start Private Session") {
                    if store.privateSession { store.endPrivateSession() } else { store.beginPrivateSession() }
                }.disabled(store.demo || store.meetingCapture.isActive)
            }
            if !store.privateSession {
                Section("External connections") {
                    Toggle("Pause Puddle’s external connections", isOn: Binding(get: { store.state.settings.networkDisabled }, set: { store.setExternalConnectionsPaused($0) }))
                    Text("Loopback AI remains available. Google, Microsoft, GitHub and Atlassian API requests are blocked and older in-flight responses discarded. Managed browser sessions and speech-language downloads stop. Installed speech languages work offline. This does not change other apps or independently running servers.").font(.caption).foregroundStyle(.secondary)
                }
                Section("App lock") {
                    Button("Lock Puddle") { store.lockWorkspace() }
                    Toggle("Lock when Puddle leaves the foreground", isOn: Binding(get: { store.state.settings.lockOnBackground }, set: { enabled in
                        do { try store.commit { $0.settings.lockOnBackground = enabled } } catch { store.fail(error) }
                    }))
                    Text("Unlock with your Mac’s authentication. Locking hides workspace content and stops assistant and browser activity.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Archive retention") {
                    Picker("Keep archived conversations", selection: Binding(get: { store.state.settings.archiveRetentionDays }, set: { days in
                        do { try store.commit { $0.settings.archiveRetentionDays = days } } catch { store.fail(error) }
                    })) {
                        Text("Until I delete them").tag(0); Text("30 days").tag(30); Text("90 days").tag(90); Text("One year").tag(365)
                    }
                    Text("\(store.expiredArchiveIDs.count) older archives match. The current conversation is preserved. Apply explicitly after reviewing this policy.").font(.caption).foregroundStyle(.secondary)
                    Button("Apply Retention…", role: .destructive) { confirmPurge = true }.disabled(store.expiredArchiveIDs.isEmpty)
                    Text("The active state and rolling recovery copy are encrypted. Older encrypted migration/recovery files and exports can retain previous data; deleting here does not erase external backups.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Storage") {
                    Label("Encrypted on this Mac · AES-256-GCM", systemImage: "lock.shield")
                    Text(storageDescription).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
        }.formStyle(.grouped).confirmationDialog("Delete \(store.expiredArchiveIDs.count) older archived conversations?", isPresented: $confirmPurge) {
            Button("Delete Matching Archives", role: .destructive) { store.applyArchiveRetention() }
            Button("Cancel", role: .cancel) {}
        }
    }
    private var storageDescription: String {
        #if DEBUG
        if UITestWorkspace.enabled { return "UI test mode only: the synthetic workspace key is in the owner-only fixture file. This does not verify production Keychain protection. Portable backups still require a separate passphrase." }
        #endif
        return "The workspace key stays in Keychain. Portable backups use a separate passphrase in Backups. Losing both the key and portable backups makes the workspace unrecoverable."
    }
}

struct PrivacyLockView: View {
    @ObservedObject var store: PuddleStore
    @State private var error: String?
    @State private var unlocking = false
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield").font(.system(size: 48)).foregroundStyle(PuddleStyle.teal)
            Text("Puddle is locked").font(.title.bold())
            Button(unlocking ? "Authenticating…" : "Unlock with macOS") {
                unlocking = true
                Task {
                    do {
                        if try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your Puddle workspace") { store.unlockWorkspace(); error = nil }
                    } catch { self.error = error.localizedDescription }
                    unlocking = false
                }
            }.buttonStyle(.borderedProminent).disabled(unlocking)
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(PuddleStyle.background)
    }
}

extension PuddleStore {
    func beginPrivateSession() {
        guard !demo, !privateSession, !meetingCapture.isActive, !isLocked, executingActions.isEmpty else { return }
        stopAI(); cancelMeetingSummary(); suspendConnectionWork(); browserWorkspace.stop(); meetAttendance.leave(); systemDictation.stop()
        savedPrivateWorkspace = state; privateSession = true
        state.chat = []; state.conversations = []; state.actionProposals = []; state.currentConversationID = UUID()
        state.settings.automaticallyLearn = false; state.settings.automaticallyCheck = false
        networkPolicy.allowExternalConnections(false); section = .chat; errorMessage = nil
    }
    func endPrivateSession() {
        guard privateSession, let saved = savedPrivateWorkspace else { return }
        stopAI(); cancelMeetingSummary(); resetMeetingWorkspace()
        state = saved; savedPrivateWorkspace = nil; privateSession = false; errorMessage = nil
        networkPolicy.allowExternalConnections(!state.settings.networkDisabled && !isLocked); startPolling()
        if !isLocked { systemDictation.configure(state.settings) }
    }
    func setExternalConnectionsPaused(_ paused: Bool) {
        guard !privateSession, !demo else { return }
        do {
            try commit { $0.settings.networkDisabled = paused }
            networkPolicy.allowExternalConnections(!paused && !isLocked)
            if paused {
                stopAI(); suspendConnectionWork(); browserWorkspace.stop(); meetAttendance.leave(); splashSetup.stop()
                if meetingCapture.status == .installingLanguage { meetingCapture.cancel() }
            }
            else { startPolling() }
        } catch { fail(error) }
    }
    func lockWorkspace() {
        guard !demo else { return }
        stopAI(); cancelMeetingSummary(); suspendConnectionWork(); browserWorkspace.stop(); meetingCapture.stop(); meetAttendance.leave()
        isLocked = true; networkPolicy.allowExternalConnections(false)
        systemDictation.stop()
    }
    func unlockWorkspace() {
        isLocked = false; networkPolicy.allowExternalConnections(!state.settings.networkDisabled && !privateSession)
        if !privateSession { startPolling() }
        if !privateSession { systemDictation.configure(state.settings) }
    }
    var expiredArchiveIDs: Set<UUID> {
        guard state.settings.archiveRetentionDays > 0 else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(state.settings.archiveRetentionDays) * 86400)
        return Set(state.conversations.filter { $0.createdAt < cutoff }.map(\.id))
    }
    func applyArchiveRetention() {
        let ids = expiredArchiveIDs
        do {
            try commit { $0.conversations.removeAll { ids.contains($0.id) } }
            try commit { _ in }; errorMessage = nil
        } catch { fail(error) }
    }
}
