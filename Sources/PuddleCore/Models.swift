import Foundation

public struct PuddleError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct MailMessage: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let threadID: String
    public let subject: String
    public let sender: String
    public let recipient: String
    public let date: Date
    public let snippet: String
    public let body: String
    public let labels: [String]
    public let attachments: [String]
    public let internetMessageID: String?
    public let provider: MailProvider?
    public let providerURL: URL?
    public let attachmentParts: [MailAttachment]?
    public let newsletter: NewsletterTarget?
    public var summary: String?
    public var isNew: Bool
    public var isUnread: Bool { labels.contains("UNREAD") }
    public var sourceURL: URL {
        if let providerURL, providerURL.scheme == "https", ["outlook.office.com", "outlook.office365.com", "outlook.live.com"].contains(providerURL.host ?? "") { return providerURL }
        if provider == .outlook { return URL(string: "https://outlook.office.com/mail/")! }
        let identifier = (threadID.isEmpty ? id : threadID).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: "https://mail.google.com/mail/u/0/#all/\(identifier)")!
    }

    public init(id: String, threadID: String = "", subject: String, sender: String,
                recipient: String = "", date: Date = Date(), snippet: String = "",
                body: String, labels: [String] = [], attachments: [String] = [],
                summary: String? = nil, isNew: Bool = false, internetMessageID: String? = nil, provider: MailProvider? = nil, providerURL: URL? = nil, attachmentParts: [MailAttachment]? = nil, newsletter: NewsletterTarget? = nil) {
        self.id = id; self.threadID = threadID; self.subject = subject
        self.sender = sender; self.recipient = recipient; self.date = date
        self.snippet = snippet; self.body = body; self.labels = labels
        self.attachments = attachments; self.summary = summary; self.isNew = isNew
        self.internetMessageID = internetMessageID
        self.provider = provider; self.providerURL = providerURL
        self.attachmentParts = attachmentParts
        self.newsletter = newsletter
    }
}

public struct ChatLine: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public let role: String
    public var content: String
    public var receipts: [ToolReceipt]?
    public var metrics: TurnMetrics?
    public var kind: String?
    public var profileName: String?
    public init(role: String, content: String) { self.role = role; self.content = content }
}

public struct ToolReceipt: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let tool: String
    public let detail: String
    public let status: String
    public var references: [SourceReference] = []
    public init(id: String, tool: String, detail: String, status: String = "completed", references: [SourceReference] = []) {
        self.id = id; self.tool = tool; self.detail = detail; self.status = status; self.references = references
    }
}

public struct SourceReference: Codable, Equatable, Sendable {
    public let title: String
    public let url: URL
    public init(title: String, url: URL) { self.title = title; self.url = url }
}

public struct TurnMetrics: Codable, Equatable, Sendable {
    public var totalSeconds: Double
    public var firstTokenSeconds: Double?
    public var extractionSeconds: Double
    public init(totalSeconds: Double, firstTokenSeconds: Double? = nil, extractionSeconds: Double = 0) {
        self.totalSeconds = totalSeconds; self.firstTokenSeconds = firstTokenSeconds; self.extractionSeconds = extractionSeconds
    }
}

public struct Conversation: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var createdAt = Date()
    public var lines: [ChatLine]
    public var title: String { String(lines.first(where: { $0.role == "user" })?.content.prefix(80) ?? "Conversation") }
    public init(id: UUID = UUID(), createdAt: Date = Date(), lines: [ChatLine]) {
        self.id = id; self.createdAt = createdAt; self.lines = lines
    }
}

public struct ActivityEvent: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public let text: String
    public init(_ text: String) { self.text = text }
}

public struct PuddleSettings: Codable, Sendable {
    public var splashAddress = "http://127.0.0.1:8000"
    public var pollSeconds = 60
    public var automaticallyCheck = true
    public var automaticallySummarize = false
    public var notifications = false
    public var automaticallyLearn = true
    public var contextTokens = 8192
    public var readRepliesAloud = false
    public var speechLanguage = "en-US"
    public var speechSpeed = 1.0
    public var networkDisabled = false
    public var archiveRetentionDays = 0
    public var lockOnBackground = false
    public var systemDictationEnabled = false
    public var dictationPunctuation = true
    public var dictationVocabulary: [String: String] = [:]
    public var mailProvider = MailProvider.google
    public var workdayStartHour = 9
    public var workdayEndHour = 17
    public var meetingBufferMinutes = 15
    public init() {}
    enum CodingKeys: String, CodingKey {
        case splashAddress, pollSeconds, automaticallyCheck, automaticallySummarize, notifications, automaticallyLearn, contextTokens
        case readRepliesAloud, speechLanguage, speechSpeed, networkDisabled, archiveRetentionDays, lockOnBackground
        case systemDictationEnabled, dictationPunctuation, dictationVocabulary
        case mailProvider
        case workdayStartHour, workdayEndHour, meetingBufferMinutes
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        splashAddress = try values.decodeIfPresent(String.self, forKey: .splashAddress) ?? splashAddress
        pollSeconds = max(30, min(3600, try values.decodeIfPresent(Int.self, forKey: .pollSeconds) ?? pollSeconds))
        automaticallyCheck = try values.decodeIfPresent(Bool.self, forKey: .automaticallyCheck) ?? automaticallyCheck
        automaticallySummarize = try values.decodeIfPresent(Bool.self, forKey: .automaticallySummarize) ?? automaticallySummarize
        notifications = try values.decodeIfPresent(Bool.self, forKey: .notifications) ?? notifications
        automaticallyLearn = try values.decodeIfPresent(Bool.self, forKey: .automaticallyLearn) ?? automaticallyLearn
        contextTokens = max(4096, min(131072, try values.decodeIfPresent(Int.self, forKey: .contextTokens) ?? contextTokens))
        readRepliesAloud = try values.decodeIfPresent(Bool.self, forKey: .readRepliesAloud) ?? readRepliesAloud
        speechLanguage = try values.decodeIfPresent(String.self, forKey: .speechLanguage) ?? speechLanguage
        speechSpeed = max(0.7, min(1.3, try values.decodeIfPresent(Double.self, forKey: .speechSpeed) ?? speechSpeed))
        networkDisabled = try values.decodeIfPresent(Bool.self, forKey: .networkDisabled) ?? false
        archiveRetentionDays = max(0, try values.decodeIfPresent(Int.self, forKey: .archiveRetentionDays) ?? 0)
        lockOnBackground = try values.decodeIfPresent(Bool.self, forKey: .lockOnBackground) ?? false
        systemDictationEnabled = try values.decodeIfPresent(Bool.self, forKey: .systemDictationEnabled) ?? false
        dictationPunctuation = try values.decodeIfPresent(Bool.self, forKey: .dictationPunctuation) ?? true
        dictationVocabulary = try values.decodeIfPresent([String: String].self, forKey: .dictationVocabulary) ?? [:]
        mailProvider = try values.decodeIfPresent(MailProvider.self, forKey: .mailProvider) ?? .google
        workdayStartHour = max(0, min(23, try values.decodeIfPresent(Int.self, forKey: .workdayStartHour) ?? 9))
        workdayEndHour = max(workdayStartHour + 1, min(24, try values.decodeIfPresent(Int.self, forKey: .workdayEndHour) ?? 17))
        meetingBufferMinutes = max(0, min(120, try values.decodeIfPresent(Int.self, forKey: .meetingBufferMinutes) ?? 15))
    }
}

public struct AppSnapshot: Codable, Sendable {
    public static let currentSchemaVersion = 8
    public var schemaVersion = currentSchemaVersion
    public var account: String?
    public var messages: [MailMessage] = []
    public var chat: [ChatLine] = []
    public var currentConversationID = UUID()
    public var currentConversationCreatedAt = Date()
    public var conversations: [Conversation] = []
    public var activity: [ActivityEvent] = []
    public var settings = PuddleSettings()
    public var lastSync: Date?
    public var mailHistoryID: String?
    public var calendarHasMore: Bool = false
    public var calendarLastSync: Date?
    public var profileLibrary = AssistantProfileLibrary()
    /// Compatibility accessor: existing work-context editing targets the selected role profile.
    public var profile: ExecutiveProfile {
        get { profileLibrary.context }
        set { profileLibrary.context = newValue }
    }
    public var memories: [MemoryNote] = []
    public var tasks: [AssistantTask] = []
    public var meetings: [MeetingNote] = []
    public var calendarEvents: [CalendarEvent] = []
    public var developerProjects: [DeveloperProject] = []
    public var activeDeveloperProjectID: UUID?
    public var developmentSessions: [DevelopmentSession] = []
    public var actionProposals: [ActionProposal] = []
    public var meetingCaptureRecoveries: [MeetingCaptureRecovery] = []
    public var browserErrands: [BrowserErrand] = []
    public var routines: [AssistantRoutine] = []
    public var routineRuns: [RoutineRun] = []
    public var outlookAccount: String?
    public var outlookMessages: [MailMessage] = []
    public var outlookLastSync: Date?
    public var knowledgeSources: [KnowledgeSource] = []
    public var knowledgeDocuments: [KnowledgeDocument] = []
    public var workProjects: [WorkProject] = []
    public var people: [PersonContext] = []
    public var workDecisions: [WorkDecision] = []
    public var mailSnoozes: [MailSnooze] = []
    public var assistantInstructions = "Be warm, practical, and concise. Help me think clearly and follow through."
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, account, messages, chat, currentConversationID, currentConversationCreatedAt, conversations, activity, settings, lastSync, mailHistoryID, calendarHasMore
        case memories, tasks, meetings, calendarEvents, assistantInstructions, calendarLastSync, profileLibrary
        case developerProjects, activeDeveloperProjectID, developmentSessions, actionProposals, meetingCaptureRecoveries
        case browserErrands
        case routines, routineRuns
        case outlookAccount, outlookMessages, outlookLastSync
        case knowledgeSources, knowledgeDocuments
        case workProjects, people, workDecisions
        case mailSnoozes
    }
    private enum LegacyProfileKey: String, CodingKey { case profile }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        guard (0...Self.currentSchemaVersion).contains(version) else { throw SnapshotVersionError() }
        account = try values.decodeIfPresent(String.self, forKey: .account)
        messages = try values.decodeIfPresent([MailMessage].self, forKey: .messages) ?? []
        chat = try values.decodeIfPresent([ChatLine].self, forKey: .chat) ?? []
        // Legacy snapshots already saved the active transcript outside the archive.
        // Its first message supplies a stable identity until the next save.
        currentConversationID = try values.decodeIfPresent(UUID.self, forKey: .currentConversationID) ?? chat.first?.id ?? UUID()
        currentConversationCreatedAt = try values.decodeIfPresent(Date.self, forKey: .currentConversationCreatedAt) ?? Date()
        conversations = try values.decodeIfPresent([Conversation].self, forKey: .conversations) ?? []
        activity = try values.decodeIfPresent([ActivityEvent].self, forKey: .activity) ?? []
        settings = try values.decodeIfPresent(PuddleSettings.self, forKey: .settings) ?? PuddleSettings()
        lastSync = try values.decodeIfPresent(Date.self, forKey: .lastSync)
        mailHistoryID = try values.decodeIfPresent(String.self, forKey: .mailHistoryID)
        calendarHasMore = try values.decodeIfPresent(Bool.self, forKey: .calendarHasMore) ?? false
        calendarLastSync = try values.decodeIfPresent(Date.self, forKey: .calendarLastSync)
        if let library = try values.decodeIfPresent(AssistantProfileLibrary.self, forKey: .profileLibrary) { profileLibrary = library }
        else {
            let legacy = try decoder.container(keyedBy: LegacyProfileKey.self)
            profileLibrary = AssistantProfileLibrary(legacyContext: try legacy.decodeIfPresent(ExecutiveProfile.self, forKey: .profile) ?? ExecutiveProfile())
        }
        memories = try values.decodeIfPresent([MemoryNote].self, forKey: .memories) ?? []
        tasks = try values.decodeIfPresent([AssistantTask].self, forKey: .tasks) ?? []
        meetings = try values.decodeIfPresent([MeetingNote].self, forKey: .meetings) ?? []
        calendarEvents = try values.decodeIfPresent([CalendarEvent].self, forKey: .calendarEvents) ?? []
        developerProjects = try values.decodeIfPresent([DeveloperProject].self, forKey: .developerProjects) ?? []
        activeDeveloperProjectID = try values.decodeIfPresent(UUID.self, forKey: .activeDeveloperProjectID)
        developmentSessions = try values.decodeIfPresent([DevelopmentSession].self, forKey: .developmentSessions) ?? []
        actionProposals = try values.decodeIfPresent([ActionProposal].self, forKey: .actionProposals) ?? []
        meetingCaptureRecoveries = try values.decodeIfPresent([MeetingCaptureRecovery].self, forKey: .meetingCaptureRecoveries) ?? []
        browserErrands = try values.decodeIfPresent([BrowserErrand].self, forKey: .browserErrands) ?? []
        routines = try values.decodeIfPresent([AssistantRoutine].self, forKey: .routines) ?? []
        routineRuns = try values.decodeIfPresent([RoutineRun].self, forKey: .routineRuns) ?? []
        outlookAccount = try values.decodeIfPresent(String.self, forKey: .outlookAccount)
        outlookMessages = try values.decodeIfPresent([MailMessage].self, forKey: .outlookMessages) ?? []
        outlookLastSync = try values.decodeIfPresent(Date.self, forKey: .outlookLastSync)
        knowledgeSources = try values.decodeIfPresent([KnowledgeSource].self, forKey: .knowledgeSources) ?? []
        knowledgeDocuments = try values.decodeIfPresent([KnowledgeDocument].self, forKey: .knowledgeDocuments) ?? []
        workProjects = try values.decodeIfPresent([WorkProject].self, forKey: .workProjects) ?? []
        people = try values.decodeIfPresent([PersonContext].self, forKey: .people) ?? []
        workDecisions = try values.decodeIfPresent([WorkDecision].self, forKey: .workDecisions) ?? []
        mailSnoozes = try values.decodeIfPresent([MailSnooze].self, forKey: .mailSnoozes) ?? []
        guard Set(actionProposals.map(\.id)).count == actionProposals.count else { throw PuddleError("Saved actions contain repeated identifiers.") }
        guard Set(developerProjects.map(\.id)).count == developerProjects.count,
              Set(developmentSessions.map(\.id)).count == developmentSessions.count else { throw PuddleError("Saved development work contains repeated identifiers.") }
        if !developerProjects.contains(where: { $0.id == activeDeveloperProjectID }) { activeDeveloperProjectID = nil }
        if let instructions = try values.decodeIfPresent(String.self, forKey: .assistantInstructions) {
            assistantInstructions = instructions
        }
    }

    public mutating func remember(title: String, content: String, source: String? = nil, sourceMessageID: UUID? = nil) {
        let identity = MemoryLearning.identity(title)
        if let index = memories.firstIndex(where: { MemoryLearning.identity($0.title) == identity }) {
            memories[index].content = content; memories[index].updatedAt = Date()
            memories[index].source = source; memories[index].sourceMessageID = sourceMessageID
        } else { memories.append(MemoryNote(title: title, content: content, source: source, sourceMessageID: sourceMessageID)) }
    }

    public mutating func startNewConversation() {
        if !chat.isEmpty {
            conversations.removeAll { $0.id == currentConversationID }
            conversations.insert(Conversation(id: currentConversationID, createdAt: currentConversationCreatedAt, lines: chat), at: 0)
        }
        chat = []; currentConversationID = UUID(); currentConversationCreatedAt = Date()
    }

    public mutating func openConversation(_ id: UUID) {
        guard id != currentConversationID else { return }
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let previous = conversations.remove(at: index)
        startNewConversation(); chat = previous.lines
        currentConversationID = previous.id; currentConversationCreatedAt = previous.createdAt
    }

    /// History includes the saved active transcript immediately, even before New Conversation.
    public var conversationHistory: [Conversation] {
        guard !chat.isEmpty else { return conversations }
        return [Conversation(id: currentConversationID, createdAt: currentConversationCreatedAt, lines: chat)] +
            conversations.filter { $0.id != currentConversationID }
    }

    public func matchingConversations(_ query: String) -> [Conversation] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let history = conversationHistory
        guard !query.isEmpty else { return history }
        var matches: [Conversation] = []
        for conversation in history {
            guard !Task.isCancelled else { break }
            if conversation.lines.contains(where: { !Task.isCancelled && $0.content.localizedCaseInsensitiveContains(query) }) { matches.append(conversation) }
        }
        return matches
    }

    public mutating func deleteConversation(_ id: UUID) {
        if id == currentConversationID {
            chat = []; currentConversationID = UUID(); currentConversationCreatedAt = Date()
        }
        conversations.removeAll { $0.id == id }
    }

    public mutating func recordReceipt(_ receipt: ToolReceipt, userID: UUID?) {
        guard let userID, let index = chat.firstIndex(where: { $0.id == userID }) else { return }
        var receipts = chat[index].receipts ?? []
        receipts.removeAll { $0.id == receipt.id }; receipts.append(receipt)
        chat[index].receipts = receipts
    }

    /// Reminders are durable and fire once, including overdue items after restart.
    public mutating func dueReminders(now: Date = Date()) -> [AssistantTask] {
        var due: [AssistantTask] = []
        for index in tasks.indices {
            if !tasks[index].completed, tasks[index].notifiedAt == nil,
               let date = tasks[index].dueAt, date <= now {
                tasks[index].notifiedAt = now
                due.append(tasks[index])
            }
        }
        return due
    }

    /// The first sync establishes a baseline. Later syncs identify new arrivals,
    /// preserve summaries, and remove mail that is no longer in the fetched inbox.
    @discardableResult
    public mutating func merge(_ fetched: [MailMessage], now: Date = Date(), newMessageIDs: Set<String>? = nil) -> [MailMessage] {
        let existing = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var unique: [String: MailMessage] = [:]
        for var message in fetched {
            message.summary = existing[message.id]?.summary
            message.isNew = existing[message.id]?.isNew ?? (lastSync != nil && (newMessageIDs?.contains(message.id) ?? true))
            unique[message.id] = message
        }
        let arrivals = unique.values.filter { existing[$0.id] == nil && lastSync != nil && (newMessageIDs?.contains($0.id) ?? true) }
        messages = unique.values.sorted { $0.date > $1.date }
        lastSync = now
        return arrivals.sorted { $0.date > $1.date }
    }
}

public struct SnapshotVersionError: LocalizedError {
    public var errorDescription: String? { "This state was saved by a newer Puddle version. Open it with that version; the file has not been changed." }
}

public protocol SnapshotPersistence: Sendable {
    func load() throws -> AppSnapshot
    func loadResult() throws -> SnapshotLoadResult
    func save(_ state: AppSnapshot) throws
}

public struct SnapshotLoadResult: Sendable {
    public let snapshot: AppSnapshot
    public let notice: String?
    public init(snapshot: AppSnapshot, notice: String? = nil) { self.snapshot = snapshot; self.notice = notice }
}

extension SnapshotPersistence {
    public func loadResult() throws -> SnapshotLoadResult { SnapshotLoadResult(snapshot: try load()) }
}

public struct SnapshotStore: SnapshotPersistence {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    private var file: URL { directory.appendingPathComponent("state.json") }
    private var backup: URL { directory.appendingPathComponent("state.backup.json") }

    public func load() throws -> AppSnapshot {
        try loadResult().snapshot
    }

    public func loadResult() throws -> SnapshotLoadResult {
        guard FileManager.default.fileExists(atPath: file.path) else {
            if FileManager.default.fileExists(atPath: backup.path) {
                return SnapshotLoadResult(snapshot: try JSONDecoder().decode(AppSnapshot.self, from: Data(contentsOf: backup)),
                                          notice: "The main state file was missing. Puddle loaded its previous-state backup; the latest changes may be missing.")
            }
            return SnapshotLoadResult(snapshot: AppSnapshot())
        }
        do { return SnapshotLoadResult(snapshot: try JSONDecoder().decode(AppSnapshot.self, from: Data(contentsOf: file))) }
        catch let error as SnapshotVersionError { throw error }
        catch {
            guard let data = try? Data(contentsOf: backup),
                  let restored = try? JSONDecoder().decode(AppSnapshot.self, from: data) else {
                throw PuddleError("Puddle could not read its saved state. Your files are preserved. Restore state.json from a backup and choose Retry Loading State in Settings.")
            }
            let preserved = directory.appendingPathComponent("state-unreadable-\(UUID().uuidString).json")
            try FileManager.default.moveItem(at: file, to: preserved)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preserved.path)
            try write(data, to: file)
            return SnapshotLoadResult(snapshot: restored, notice: "Puddle restored its previous-state backup. The latest changes may be missing. The unreadable original was preserved as \(preserved.lastPathComponent).")
        }
    }

    public func save(_ state: AppSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(state)
        // Never replace unreadable or future-version data with an empty startup state.
        if FileManager.default.fileExists(atPath: file.path) {
            let previous = try Data(contentsOf: file)
            _ = try JSONDecoder().decode(AppSnapshot.self, from: previous)
            try write(previous, to: backup)
        }
        try write(data, to: file)
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
