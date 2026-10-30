import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import PuddleCore

struct MailInspectorView: View {
    @ObservedObject var store: PuddleStore
    let message: MailMessage
    @Environment(\.dismiss) private var dismiss
    @State private var thread: [MailMessage] = []
    @State private var parts: [MailAttachment] = []
    @State private var selected: MailAttachment?
    @State private var data: Data?
    @State private var busy = false
    @State private var error: String?
    @State private var hasMore = false
    @State private var attachmentMessageID = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Conversation & attachments").font(.title2.bold()); Spacer(); Button("Close") { dismiss() } }
            Text(message.subject).font(.headline).textSelection(.enabled)
            if busy { ProgressView("Loading from your provider…").controlSize(.small) }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Thread · \(thread.count) messages").font(.headline)
                        Text("Attachments are fetched only when you choose one. This view loads up to 250 Gmail or 500 Outlook messages within a bounded response size.").font(.caption).foregroundStyle(.secondary)
                        if hasMore { Label("This conversation exceeds the local limit. Open the provider for the remaining messages.", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                        ForEach(thread) { item in
                            DisclosureGroup("\(item.sender) · \(item.date.formatted())") {
                                Text(item.body).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.callout)
                        }
                        Divider(); Text("Attachments").font(.headline)
                        Picker("Message", selection: $attachmentMessageID) {
                            ForEach(thread) { item in Text("\(item.sender) · \(item.date.formatted())").tag(item.id) }
                        }.onChange(of: attachmentMessageID) { _, _ in Task { await loadParts() } }
                        if parts.isEmpty { Text("No downloadable attachments found.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(parts) { part in
                            Button("\(part.name) · \(ByteCountFormatter.string(fromByteCount: Int64(part.bytes), countStyle: .file))") { Task { await load(part) } }.disabled(busy)
                        }
                    }.padding(12)
                }.frame(minWidth: 280, idealWidth: 330)
                VStack(alignment: .leading, spacing: 12) {
                    if let data, let selected {
                        Text(selected.name).font(.headline)
                        AttachmentPreview(data: data, attachment: selected)
                        if let text = analysisText(data, selected) {
                            Button("Ask Puddle About Attachment") {
                                dismiss()
                                Task { @MainActor in await Task.yield(); store.askReference(question: "Summarize this attachment. List only explicit requested follow-ups; label any suggestions separately: \(selected.name)", reference: "Source: \(message.sourceURL.absoluteString)\nAttachment: \(selected.name)\nExtracted text (may be shortened):\n\(text)", references: [SourceReference(title: selected.name + " · source message", url: message.sourceURL)]) }
                            }.disabled(store.isThinking)
                        }
                        Button("Save Attachment…") { save(data, named: selected.name) }
                    } else { ContentUnavailableView("Choose an attachment", systemImage: "paperclip", description: Text("PDF, image, and plain-text previews stay on this Mac. Other files can be saved for a compatible app.")) }
                }.padding(12).frame(minWidth: 320)
            }
        }.padding(22).frame(width: 920, height: 680).task { await loadConversation() }
    }
    private func loadConversation() async {
        busy = true; defer { busy = false }
        let account = (message.provider == .outlook ? store.outlookAccount?.email : store.state.account)
        do {
            if message.provider == .outlook {
                let page = try await OutlookMailClient(session: store.outlook, transport: store.transport).thread(message.threadID)
                thread = page.messages; hasMore = page.hasMore
            } else {
                let page = try await GmailClient(session: store.google, transport: store.transport).thread(message.threadID.isEmpty ? message.id : message.threadID)
                thread = page.messages; hasMore = page.hasMore
            }
            try Task.checkCancellation()
            guard account == (message.provider == .outlook ? store.outlookAccount?.email : store.state.account) else { thread = []; parts = []; throw PuddleError("The account changed. Reopen this message from the current inbox.") }
            attachmentMessageID = thread.contains(where: { $0.id == message.id }) ? message.id : thread.first?.id ?? ""
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func loadParts() async {
        guard !attachmentMessageID.isEmpty else { return }
        let id = attachmentMessageID, account = message.provider == .outlook ? store.outlookAccount?.email : store.state.account
        selected = nil; data = nil; parts = []
        do {
            let found = message.provider == .outlook ? try await OutlookMailClient(session: store.outlook, transport: store.transport).attachments(messageID: id) : thread.first(where: { $0.id == id })?.attachmentParts ?? []
            try Task.checkCancellation()
            guard attachmentMessageID == id, account == (message.provider == .outlook ? store.outlookAccount?.email : store.state.account) else { return }
            parts = found
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func load(_ part: MailAttachment) async {
        busy = true; defer { busy = false }; error = nil
        let account = message.provider == .outlook ? store.outlookAccount?.email : store.state.account
        do {
            let id = attachmentMessageID
            let bytes = message.provider == .outlook ? try await OutlookMailClient(session: store.outlook, transport: store.transport).attachment(part, messageID: id) : try await GmailClient(session: store.google, transport: store.transport).attachment(part, messageID: id)
            try Task.checkCancellation()
            guard attachmentMessageID == id, account == (message.provider == .outlook ? store.outlookAccount?.email : store.state.account) else { data = nil; selected = nil; throw PuddleError("The account or selected message changed. Reopen the attachment.") }
            selected = part; data = bytes
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func analysisText(_ bytes: Data, _ attachment: MailAttachment) -> String? {
        let value: String?
        if attachment.mimeType == "application/pdf" { value = PDFDocument(data: bytes)?.string }
        else if attachment.mimeType.hasPrefix("text/") { value = String(data: bytes, encoding: .utf8).map { attachment.mimeType == "text/html" ? MailText.fromHTML($0) : $0 } }
        else { value = nil }
        return value.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String($0.prefix(40_000)) }
    }
    private func save(_ bytes: Data, named name: String) {
        let access: UUID
        do { access = try store.workspaceAccess() } catch { self.error = error.localizedDescription; return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = URL(fileURLWithPath: name).lastPathComponent
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try store.checkWorkspaceAccess(access)
                let origin = thread.first(where: { $0.id == attachmentMessageID })?.sourceURL ?? message.sourceURL
                try RemoteAttachmentFile.write(bytes, to: url, origin: origin)
            }
            catch { self.error = error.localizedDescription }
        }
    }
}
private struct AttachmentPreview: View {
    let data: Data
    let attachment: MailAttachment
    var body: some View {
        Group {
            if attachment.mimeType == "application/pdf", let document = PDFDocument(data: data) { LocalPDFPreview(document: document) }
            else if attachment.mimeType.hasPrefix("image/"), let image = NSImage(data: data) { ScrollView([.horizontal, .vertical]) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 600) } }
            else if attachment.mimeType.hasPrefix("text/"), let text = String(data: data, encoding: .utf8) {
                ScrollView { Text(String((attachment.mimeType == "text/html" ? MailText.fromHTML(text) : text).prefix(100_000))).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            } else { ContentUnavailableView("Preview unavailable", systemImage: "doc", description: Text("Save this attachment to open it in a compatible app.")) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
private struct LocalPDFPreview: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.document = document; return view }
    func updateNSView(_ view: PDFView, context: Context) { if view.document !== document { view.document = document } }
}
