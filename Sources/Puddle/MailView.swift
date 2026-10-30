import SwiftUI
import PuddleCore

struct MailView: View {
    @ObservedObject var store: PuddleStore
    @State private var query = ""
    @State private var filter = MailFilter.all
    @State private var taskSource: MailMessage?
    @State private var inspecting: MailMessage?
    @State private var attentionOnly = false
    @State private var showSnoozed = false
    @State private var showNewsletters = false

    private var messages: [MailMessage] {
        let matches = MailWorkspace.messages(store.mailInbox, query: query, filter: filter).filter { message in
            let snoozed = store.state.mailSnoozes.contains { $0.messageID == message.id && $0.provider == store.state.settings.mailProvider && $0.account == store.mailAccount && $0.until > Date() }
            return showSnoozed ? snoozed : !snoozed
        }
        if !attentionOnly { return matches }
        return matches.filter { MailAttention.assess($0, people: store.state.people).rank >= 2 }.sorted {
            let left = MailAttention.assess($0, people: store.state.people).rank, right = MailAttention.assess($1, people: store.state.people).rank
            return left == right ? $0.date > $1.date : left > right
        }
    }
    private var selected: MailMessage? { messages.first { $0.id == store.selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !store.mailConnected, store.state.settings.mailProvider == .outlook {
                ContentUnavailableView { Label("Connect Outlook", systemImage: "envelope") } description: { Text("Add your Microsoft account in Connections.") } actions: { Button("Connections") { store.section = .connections } }
            } else if !store.mailConnected {
                GoogleWorkspaceConnectionView(store: store, title: "Mail", icon: "envelope",
                    detail: "Read recent Gmail messages, summarize a conversation, and turn an email into a local task.")
            } else {
                HSplitView {
                    messageList.frame(minWidth: 230, idealWidth: 280, maxWidth: 340)
                    Group {
                        if let message = selected { readingPane(message) }
                        else {
                            ContentUnavailableView("Select a message", systemImage: "envelope.open",
                                description: Text("Choose a message from your recent inbox to read it here."))
                        }
                    }.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: messages.map(\.id), initial: true) { _, ids in
            if !ids.contains(store.selectedID ?? "") { store.selectedID = ids.first }
        }
        .sheet(item: $taskSource) { message in
            CommitmentEditor(store: store, initialDraft: MailWorkspace.taskDraft(for: message))
        }
        .sheet(item: $inspecting) { MailInspectorView(store: store, message: $0) }
        .sheet(isPresented: $showNewsletters) { NewsletterReviewView(store: store) }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) { heading; Spacer(minLength: 0); headerActions }
            VStack(alignment: .leading, spacing: 14) { heading; headerActions }
        }.padding(26)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Mail").font(.system(size: 29, weight: .semibold, design: .rounded))
                .foregroundStyle(PuddleStyle.ink).accessibilityAddTraits(.isHeader)
            Text("Your recent inbox, with room to focus.").font(.callout).foregroundStyle(PuddleStyle.muted)
            if store.mailConnected {
                Text("\(store.mailAccount ?? "Mail") · Actions require review").font(.caption).foregroundStyle(PuddleStyle.muted)
                WorkspaceSyncStatus(date: store.mailLastSync, isRefreshing: store.isSyncing)
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 10) {
            Picker("Mail provider", selection: Binding(get: { store.state.settings.mailProvider }, set: { store.selectMailProvider($0) })) {
                Text("Gmail").tag(MailProvider.google); Text("Outlook").tag(MailProvider.outlook)
            }.labelsHidden().accessibilityLabel("Mail provider").frame(width: 115).disabled(store.isSyncing)
            if store.mailConnected {
                Button("Compose") { store.composeMail() }.buttonStyle(PuddlePrimaryButtonStyle())
                Button("Newsletters") { showNewsletters = true }.buttonStyle(PuddleSecondaryButtonStyle())
                Button { Task { await store.sync() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(PuddleSecondaryButtonStyle())
                    .disabled(store.demo || store.isSyncing || store.isSigningIn)
            }
        }
    }

    private var messageList: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search recent mail", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search recent mail by sender, subject, or content")
            Toggle("VIP or provider Important", isOn: $attentionOnly).font(.caption)
            Toggle("Show snoozed in Puddle", isOn: $showSnoozed).font(.caption)
            Picker("Filter mail", selection: $filter) {
                ForEach(MailFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Text("\(messages.count) messages in this view").font(.caption).foregroundStyle(.secondary)
            List(selection: $store.selectedID) {
                ForEach(messages) { message in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if message.isUnread {
                                Circle().fill(PuddleStyle.teal).frame(width: 6, height: 6).accessibilityLabel("Unread")
                            }
                            Text(message.sender).font(.callout.weight(message.isUnread ? .semibold : .regular)).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(message.date, format: .dateTime.month(.abbreviated).day()).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(message.subject.isEmpty ? "(No subject)" : message.subject).font(.callout).lineLimit(2)
                        Text(message.snippet.isEmpty ? String(message.body.prefix(160)) : message.snippet)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.padding(.vertical, 7).tag(message.id)
                }
            }.listStyle(.inset).scrollContentBackground(.hidden).background(PuddleStyle.panel)
                .overlay {
                    if messages.isEmpty {
                        ContentUnavailableView {
                            Label(store.isSyncing ? "Loading mail…" : "No matching mail", systemImage: "tray")
                        } description: {
                            Text(query.isEmpty && filter == .all ? "Refresh to check your recent inbox." : "Try another search or choose All.")
                        }
                    }
                }
            Text("Up to 50 recent inbox messages. Search and filters apply to these cached messages. Opening a message keeps its provider read status.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16)
    }

    private func readingPane(_ message: MailMessage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(message.subject.isEmpty ? "(No subject)" : message.subject).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(message.sender).font(.callout).textSelection(.enabled)
                    ForEach(MailAttention.assess(message, people: store.state.people).reasons, id: \.self) { reason in Text(reason).font(.caption).foregroundStyle(.secondary) }
                    if !message.recipient.isEmpty { Text("To: \(message.recipient)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    Text(message.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    PuddleActionFlow { messageActions(message) }.frame(maxWidth: .infinity, alignment: .leading)
                    Link("Open original message", destination: message.sourceURL).font(.caption).disabled(store.demo)
                }
                if let summary = message.summary {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Puddle summary", systemImage: "sparkles").font(.headline)
                        Text(.init(summary)).font(.callout).textSelection(.enabled)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(PuddleStyle.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
                Divider()
                Text(message.body.isEmpty ? message.snippet : message.body).font(.body).lineSpacing(5).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !message.attachments.isEmpty {
                    Divider()
                    Label("Attachments", systemImage: "paperclip").font(.headline)
                    ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, name in Text(name).font(.callout) }
                    Text("Choose Thread & Attachments to preview supported files, or open the original message for provider options.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(26).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }.background(PuddleStyle.panel.opacity(0.4)).id(message.id)
    }

    @ViewBuilder private func messageActions(_ message: MailMessage) -> some View {
        Button("Thread & Attachments") { inspecting = message }
        Button("Reply") { store.composeMail(replyTo: message) }
        Menu("More") {
            Button("Snooze in Puddle for 1 hour") { store.snoozeMail(message, until: Date().addingTimeInterval(3600)) }
            Button("Snooze in Puddle for 24 hours") { store.snoozeMail(message, until: Date().addingTimeInterval(86400)) }
            if showSnoozed { Button("Bring Back Now") { store.unsnoozeMail(message.id) } }
            Button("Sender Context / VIP…") { store.addSenderContext(message) }
            Button("Forward") { store.composeMail(replyTo: message, forward: true) }
            Button("Archive…") { store.proposeLabels(message, remove: ["INBOX"]) }
            Button(message.isUnread ? "Mark read…" : "Mark unread…") { store.proposeLabels(message, add: message.isUnread ? [] : ["UNREAD"], remove: message.isUnread ? ["UNREAD"] : []) }
            Button("Star…") { store.proposeLabels(message, add: ["STARRED"]) }
        }.fixedSize()
        Button(message.summary == nil ? "Summarize" : "Summarize again") { store.summarize(message.id) }
            .disabled(store.isThinking)
        Button("Ask Puddle") { store.askAboutMail(message.id) }.disabled(store.isThinking)
        Button("Create task…") { taskSource = message }
    }
}

extension PuddleStore {
    func snoozeMail(_ message: MailMessage, until: Date) {
        guard let account = mailAccount, until > Date() else { return }
        do {
            var task = AssistantTask(title: "Review email: \(String(message.subject.prefix(250)))", dueAt: until)
            task.notes = "Local mail snooze. Provider inbox stays unchanged.\n" + message.sourceURL.absoluteString
            let snooze = MailSnooze(messageID: message.id, provider: message.provider ?? .google, account: account, until: until, reminderID: task.id)
            try commit { next in
                let replaced = next.mailSnoozes.filter { $0.messageID == message.id && $0.account == account && $0.provider == snooze.provider }
                let ids = Set(replaced.map(\.reminderID)); next.tasks.removeAll { ids.contains($0.id) }
                next.mailSnoozes.removeAll { $0.messageID == message.id && $0.account == account && $0.provider == snooze.provider }
                next.mailSnoozes.append(snooze); next.tasks.append(task)
            }; scheduleReminders()
        } catch { fail(error) }
    }
    func unsnoozeMail(_ id: String) {
        do { try commit { next in
            let ids = Set(next.mailSnoozes.filter { $0.messageID == id && $0.account == mailAccount && $0.provider == next.settings.mailProvider }.map(\.reminderID))
            next.mailSnoozes.removeAll { $0.messageID == id && $0.account == mailAccount && $0.provider == next.settings.mailProvider }
            next.tasks.removeAll { ids.contains($0.id) }
        }; scheduleReminders() } catch { fail(error) }
    }
}
