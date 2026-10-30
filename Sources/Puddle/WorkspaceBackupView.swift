import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PuddleCore

struct WorkspaceBackupView: View {
    @ObservedObject var store: PuddleStore
    @State private var busy = false
    @State private var status: String?
    @State private var error: String?
    @State private var pending: WorkspaceBackupPreview?
    @State private var showingMerge = false
    @State private var password = ""
    @State private var confirmation = ""
    @State private var encrypt = true

    var body: some View {
        Form {
            Section("Portable workspace backup") {
                Text("Back up conversations, memories, commitments, profiles, meeting notes, actions, projects, people, decisions, routines, browser errand records and development sessions. Credentials, account caches, model settings, local indexes, folder access and browser sessions are excluded.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Encrypt portable backup", isOn: $encrypt)
                SecureField("Backup passphrase (also used when restoring)", text: $password)
                if encrypt { SecureField("Confirm passphrase for export", text: $confirmation) }
                Text("Encrypted backups use your passphrase, independently of this Mac’s Keychain. Keep the passphrase somewhere safe; it cannot be recovered by Puddle. Drafts include their sending account and message contents.").font(.caption).foregroundStyle(.secondary)
                if !encrypt { Label("Unencrypted exports can contain confidential work.", systemImage: "lock.open").font(.caption) }
                Button("Export Workspace Backup…") { run { try await export() } }.disabled(busy || store.demo || !store.storageAvailable)
            }
            Section("Restore from a backup") {
                Text("Review a backup, then merge missing items into this workspace. Existing items and your active conversation are kept. Restored chats appear in History; saved connections remain as they are.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Review Backup…") { run { try await review() } }.disabled(busy || store.demo || !store.storageAvailable)
                Text("Imported tasks start without daily priority stars. Past reminders appear as overdue without replaying notifications; future reminders use your current notification setting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if busy { ProgressView("Working with your local backup…").controlSize(.small) }
            if let status { Text(status).font(.callout).textSelection(.enabled) }
            if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
        }.formStyle(.grouped)
            .sheet(isPresented: $showingMerge, onDismiss: { pending = nil }) {
                if let pending { mergePreview(pending) }
            }
    }

    private func mergePreview(_ backup: WorkspaceBackupPreview) -> some View {
        let report = WorkspaceBackup.merging(backup, into: store.state).1
        return VStack(alignment: .leading, spacing: 18) {
            Text("Review workspace backup").font(.title2).fontWeight(.semibold)
            Text("Created \(backup.createdAt.formatted(date: .complete, time: .shortened))").foregroundStyle(.secondary)
            Text("Contains \(backup.profilesCount) profiles, \(backup.memoriesCount) memories, \(backup.tasksCount) commitments, \(backup.meetingsCount) meeting notes, \(backup.conversationsCount) conversations, \(backup.actionsCount) actions, \(backup.projectsCount) projects, \(backup.peopleCount) people, \(backup.decisionsCount) decisions, \(backup.routinesCount) routines and \(backup.errandsCount) browser errands.")
            Text(report.summary).font(.callout)
            Text("Current items take precedence when IDs or memory titles already exist. Empty preset profiles can receive saved context; conflicting profile names and profiles beyond the 50-profile limit are kept out. Restoring does not execute actions or connect accounts.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { showingMerge = false }.keyboardShortcut(.cancelAction)
                Button("Merge Workspace") {
                    if let result = store.restoreWorkspaceBackup(backup) {
                        status = result.summary; showingMerge = false; error = nil
                    } else { error = store.errorMessage }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 560)
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true; status = nil; error = nil
        Task {
            defer { busy = false }
            do { try await operation() } catch { self.error = error.localizedDescription }
        }
    }

    private func export() async throws {
        let access = try store.workspaceAccess()
        if encrypt { guard password.count >= 12, password == confirmation else { throw PuddleError("Enter matching backup passphrases of at least 12 characters.") } }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Puddle-workspace-\(Date().ISO8601Format().prefix(10)).json"
        let response = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
        guard response == .OK, let url = panel.url else { return }
        try store.checkWorkspaceAccess(access)
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Snapshot after the user chooses a destination so work saved during the panel is included.
        let snapshot = store.state
        let password = password, encrypt = encrypt
        try await store.writeWorkspaceExport(to: url, access: access) {
            try await Task.detached(priority: .userInitiated) {
                try encrypt ? ProtectedWorkspaceBackup.encode(snapshot, password: password) : WorkspaceBackup.encode(snapshot)
            }.value
        }
        status = "Saved backup to \(url.lastPathComponent). Unsaved meeting drafts are not included."
    }

    private func review() async throws {
        let access = try store.workspaceAccess()
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        let response = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
        guard response == .OK, let url = panel.url else { return }
        try store.checkWorkspaceAccess(access)
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let password = password
        let preview = try await Task.detached(priority: .userInitiated) {
            let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard info.isRegularFile == true, let bytes = info.fileSize, bytes <= WorkspaceBackup.maximumBytes * 2 else { throw PuddleError("Choose a regular backup under 128 MB.") }
            return try ProtectedWorkspaceBackup.inspect(Data(contentsOf: url), password: password)
        }.value
        try store.checkWorkspaceAccess(access)
        pending = preview
        showingMerge = true
    }
}

extension PuddleStore {
    @discardableResult func restoreWorkspaceBackup(_ backup: WorkspaceBackupPreview) -> WorkspaceRestoreReport? {
        do {
            _ = try workspaceAccess()
            let (next, report) = WorkspaceBackup.merging(backup, into: state)
            let profileChanged = next.profileLibrary.active != state.profileLibrary.active
            try commit { $0 = next }
            if profileChanged { stopAI() }
            scheduleReminders(); errorMessage = nil; return report
        } catch { fail(error); return nil }
    }
}
