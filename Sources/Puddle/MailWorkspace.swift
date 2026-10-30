import Foundation
import PuddleCore

enum MailFilter: String, CaseIterable {
    case all = "All", unread = "Unread", important = "Important"
}

enum MailWorkspace {
    static func messages(_ messages: [MailMessage], query: String, filter: MailFilter) -> [MailMessage] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return messages.filter { message in
            let inFilter = filter == .all || (filter == .unread ? message.isUnread : message.labels.contains("IMPORTANT"))
            let text = [message.subject, message.sender, message.recipient, message.snippet, message.body] + message.attachments
            return inFilter && (query.isEmpty || text.joined(separator: "\n").localizedCaseInsensitiveContains(query))
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }

    static func taskDraft(for message: MailMessage) -> TaskDraft {
        var draft = TaskDraft(AssistantTask(title: String(message.subject.prefix(300))))
        draft.notes = "From: \(message.sender)\nSubject: \(message.subject)\n\(message.sourceURL.absoluteString)"
        draft.notes = String(draft.notes.prefix(4000))
        return draft
    }
}
