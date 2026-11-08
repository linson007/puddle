import SwiftUI

struct ConnectionPrivacyNotice: View {
    @ObservedObject var store: PuddleStore
    let provider: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Selected provider content is sent to your local model. Disconnect removes local credentials and current caches. Retrieved content can remain in saved conversations, notes, model-server logs and exported backups. Review History, Memory and Meetings to delete saved content; delete old exports and model-server logs separately.")
            Text("Provider access is not confirmed revoked by disconnecting. Remove Puddle’s grant or token in your provider’s account settings.")
            HStack {
                Button("Review Saved History") { store.section = .history }
                if provider == "Google" { Link("Manage Google access", destination: URL(string: "https://myaccount.google.com/connections")!) }
                if provider == "Microsoft" { Link("Manage Microsoft access", destination: URL(string: "https://account.live.com/consent/Manage")!) }
                if provider == "GitHub" { Link("Manage GitHub tokens", destination: URL(string: "https://github.com/settings/personal-access-tokens")!) }
                if provider == "Atlassian" { Link("Manage Atlassian access", destination: URL(string: "https://id.atlassian.com/manage-profile/apps")!) }
            }
        }.font(.caption).foregroundStyle(.secondary)
    }
}
