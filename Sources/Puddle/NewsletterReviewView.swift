import SwiftUI
import PuddleCore

struct NewsletterReviewView: View {
    @ObservedObject var store: PuddleStore
    @Environment(\.dismiss) private var dismiss
    @State private var kept: Set<String> = []
    @State private var additional: [MailMessage] = []
    @State private var query = ""
    @State private var searching = false
    private var candidates: [MailMessage] {
        var seen = Set<String>()
        return (store.mailInbox + additional).filter { message in
            guard message.newsletter != nil else { return false }
            let key = MailDraft.mailbox(message.sender).lowercased()
            return !kept.contains(key) && seen.insert(key).inserted
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Review newsletters").font(.title2.bold()); Spacer(); Button("Close") { dismiss() } }
            Text("Reviews senders with a supported HTTPS one-click unsubscribe header. Your cached inbox is a partial view. Each unsubscribe gets its own exact-destination review.").font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Search mail (Gmail syntax or Outlook text)", text: $query).textFieldStyle(.roundedBorder)
                Button(searching ? "Searching…" : "Search Mail") {
                    searching = true
                    Task { defer { searching = false }; do { additional = try await store.searchCurrentMail(query) } catch { store.fail(error) } }
                }.disabled(searching || store.demo)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if candidates.isEmpty { ContentUnavailableView("No supported newsletter senders", systemImage: "tray", description: Text("Search other mail or open a sender’s subscription settings from the original email.")) }
                    ForEach(candidates) { message in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(message.sender).font(.headline)
                            Text(message.newsletter?.url.host ?? "").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Keep") { kept.insert(MailDraft.mailbox(message.sender).lowercased()) }
                                Button("Review Unsubscribe…") {
                                    dismiss(); Task { @MainActor in await Task.yield(); store.proposeUnsubscribe(message) }
                                }
                                Link("Original message", destination: message.sourceURL)
                            }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(24).frame(width: 700, height: 570)
    }
}
extension PuddleStore {
    func proposeUnsubscribe(_ message: MailMessage) {
        guard let target = message.newsletter else { return }
        editingAction = ActionProposal(account: mailAccount ?? "", payload: .unsubscribe(target), sourceURL: message.sourceURL, provider: message.provider ?? .google)
    }
}
