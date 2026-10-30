import SwiftUI
import PuddleCore

struct OutlookConnectionsView: View {
    @ObservedObject var store: PuddleStore
    @State private var clientID = ""
    @State private var tenant = "common"
    @State private var send = false
    @State private var organize = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Outlook & Microsoft 365", systemImage: "envelope.badge.shield.half.filled").font(.headline)
            if let account = store.outlookAccount {
                Text(account.email).font(.callout)
                if store.outlookAccounts.count > 1 {
                    Picker("Microsoft account", selection: Binding(get: { account.id }, set: { id in Task { await store.switchOutlookAccount(id) } })) {
                        ForEach(store.outlookAccounts) { Text($0.email).tag($0.id) }
                    }
                }
                HStack {
                    Button("Use Outlook in Mail") { store.selectMailProvider(.outlook) }
                    Button("Disconnect This Account") { Task { await store.disconnectOutlook() } }
                }
            }
            DisclosureGroup(store.outlookAccount == nil ? "Connect Outlook" : "Add Account / Manage Permissions") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Microsoft application (client) ID", text: $clientID).textFieldStyle(.roundedBorder)
                    TextField("Tenant: common, organizations, consumers, or tenant ID", text: $tenant).textFieldStyle(.roundedBorder)
                    Text("App owner setup: register a Desktop/public client in Microsoft Entra with loopback redirect http://localhost/oauth/callback. An application ID is public configuration; no client secret is used.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Allow reviewed sending", isOn: $send)
                    Toggle("Allow reviewed mail organization", isOn: $organize)
                    HStack {
                        Button(store.isConnectingOutlook ? "Waiting for Microsoft…" : "Sign in with Microsoft") { store.connectOutlook(clientID: clientID, tenant: tenant, allowSend: send, allowOrganize: organize) }
                            .disabled(store.isConnectingOutlook || store.demo || store.state.settings.networkDisabled)
                        if store.isConnectingOutlook { ProgressView().controlSize(.small); Button("Cancel") { store.cancelOutlookConnection() } }
                    }
                }.padding(.top, 10)
            }
            Text("Mail goes directly to Microsoft Graph. Credentials stay in Keychain. Calendar proposals currently use Google Calendar. Sending is reviewed separately and an accepted request is not proof of delivery.").font(.caption).foregroundStyle(.secondary)
        }.padding(22).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 12))
            .task {
                if let config = try? await store.outlook.configuration() { clientID = config.clientID; tenant = config.tenant }
                send = store.outlookAccount?.scopes.contains("Mail.Send") == true
                organize = store.outlookAccount?.scopes.contains("Mail.ReadWrite") == true
            }
    }
}

extension PuddleStore {
    func loadOutlookConnection() async {
        do {
            if try await outlook.configuration() == nil, let id = Bundle.main.object(forInfoDictionaryKey: "PuddleMicrosoftClientID") as? String {
                try await outlook.configure(MicrosoftClientConfiguration(clientID: id))
            }
            outlookAccounts = try await outlook.accounts(); outlookAccount = try await outlook.account()
            let email = outlookAccount?.email
            if state.outlookAccount != email {
                try commit { $0.outlookAccount = email; $0.outlookMessages = []; $0.outlookLastSync = nil }
            }
        } catch { fail(error) }
    }
    func connectOutlook(clientID: String, tenant: String, allowSend: Bool, allowOrganize: Bool) {
        guard !demo, !privateSession, !isLocked, !state.settings.networkDisabled, !isConnectingOutlook else { return }
        stopAI(); isConnectingOutlook = true
        outlookOAuthTask = Task {
            let callback = WorkOAuthCallback(); outlookCallback = callback
            defer { callback.close(); outlookCallback = nil; isConnectingOutlook = false }
            do {
                let config = try MicrosoftClientConfiguration(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines), tenant: tenant.trimmingCharacters(in: .whitespacesAndNewlines))
                try await outlook.configure(config)
                let redirect = try await callback.start()
                let attempt = try MicrosoftOAuthAttempt(configuration: config, callback: redirect, allowSend: allowSend, allowOrganize: allowOrganize)
                let code = try await callback.wait(for: attempt)
                try await outlook.exchange(code: code, attempt: attempt); try Task.checkCancellation()
                await loadOutlookConnection(); selectMailProvider(.outlook); errorMessage = nil
            } catch is CancellationError {} catch { fail(error) }
        }
    }
    func cancelOutlookConnection() { outlookOAuthTask?.cancel(); outlookCallback?.cancel(); isConnectingOutlook = false }
    func switchOutlookAccount(_ id: String) async {
        guard !privateSession, !isLocked, !isConnectingOutlook else { return }
        stopAI(); suspendConnectionWork()
        do { try await outlook.select(id); await loadOutlookConnection(); selectMailProvider(.outlook) } catch { fail(error) }
    }
    func disconnectOutlook() async {
        guard !privateSession, !isLocked else { return }
        cancelOutlookConnection(); stopAI(); suspendConnectionWork()
        do { try await outlook.disconnect(); await loadOutlookConnection(); startPolling() } catch { fail(error) }
    }
    func selectMailProvider(_ provider: MailProvider) {
        guard !privateSession, !isLocked else { return }
        stopAI(); suspendConnectionWork()
        do { try commit { $0.settings.mailProvider = provider }; selectedID = nil; startPolling(); Task { await sync() } }
        catch { fail(error) }
    }
    func syncOutlook() async {
        guard !isSyncing, !demo, !privateSession, !isLocked, let account = outlookAccount else { return }
        isSyncing = true; defer { isSyncing = false }
        do {
            let fetched = try await OutlookMailClient(session: outlook, transport: transport).inbox()
            try Task.checkCancellation()
            guard state.settings.mailProvider == .outlook, outlookAccount?.id == account.id, !isLocked, !privateSession else { return }
            try commit { next in
                let summaries = Dictionary(next.outlookMessages.map { ($0.id, $0.summary) }, uniquingKeysWith: { first, _ in first })
                next.outlookMessages = fetched.map { value in var copy = value; copy.summary = summaries[value.id] ?? nil; return copy }
                next.outlookLastSync = Date()
            }
        } catch is CancellationError {} catch { fail(error) }
    }
    func searchCurrentMail(_ query: String) async throws -> [MailMessage] {
        if demo { return Array(mailInbox.prefix(10)) }
        if state.settings.mailProvider == .outlook { return try await OutlookMailClient(session: outlook, transport: transport).search(query) }
        return try await GmailClient(session: google, transport: transport).search(query: query)
    }
    func accountForAction(_ proposal: ActionProposal) -> String? { proposal.provider == .outlook ? outlookAccount?.email : state.account }
}
