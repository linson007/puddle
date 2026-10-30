import SwiftUI

struct WorkspaceSyncStatus: View {
    let date: Date?
    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: 7) {
            if isRefreshing { ProgressView().controlSize(.small) }
            Text(isRefreshing ? "Refreshing…" : date.map { "Updated \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Not refreshed yet")
        }.font(.caption).foregroundStyle(.secondary)
    }
}

struct GoogleWorkspaceConnectionView: View {
    @ObservedObject var store: PuddleStore
    let title: String
    let icon: String
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label("Connect \(title)", systemImage: icon)
        } description: {
            Text(detail)
        } actions: {
            VStack(spacing: 12) {
                Button(store.isSigningIn ? "Connecting Google…" : store.connected ? "Manage Google Permissions…" : "Connect Google") {
                    store.requestGoogleConnection()
                }.buttonStyle(.borderedProminent).disabled(store.isSigningIn || store.isDisconnecting)
                if store.isSigningIn {
                    ProgressView(store.googleSignInStatus).controlSize(.small)
                    Button("Cancel sign-in") { store.cancelSignIn() }
                }
                Button("Manage connections") { store.section = .connections }.buttonStyle(.link)
                Text("Read-only access. Choose the Google services you want to connect.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
