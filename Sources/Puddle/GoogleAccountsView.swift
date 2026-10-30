import SwiftUI
import PuddleCore

struct GoogleAccountsView: View {
    @ObservedObject var store: PuddleStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.googleAccounts.count > 1 || (store.state.account == nil && !store.googleAccounts.isEmpty) {
                Picker("Active Google account", selection: Binding(get: { store.state.account ?? "" }, set: { email in Task { await store.switchGoogleAccount(email) } })) {
                    if store.state.account == nil { Text("Choose account").tag("") }
                    ForEach(store.googleAccounts, id: \.id) { account in Text(account.email).tag(account.email) }
                }.disabled(store.isSigningIn || store.isDisconnecting)
            }
            Button("Add Google Account") { store.connect() }.disabled(store.isSigningIn || store.privateSession || store.state.settings.networkDisabled)
            Text("Switching selects this account for Gmail and Google Calendar. Each account’s tokens stay in Keychain. Cached views are cleared and refreshed; saved conversations and notes remain. Actions stay bound to the account you reviewed.").font(.caption).foregroundStyle(.secondary)
        }.task { await store.loadGoogleAccounts() }
    }
}

extension PuddleStore {
    func loadGoogleAccounts() async {
        do { googleAccounts = try await google.accounts() } catch { fail(error) }
    }
    func switchGoogleAccount(_ email: String) async {
        guard !isSigningIn, !isDisconnecting, !privateSession, !isLocked, email != state.account else { return }
        stopAI(); suspendConnectionWork(); isSigningIn = true
        defer { isSigningIn = false; startPolling() }
        do {
            try await google.selectAccount(email: email)
            guard try await google.account()?.email == email, !isDisconnecting else { throw CancellationError() }
            let scopes = try await google.grantedScopes()
            try commit { next in
                next.account = email; next.messages = []; next.calendarEvents = []
                next.settings.mailProvider = .google
                next.lastSync = nil; next.mailHistoryID = nil; next.calendarLastSync = nil; next.calendarHasMore = false
            }
            connected = true; grantedScopes = scopes; selectedID = nil; errorMessage = nil
            await loadGoogleAccounts(); isSigningIn = false
            if mailConnected { await sync() }; if calendarConnected { await refreshCalendar() }
        } catch { fail(error) }
    }
}
