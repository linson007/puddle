import Foundation

struct ConversationDraft: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let text: String
    let revision = UUID()
}

extension PuddleStore {
    var conversationDraft: String { conversationDrafts[state.currentConversationID]?.text ?? "" }
    var otherConversationDrafts: [ConversationDraft] {
        conversationDrafts.values.filter { $0.id != state.currentConversationID }.sorted { $0.createdAt > $1.createdAt }
    }
    var hasUnsentConversationDrafts: Bool {
        !conversationDrafts.isEmpty || savedPrivateConversationDrafts?.isEmpty == false || savedDemoConversationDrafts?.isEmpty == false
    }

    func setConversationDraft(_ text: String) {
        guard !isLocked, !isShuttingDown else { return }
        let id = state.currentConversationID
        if text.isEmpty { conversationDrafts.removeValue(forKey: id) }
        else { conversationDrafts[id] = ConversationDraft(id: id, createdAt: state.currentConversationCreatedAt, text: text) }
    }

    func sendConversationDraft() async {
        guard let draft = conversationDrafts[state.currentConversationID] else { return }
        let access = workspaceAccessRevision
        // A save suspends. Text typed meanwhile, or a new private/demo workspace,
        // must never be cleared by the completion of this submission.
        if await ask(draft.text), access == workspaceAccessRevision,
           conversationDrafts[draft.id]?.revision == draft.revision {
            conversationDrafts.removeValue(forKey: draft.id)
        }
    }
}
