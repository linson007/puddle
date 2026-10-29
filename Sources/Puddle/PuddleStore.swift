import AppKit
import Combine
import Foundation
import PuddleCore
import UserNotifications

@MainActor
final class PuddleStore: ObservableObject {
    enum Section: String, CaseIterable {
        case chat = "Puddle", history = "History", meetings = "Meetings", tasks = "Tasks", memory = "Memory", connections = "Connections"
        var icon: String {
            switch self {
            case .chat: "bubble.left.and.bubble.right"
            case .history: "clock.arrow.circlepath"
            case .meetings: "video"
            case .tasks: "checklist"
            case .memory: "brain"
            case .connections: "point.3.connected.trianglepath.dotted"
            }
        }
    }
    struct Approval: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
    }
    @Published var state = AppSnapshot()
    @Published var section = Section.chat
    @Published var settingsTab = "localAI"
    @Published var selectedID: String?
    @Published var showSetup = false
    @Published var errorMessage: String?
    @Published var connected = false
    @Published var configured = false
    @Published var grantedScopes: Set<String> = []
    @Published var isSigningIn = false
    @Published var isDisconnecting = false
    @Published var googleSignInStatus = ""
    @Published var googleSignInBrowser = GoogleSignInBrowser(rawValue: UserDefaults.standard.string(forKey: "googleSignInBrowser") ?? "") ?? .safari {
        didSet { UserDefaults.standard.set(googleSignInBrowser.rawValue, forKey: "googleSignInBrowser") }
    }
    @Published var isSyncing = false
    @Published var isRefreshingCalendar = false
    @Published var isThinking = false
    @Published var isTestingSplash = false
    @Published var splashModel: String?
    @Published var demo = false
    @Published var apiKey = ""
    @Published var toolActivities: [String] = []
    @Published var pendingApproval: Approval?
    @Published var storageAvailable = false
    @Published var streamingReply = ""
    @Published var speakingMessageID: UUID?
    private var speechGeneration = UUID()
    private let speechPlayer: any SpeechPlaying
    let voiceInput: VoiceInputController
    let meetingCapture: MeetingCaptureController
    let meetAttendance: MeetAttendanceController
    let meetingWorkspace = MeetingWorkspace()
    let suppliedMeetingSummarizer: (any MeetingSummarizing)?
    var meetingSummaryTask: Task<Void, Never>?
    var meetingSummaryGeneration = UUID()
    private let urlOpener: any ExternalURLOpening
    @Published var meetingLinkStatus: String?
    private var turnMetrics: TurnMetrics?
    private var modelConnection: ModelConnection?
    private let reminderScheduler: any ReminderScheduling
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private var started = false
    private let cache: any SnapshotPersistence
    private let secrets: any SecretStore
    private let google: GoogleSession
    private let transport: any HTTPTransport
    private var lastSavedState = AppSnapshot()
    private var pollingTask: Task<Void, Never>?
    private var reminderTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var aiTask: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    private var signIn: LoopbackSignIn?
    private var generation = UUID()
    private var aiGeneration = UUID()
    private var splashRevision = UUID()
    private var nextMailCheck = Date.distantPast
    private var mailFailures = 0

    var selectedMessage: MailMessage? { state.messages.first { $0.id == selectedID } }
    var newCount: Int { state.messages.filter(\.isNew).count }
    var mailConnected: Bool { demo || (connected && grantedScopes.contains(OAuthFlow.scope)) }
    var calendarConnected: Bool {
        demo || (connected && (grantedScopes.contains(OAuthFlow.calendarScope) ||
                               grantedScopes.contains("https://www.googleapis.com/auth/calendar.readonly")))
    }
    var availableTools: [AgentTool] {
        [.memories, .tasks, .remind] + (state.settings.automaticallyLearn ? [.remember] : []) +
        (!isSigningIn && mailConnected ? [.searchMail] : []) + (!isSigningIn && calendarConnected ? [.calendar] : [])
    }

    init(directory suppliedDirectory: URL? = nil, cache: (any SnapshotPersistence)? = nil,
         secrets: any SecretStore = KeychainStore(), google: GoogleSession? = nil,
         transport: any HTTPTransport = URLSessionTransport(), reminderScheduler: (any ReminderScheduling)? = nil,
         speechPlayer: (any SpeechPlaying)? = nil, speechCapture: (any SpeechCapturing)? = nil,
         urlOpener: (any ExternalURLOpening)? = nil, meetingSummarizer: (any MeetingSummarizing)? = nil,
         meetingAudioCapture: (any MeetingAudioCapturing)? = nil, meetBrowserLauncher: (any MeetBrowserLaunching)? = nil) {
        let arguments = ProcessInfo.processInfo.arguments
        demo = arguments.contains("--demo")
        let directory: URL
        if let suppliedDirectory { directory = suppliedDirectory }
        else if let index = arguments.firstIndex(of: "--data-dir"), arguments.indices.contains(index + 1) {
            directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Puddle", isDirectory: true)
        }
        self.cache = cache ?? SnapshotStore(directory: directory)
        self.secrets = secrets; self.transport = transport
        self.reminderScheduler = reminderScheduler ?? ReminderScheduler()
        self.speechPlayer = speechPlayer ?? SystemSpeechPlayer()
        self.voiceInput = VoiceInputController(capture: speechCapture ?? SystemSpeechCapture())
        self.meetingCapture = MeetingCaptureController(capture: meetingAudioCapture ?? SystemMeetingAudioCapture())
        self.meetAttendance = MeetAttendanceController(launcher: meetBrowserLauncher ?? ManagedMeetBrowser(directory: directory.appendingPathComponent("MeetBrowser", isDirectory: true)))
        self.urlOpener = urlOpener ?? WorkspaceURLOpener()
        self.suppliedMeetingSummarizer = meetingSummarizer
        self.google = google ?? GoogleSession(store: secrets, transport: transport)
        self.meetingCapture.onCompletion = { [weak self] id, text in
            guard let self, self.state.meetings.contains(where: { $0.id == id }) else { return }
            self.meetingWorkspace.pendingImport = PendingTranscriptImport(noteID: id,
                result: ImportedTranscript(text: text, sourceName: "Live meeting transcription"))
        }
        self.meetAttendance.onEnded = { [weak self] id in
            guard let self, self.meetingCapture.noteID == id else { return }; self.meetingCapture.stop()
        }
    }

    func start() async {
        guard !started else { return }
        started = true
        if demo { enterDemo(); return }
        guard loadState() else { return }
        do {
            apiKey = try secrets.read("splash-key").map { String(decoding: $0, as: UTF8.self) } ?? ""
        } catch { fail(error) }
        do {
            try await prepareGoogleClient()
            connected = try await google.hasCredentials()
            grantedScopes = try await google.grantedScopes()
            if let account = try await google.account() {
                if state.account != account.email { state.messages = []; state.calendarEvents = []; state.lastSync = nil; state.mailHistoryID = nil; state.calendarHasMore = false }
                state.account = account.email
            }
        } catch { fail(error) }
        processReminders()
        scheduleReminders()
        startPolling()
        Task { await testSplash(silent: true) }
        if mailConnected || calendarConnected { refresh() }
    }

    private func loadState() -> Bool {
        do {
            let loaded = try cache.loadResult()
            state = loaded.snapshot; lastSavedState = state; storageAvailable = true; errorMessage = loaded.notice
            return true
        } catch { storageAvailable = false; fail(error); return false }
    }

    func retryLoadingState() async { started = false; await start() }

    func openMeetingLink(_ address: String) {
        meetingLinkStatus = nil
        guard !demo else { errorMessage = "Demo mode does not open real meeting links."; return }
        do {
            let link = try MeetingJoinLink(address)
            guard urlOpener.open(link.url) else { throw PuddleError("The meeting link could not open. Check your browser or meeting app and try again.") }
            errorMessage = nil
            meetingLinkStatus = "Opened the \(link.provider.title) join screen. Finish joining in your browser or meeting app."
            record("Opened a \(link.provider.title) join screen.")
            if storageAvailable { persist() }
        } catch { meetingLinkStatus = nil; fail(error) }
    }

    func importClient() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "Choose the JSON for your Google OAuth Desktop app client."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let client = try GoogleClientConfiguration.load(from: url)
                if connected { throw PuddleError("Disconnect Google before replacing the OAuth client.") }
                try await google.configure(client)
                configured = true
            } catch { fail(error) }
        }
    }

    private func prepareGoogleClient() async throws {
        if try await google.configuration() != nil { configured = true; return }
        let client = try Bundle.main.url(forResource: "GoogleClient", withExtension: "json")
            .map { try GoogleClientConfiguration.load(from: $0) }
        configured = try await google.configureIfNeeded(client)
    }

    /// Normal connection is a single entry point. Owners can provision a client
    /// once; permission choices remain available for an existing connection.
    func requestGoogleConnection() {
        guard !isSigningIn else { return }
        errorMessage = nil
        if connected { showSetup = true; return }
        connect()
    }

    func connect(scopes: [String] = [OAuthFlow.scope, OAuthFlow.calendarScope]) {
        guard !isSigningIn, !isDisconnecting, !scopes.isEmpty else { return }
        if demo { leaveDemo() }
        generation = UUID(); stopAI(); syncTask?.cancel(); pollingTask?.cancel(); isSyncing = false; isRefreshingCalendar = false
        let expected = generation
        isSigningIn = true
        googleSignInStatus = "Preparing Google sign-in…"
        signInTask = Task {
            defer {
                isSigningIn = false; signIn = nil; googleSignInStatus = ""
                if generation == expected { startPolling() }
            }
            do {
                try await prepareGoogleClient()
                try Task.checkCancellation()
                guard let client = try await google.configuration() else { showSetup = true; return }
                googleSignInStatus = "Finish sign-in in your browser"
                let flow = LoopbackSignIn(); signIn = flow
                try await flow.signIn(client: client, session: google, scopes: scopes, browser: googleSignInBrowser)
                try Task.checkCancellation()
                guard generation == expected else { throw CancellationError() }
                googleSignInStatus = "Loading your email and calendar…"
                let scopes = try await google.grantedScopes(), account = try await google.account()
                try Task.checkCancellation()
                guard generation == expected else { throw CancellationError() }
                stopAI(); connected = true; grantedScopes = scopes; errorMessage = nil
                if let account {
                    if state.account != account.email {
                        state.messages = []; state.calendarEvents = []; state.lastSync = nil; state.mailHistoryID = nil; state.calendarHasMore = false; selectedID = nil
                    }
                    state.account = account.email
                }
                if !mailConnected { state.messages = []; state.lastSync = nil; state.mailHistoryID = nil; selectedID = nil }
                if !calendarConnected { state.calendarEvents = []; state.calendarHasMore = false }
                record("Google connected with selected read-only permissions.")
                guard persist() else { connected = false; grantedScopes = []; return }
                if mailConnected { await sync() }
                if calendarConnected { await refreshCalendar() }
                startPolling(); showSetup = false
                NSApplication.shared.activate(ignoringOtherApps: true)
            } catch is CancellationError {} catch { if !Task.isCancelled { fail(error) } }
        }
    }

    func cancelSignIn() { signInTask?.cancel(); signIn?.cancel() }

    func disconnect() {
        guard !isDisconnecting else { return }
        cancelSignIn(); generation = UUID(); stopAI(); syncTask?.cancel(); pollingTask?.cancel()
        isDisconnecting = true
        connected = false; grantedScopes = []; isSyncing = false; isRefreshingCalendar = false; selectedID = nil
        Task {
            defer { isDisconnecting = false }
            do {
                try await google.disconnect()
                state.account = nil; state.messages = []; state.calendarEvents = []; state.lastSync = nil; state.mailHistoryID = nil; state.calendarHasMore = false
                record("Google disconnected. Assistant conversation, memory, and tasks retained.")
                persist(); startPolling()
            } catch { fail(error) }
        }
    }

    func refresh() {
        processReminders()
        guard !demo, !isSyncing, !isRefreshingCalendar else { return }
        syncTask = Task {
            if mailConnected { await sync() }
            if calendarConnected { await refreshCalendar() }
        }
    }

    func sync() async {
        guard mailConnected, !demo, !isSyncing else { return }
        isSyncing = true
        let expected = generation
        defer { if expected == generation { isSyncing = false } }
        do {
            let source = GmailClient(session: google, transport: transport)
            let result = try await source.synchronize(cached: state.messages, historyID: state.mailHistoryID)
            let email = result.account, messages = result.messages
            try Task.checkCancellation()
            guard generation == expected, connected else { return }
            if let previous = state.account, previous != email {
                state.messages = []; state.lastSync = nil; state.mailHistoryID = nil; selectedID = nil
            }
            state.account = email
            let arrivals = state.merge(messages, newMessageIDs: result.newMessageIDs)
            state.mailHistoryID = result.historyID
            mailFailures = 0; nextMailCheck = .distantPast
            record("Checked Gmail: \(messages.count) recent inbox messages, \(arrivals.count) new.")
            guard persist() else { return }
            if !arrivals.isEmpty, state.settings.notifications {
                await notify(title: "New mail", body: "\(arrivals.count) new messages are available to Puddle.")
            }
            if state.settings.automaticallySummarize, !isThinking {
                for message in arrivals.prefix(3) {
                    guard generation == expected, !Task.isCancelled else { break }
                    summarize(message.id); await aiTask?.value
                }
            }
        } catch is CancellationError {} catch {
            if expected == generation {
                mailFailures += 1
                let backoff = max((error as? HTTPServiceError)?.retryAfter ?? 0, min(900, 30 * pow(2, Double(min(mailFailures, 5)))))
                nextMailCheck = Date().addingTimeInterval(backoff); fail(error)
            }
        }
    }

    func refreshCalendar() async {
        guard calendarConnected, !demo, !isRefreshingCalendar else { return }
        isRefreshingCalendar = true
        let expected = generation
        defer { if expected == generation { isRefreshingCalendar = false } }
        do {
            let page = try await GoogleCalendarClient(session: google, transport: transport).upcomingPage(days: 7)
            try Task.checkCancellation()
            guard expected == generation, calendarConnected else { return }
            state.calendarEvents = page.events; state.calendarHasMore = page.hasMore
            record("Refreshed upcoming calendar events."); persist()
        } catch is CancellationError {} catch { if expected == generation { fail(error) } }
    }

    func startPolling() {
        pollingTask?.cancel(); reminderTask?.cancel()
        reminderTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.processReminders()
            }
        }
        guard !demo else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(max(30, self?.state.settings.pollSeconds ?? 60))) } catch { return }
                guard let self else { return }
                if self.state.settings.automaticallyCheck, self.mailConnected, Date() >= self.nextMailCheck { await self.sync() }
            }
        }
    }

    func ask(_ question: String) {
        submit(question, retryLine: nil)
    }

    func retryLastQuestion() {
        guard !isThinking, let index = state.chat.lastIndex(where: { $0.role == "user" }) else { return }
        let line = state.chat[index]
        let reminders = state.chat.dropFirst(index + 1).filter { $0.kind == "reminder" }
        state.chat = Array(state.chat.prefix(index + 1)) + reminders
        submit(line.content, retryLine: line)
    }

    func openConversation(_ id: UUID) {
        guard state.conversationHistory.contains(where: { $0.id == id }) else { return }
        if id != state.currentConversationID { stopAI(); state.openConversation(id); persist() }
        section = .chat
    }
    func deleteConversation(_ id: UUID) {
        if id == state.currentConversationID { stopAI() }
        state.deleteConversation(id); persist()
    }

    private func submit(_ question: String, retryLine: ChatLine?) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isThinking else { return }
        errorMessage = nil
        let history = retryLine == nil ? state.chat : Array(state.chat.prefix { $0.id != retryLine!.id })
        let userLine = retryLine ?? ChatLine(role: "user", content: question)
        if retryLine == nil { state.chat.append(userLine) }
        section = .chat
        guard persist() else { return }
        beginAI { [self] in
            let expected = aiGeneration
            var context = AgentContext(instructions: state.assistantInstructions, memories: state.memories,
                                       mailConnected: mailConnected, calendarConnected: calendarConnected,
                                       memoryLearning: state.settings.automaticallyLearn)
            let completed = userLine.receipts?.filter { $0.status == "completed" && $0.tool == AgentTool.remind.rawValue } ?? []
            context.priorActions = completed.map(\.detail)
            let tools = availableTools.filter { completed.isEmpty || $0 != .remind }
            let answer: String
            if demo {
                answer = completed.isEmpty ? try await demoAnswer(question) : "Your earlier task is already saved. No additional reminder was created."
            }
            else {
                answer = try await ConversationService(connection: connection()).respond(
                    question: question, history: history, context: context, tools: tools, contextTokens: state.settings.contextTokens,
                    learn: { [self] updates in try await self.applyLearning(updates, userID: userLine.id, turn: expected) },
                    execute: { [self] call in try await self.execute(call, userLine: userLine, turn: expected) },
                    onActivity: { [self] name in await self.showActivity(name, turn: expected) },
                    onPartial: { [self] text in await self.showPartial(text, turn: expected) },
                    onMetrics: { [self] metrics in await self.saveMetrics(metrics, turn: expected) })
            }
            try checkTurn(expected)
            var reply = ChatLine(role: "assistant", content: answer); reply.metrics = turnMetrics
            state.chat.append(reply); streamingReply = ""
            record(demo ? "Completed a demo conversation turn." : "Completed a local assistant turn.")
            if persist(), state.settings.readRepliesAloud { readAloud(reply) }
        }
    }

    private func checkTurn(_ expected: UUID?) throws {
        try Task.checkCancellation()
        if let expected, expected != aiGeneration { throw CancellationError() }
    }
    private func showPartial(_ text: String, turn: UUID) { if aiGeneration == turn { streamingReply = text } }
    private func showActivity(_ text: String, turn: UUID) { if aiGeneration == turn { addToolActivity(text) } }
    private func saveMetrics(_ metrics: TurnMetrics, turn: UUID) { if aiGeneration == turn { turnMetrics = metrics } }
    private func applyLearning(_ updates: [MemoryUpdate], userID: UUID, turn: UUID) throws -> [MemoryNote] {
        try checkTurn(turn)
        try commit { snapshot in
            for update in updates { snapshot.remember(title: update.title, content: update.content, source: update.source, sourceMessageID: userID) }
        }
        record("Learned \(updates.count) personal facts from conversation.")
        return state.memories
    }

    func connection() throws -> ModelConnection {
        if let modelConnection { return modelConnection }
        let connection = ModelConnection(client: try splash()); modelConnection = connection; return connection
    }

    private func execute(_ call: AgentToolCall, userLine: ChatLine? = nil, turn: UUID? = nil) async throws -> String {
        do { return try await executeTool(call, userLine: userLine, turn: turn) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try checkTurn(turn)
            let userID = userLine?.id ?? state.chat.last(where: { $0.role == "user" })?.id
            try? commit { $0.recordReceipt(ToolReceipt(id: call.id, tool: call.function.name,
                detail: String(error.localizedDescription.prefix(500)), status: "failed"), userID: userID) }
            throw error
        }
    }

    private func executeTool(_ call: AgentToolCall, userLine: ChatLine?, turn: UUID?) async throws -> String {
        try checkTurn(turn)
        guard let tool = AgentTool(rawValue: call.function.name), availableTools.contains(tool) else {
            throw PuddleError("This connection or tool is unavailable.")
        }
        let parameters = try call.parameters()
        let userID = userLine?.id ?? state.chat.last(where: { $0.role == "user" })?.id
        func receipt(_ detail: String, status: String = "completed", references: [SourceReference] = []) throws {
            try checkTurn(turn)
            try commit { $0.recordReceipt(ToolReceipt(id: call.id, tool: tool.rawValue, detail: detail,
                                                    status: status, references: references), userID: userID) }
        }
        func text(_ key: String, maximum: Int = 4000) throws -> String {
            guard let value = parameters[key] as? String, value.count <= maximum else {
                throw PuddleError("Invalid or oversized \(key) argument.")
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch tool {
        case .learnMemories, .meetingSummary:
            throw PuddleError("Batch memory learning is handled before the conversation response.")
        case .searchMail:
            let query = try text("query", maximum: 500)
            let messages = demo ? Array(state.messages.prefix(10)) : try await GmailClient(session: google, transport: transport).search(query: query)
            try receipt("Read \(messages.count) matching emails", references: messages.map { SourceReference(title: $0.subject, url: $0.sourceURL) })
            record("Assistant searched Gmail.")
            return SplashClient.emailContext(messages)
        case .calendar:
            guard let days = parameters["days"] as? Int, (1...14).contains(days) else {
                throw PuddleError("Calendar days must be between 1 and 14.")
            }
            let page = demo ? CalendarPage(events: state.calendarEvents) : try await GoogleCalendarClient(session: google, transport: transport).upcomingPage(days: days)
            let events = page.events
            try checkTurn(turn)
            try commit { $0.calendarEvents = events; $0.calendarHasMore = page.hasMore }
            try receipt("Read \(events.count) calendar events\(page.hasMore ? "; more events exist" : "")", references: events.compactMap { event in
                event.sourceURL.map { SourceReference(title: event.title, url: $0) }
            })
            record("Assistant read upcoming calendar events.")
            return encoded(page)
        case .memories:
            let query = try text("query", maximum: 500)
            try receipt("Recalled saved memories")
            return encoded(state.memories.filter { query.isEmpty || "\($0.title) \($0.content)".localizedCaseInsensitiveContains(query) })
        case .tasks:
            try receipt("Read local tasks")
            return encoded(state.tasks)
        case .remember:
            let title = try text("title", maximum: 200), content = try text("content")
            let source = try text("source")
            let message = userLine?.content ?? state.chat.last(where: { $0.role == "user" })?.content ?? ""
            let update = try MemoryUpdate.validated(title: title, content: content, source: source, userMessage: message)
            guard MemoryLearning.changed(update, in: state.memories) else {
                try receipt("This fact is already saved in Memory.")
                return "This fact is already saved in Memory."
            }
            try commit {
                $0.remember(title: update.title, content: update.content, source: update.source, sourceMessageID: userID)
                $0.recordReceipt(ToolReceipt(id: call.id, tool: tool.rawValue, detail: "Saved memory: \(title)"), userID: userID)
            }
            record("Learned a personal fact from conversation.")
            return "Memory saved successfully."
        case .remind:
            let title = try text("title", maximum: 300), rawDate = try text("due_at", maximum: 100)
            guard !title.isEmpty else { throw PuddleError("A task needs a title.") }
            let date = rawDate.isEmpty ? nil : AssistantDates.parse(rawDate)
            guard rawDate.isEmpty || (date != nil && date! > Date().addingTimeInterval(-60)) else {
                throw PuddleError("Supply a future ISO 8601 time with timezone, or ask the user to clarify.")
            }
            let detail = title + "\n\n" + (date.map { "Remind at: \($0.formatted(date: .complete, time: .shortened))" } ?? "Add as an undated task.")
            if let previous = state.chat.first(where: { $0.id == userID })?.receipts?.first(where: {
                $0.tool == tool.rawValue && $0.status != "failed" && ($0.id == call.id || $0.detail == detail)
            }) { return "This action was already \(previous.status): \(previous.detail). Do not repeat it." }
            guard await approve(title: "Create this task?", detail: detail) else {
                try receipt(detail, status: "declined")
                return "The user declined this task. Nothing was created."
            }
            try checkTurn(turn)
            let task = AssistantTask(title: title, dueAt: date)
            try commit {
                $0.tasks.append(task)
                $0.recordReceipt(ToolReceipt(id: call.id, tool: tool.rawValue, detail: detail), userID: userID)
            }
            scheduleReminders()
            record("Created an approved local task.")
            return "Task created successfully. With notifications enabled, macOS can deliver it while Puddle is closed. It also appears in chat once due."
        }
    }

    private func approve(title: String, detail: String) async -> Bool {
        await withCheckedContinuation { continuation in
            approvalContinuation = continuation
            pendingApproval = Approval(title: title, detail: detail)
        }
    }

    func resolveApproval(_ allowed: Bool) {
        let continuation = approvalContinuation
        approvalContinuation = nil; pendingApproval = nil
        continuation?.resume(returning: allowed)
    }

    private func addToolActivity(_ text: String) { toolActivities.append(text); record(text) }

    func saveMemory(title: String, content: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !content.isEmpty, title.count <= 200, content.count <= 4000 else { return }
        state.remember(title: title, content: content); persist()
    }
    func removeMemory(_ id: UUID) { stopAI(); state.memories.removeAll { $0.id == id }; persist() }
    func setAutomaticLearning(_ enabled: Bool) {
        stopAI(); state.settings.automaticallyLearn = enabled; persist()
    }
    func setContextTokens(_ tokens: Int) { stopAI(); cancelMeetingSummary(); state.settings.contextTokens = max(4096, min(131072, tokens)); persist() }
    func toggleTask(_ id: UUID) {
        if let index = state.tasks.firstIndex(where: { $0.id == id }) {
            state.tasks[index].completed.toggle()
            if persist() { scheduleReminders() }
        }
    }
    func addTask(title: String, dueAt: Date?) {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        state.tasks.append(AssistantTask(title: String(title.prefix(300)), dueAt: dueAt))
        if persist() { scheduleReminders() }
    }
    func updateTask(_ id: UUID, title: String, dueAt: Date?) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 300, let index = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        if state.tasks[index].dueAt != dueAt { state.tasks[index].notifiedAt = nil }
        state.tasks[index].title = title; state.tasks[index].dueAt = dueAt
        if persist() { scheduleReminders() }
    }
    func deleteTask(_ id: UUID) {
        state.tasks.removeAll { $0.id == id }
        if persist() { scheduleReminders() }
    }
    func snoozeTask(_ id: UUID, minutes: Int = 10) {
        guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[index].completed = false; state.tasks[index].notifiedAt = nil
        state.tasks[index].dueAt = Date().addingTimeInterval(Double(max(1, minutes)) * 60)
        if persist() { scheduleReminders() }
    }
    func scheduleReminders() {
        guard !demo, storageAvailable else { return }
        let tasks = state.tasks, enabled = state.settings.notifications
        Task {
            do { try await reminderScheduler.reconcile(tasks: tasks, enabled: enabled) }
            catch { fail(PuddleError("The task is saved, but macOS could not schedule its notification: \(error.localizedDescription)")) }
        }
    }
    func processReminders() {
        let due = state.dueReminders()
        guard !due.isEmpty else { return }
        for task in due {
            var line = ChatLine(role: "assistant", content: "Reminder: \(task.title)"); line.kind = "reminder"
            state.chat.append(line)
        }
        record("Delivered \(due.count) local reminders."); persist()
    }
    func savePersona(_ text: String) { state.assistantInstructions = String(text.prefix(4000)); persist() }

    func summarize(_ id: String) {
        guard !isThinking, let message = state.messages.first(where: { $0.id == id }) else { return }
        beginAI { [self] in
            let answer = demo ? DemoInbox.summary(for: message) : try await splash().summarize(message)
            try Task.checkCancellation()
            if let index = state.messages.firstIndex(where: { $0.id == id }) {
                state.messages[index].summary = answer; persist()
            }
        }
    }

    private func beginAI(_ operation: @escaping @MainActor () async throws -> Void) {
        stopSpeaking(); voiceInput.cancel()
        isThinking = true; toolActivities = []; streamingReply = ""; turnMetrics = nil
        let expected = UUID(); aiGeneration = expected
        aiTask = Task {
            defer { if aiGeneration == expected { isThinking = false; streamingReply = "" } }
            do { try await operation() }
            catch is CancellationError {}
            catch { if aiGeneration == expected { fail(error) } }
        }
    }
    func stopAI() {
        stopSpeaking(); voiceInput.cancel()
        aiGeneration = UUID(); resolveApproval(false); aiTask?.cancel(); isThinking = false; streamingReply = ""
    }

    func readAloud(_ line: ChatLine) {
        guard line.role == "assistant", !voiceInput.isActive, !meetingCapture.isActive else { return }
        if speakingMessageID == line.id { stopSpeaking(); return }
        stopSpeaking()
        let text = SpeechText.prepare(line.content)
        guard !text.isEmpty else { return }
        let expected = speechGeneration
        speakingMessageID = line.id
        speechPlayer.speak(text, language: state.settings.speechLanguage, speed: state.settings.speechSpeed) { [weak self] in
            guard let self, self.speechGeneration == expected else { return }
            self.speakingMessageID = nil
        }
    }

    func stopSpeaking() { speechGeneration = UUID(); speechPlayer.stop(); speakingMessageID = nil }
    func setReadRepliesAloud(_ enabled: Bool) {
        if !enabled { stopSpeaking() }
        state.settings.readRepliesAloud = enabled; persist()
    }
    func setSpeechLanguage(_ language: String) { stopSpeaking(); voiceInput.cancel(); state.settings.speechLanguage = language; persist() }
    func setSpeechSpeed(_ speed: Double) { stopSpeaking(); state.settings.speechSpeed = max(0.7, min(1.3, speed)); persist() }
    func toggleVoiceInput() {
        guard !demo, storageAvailable, !isThinking, !meetingCapture.isActive else { return }
        stopSpeaking(); voiceInput.toggle(language: state.settings.speechLanguage)
    }

    func testSplash(silent: Bool = false) async {
        guard !isTestingSplash else { return }
        isTestingSplash = true
        let expected = splashRevision
        defer { isTestingSplash = false }
        do {
            let model = try await connection().model(force: true).id
            guard expected == splashRevision else { return }
            splashModel = model; if !silent { errorMessage = nil }
        } catch { if expected == splashRevision { splashModel = nil; if !silent { fail(error) } } }
    }
    private func splash() throws -> SplashClient { try SplashClient(address: state.settings.splashAddress, apiKey: apiKey, transport: transport) }

    func saveSettings(address: String, key: String, interval: Int, automatic: Bool, summarize: Bool, testConnection: Bool = false) async {
        do {
            _ = try SplashClient(address: address, apiKey: key)
            guard demo || storageAvailable else { throw PuddleError("Retry loading saved state before changing connection settings.") }
            let previousKey = demo ? nil : try secrets.read("splash-key")
            if !demo {
                if key.isEmpty { try secrets.delete("splash-key") }
                else { try secrets.write(Data(key.utf8), key: "splash-key") }
            }
            do {
                try commit {
                    $0.settings.splashAddress = address
                    $0.settings.pollSeconds = max(30, min(3600, interval)); $0.settings.automaticallyCheck = automatic
                    $0.settings.automaticallySummarize = summarize
                }
            } catch {
                if !demo {
                    if let previousKey { try secrets.write(previousKey, key: "splash-key") }
                    else { try secrets.delete("splash-key") }
                }
                throw error
            }
            apiKey = key
            stopAI(); cancelMeetingSummary(); splashRevision = UUID(); modelConnection = nil; splashModel = nil; startPolling()
            if testConnection { await testSplash() }
        } catch { fail(error) }
    }

    func enableNotifications(_ enabled: Bool) async {
        if !enabled { state.settings.notifications = false; if persist() { scheduleReminders() }; return }
        do {
            state.settings.notifications = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            if persist() { scheduleReminders() }
        } catch { fail(error) }
    }
    private func notify(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func enterDemo() {
        resetMeetingWorkspace()
        cancelSignIn(); syncTask?.cancel(); pollingTask?.cancel(); stopAI(); generation = UUID()
        isSyncing = false; isRefreshingCalendar = false
        splashRevision = UUID(); modelConnection = nil; splashModel = nil
        demo = true; connected = false; selectedID = nil; errorMessage = nil; section = .chat
        state = AppSnapshot(); state.account = "you@example.test"
        state.merge(DemoInbox.messages)
        state.remember(title: "Response style", content: "I prefer concise explanations with concrete next steps.")
        state.tasks = [AssistantTask(title: "Outline the Puddle MVP")]
        state.calendarEvents = [CalendarEvent(id: "demo-review", title: "Project review", start: Date().addingTimeInterval(86400).ISO8601Format(), location: "Studio",
            meetingLinks: MeetingJoinLink.discover(in: ["https://meet.google.com/abc-defg-hij"]))]
        record("Demo mode: fixture responses and sample connections. No accounts accessed.")
        startPolling()
    }
    func leaveDemo() {
        resetMeetingWorkspace()
        stopAI(); generation = UUID(); demo = false; section = .chat; selectedID = nil; errorMessage = nil
        splashRevision = UUID(); modelConnection = nil; splashModel = nil
        guard loadState() else { return }
        Task {
            do {
                apiKey = try secrets.read("splash-key").map { String(decoding: $0, as: UTF8.self) } ?? ""
                try await prepareGoogleClient()
                connected = try await google.hasCredentials(); grantedScopes = try await google.grantedScopes()
                startPolling(); await testSplash(silent: true)
            } catch { fail(error) }
        }
    }
    private func demoAnswer(_ question: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(300))
        let lower = question.lowercased()
        if lower.contains("remember") {
            addToolActivity("Save a memory · Demo")
            let result = try await execute(AgentToolCall(name: AgentTool.remember.rawValue,
                arguments: encoded(["title": "Personal preference", "content": question, "source": question])))
            return result.hasPrefix("Memory saved") ? "I’ll remember that. You can review or forget it in Memory." : result
        }
        if lower.contains("remind") {
            addToolActivity("Create a reminder · Demo")
            let result = try await execute(AgentToolCall(name: AgentTool.remind.rawValue,
                arguments: encoded(["title": "Take a short break", "due_at": Date().addingTimeInterval(60).ISO8601Format()])))
            return result.hasPrefix("Task created") ? "Your break reminder is saved. It will appear in this conversation when it’s due, and you can find it in Tasks." : "Okay, I haven’t created that reminder."
        }
        if lower.contains("mail") || lower.contains("inbox") {
            addToolActivity("Search Gmail · Demo")
            return "From the sample inbox:\n\n" + state.messages.prefix(3).map { "**\($0.subject)**\n\(DemoInbox.summary(for: $0))" }.joined(separator: "\n\n")
        }
        if lower.contains("calendar") || lower.contains("meeting") {
            addToolActivity("Read calendar · Demo")
            return "Your sample calendar has a project review at the Studio tomorrow. A live conversation would read the connected calendar only when it is relevant."
        }
        return "I’m Puddle, your local personal assistant. We can think through ideas, draft something, make a plan, or keep track of what matters to you.\n\nFor example, we could turn your current project into three next steps, remember how you like to work, or create a reminder. Email and calendar are optional connections I can use when you need them.\n\nThis is a demo response. Connect Splash in Settings for a real conversation with your local model."
    }

    func clearChat() { stopAI(); state.startNewConversation(); toolActivities = []; persist() }
    private func encoded<T: Encodable>(_ value: T) -> String {
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data("[]".utf8), as: UTF8.self)
    }
    @discardableResult private func persist() -> Bool {
        guard !demo else { return true }
        state.activity = Array(state.activity.prefix(100))
        do {
            guard storageAvailable else { throw PuddleError("Saved state is unavailable. Retry loading it in Settings before making changes.") }
            try cache.save(state); lastSavedState = state; return true
        } catch {
            state = lastSavedState
            errorMessage = "Puddle could not save its local state: \(error.localizedDescription)"; return false
        }
    }
    func commit(_ update: (inout AppSnapshot) -> Void) throws {
        var next = state
        update(&next)
        if !demo {
            guard storageAvailable else { throw PuddleError("Saved state is unavailable. Retry loading it in Settings.") }
            try cache.save(next); lastSavedState = next
        }
        state = next
    }
    private func record(_ text: String) {
        state.activity.insert(ActivityEvent(text), at: 0)
        state.activity = Array(state.activity.prefix(100))
    }
    func fail(_ error: Error) { errorMessage = error.localizedDescription }
}
