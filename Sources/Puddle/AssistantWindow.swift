import SwiftUI
import PuddleCore

struct PuddleMark: View {
    var size: CGFloat = 48
    var activity: String = "Ready"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28).fill(PuddleStyle.teal.opacity(0.10))
            Image(systemName: "drop.fill").font(.system(size: size * 0.61, weight: .medium))
                .foregroundStyle(PuddleStyle.teal).offset(y: -size * 0.025)
            HStack(spacing: size * 0.085) {
                Circle().fill(.white).frame(width: size * 0.048, height: size * 0.065)
                Circle().fill(.white).frame(width: size * 0.048, height: size * 0.065)
            }.offset(y: size * 0.065)
            Ellipse().stroke(PuddleStyle.teal.opacity(0.3), lineWidth: 1.3)
                .frame(width: size * 0.48, height: size * 0.1).offset(y: size * 0.35)
        }.frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if activity != "Ready" {
                    Image(systemName: activity == "Listening" ? "mic.fill" : activity == "Speaking" ? "speaker.wave.2.fill" : activity == "Review needed" ? "hand.raised.fill" : "ellipsis")
                        .font(.system(size: max(10, size * 0.22), weight: .bold)).padding(4)
                        .background(.background, in: Circle()).foregroundStyle(PuddleStyle.teal)
                        .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion && activity == "Thinking")
                }
            }
            .accessibilityElement(children: .ignore).accessibilityLabel("Puddle: \(activity)")
    }
}

/// Daily work and conversation share the same saved local context.
struct AssistantWindow: View {
    @ObservedObject var store: PuddleStore
    var body: some View {
        Group { if store.isLocked { PrivacyLockView(store: store) } else { workspace } }
    }
    private var workspace: some View {
        NavigationSplitView {
            PuddleSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 210, ideal: 225, max: 250)
        } detail: {
            VStack(spacing: 0) {
                #if DEBUG
                if UITestWorkspace.enabled {
                    Label("UI test workspace · Synthetic providers, real local Splash · No personal credentials", systemImage: "testtube.2")
                        .font(.caption).padding(10).frame(maxWidth: .infinity).background(.orange.opacity(0.15))
                }
                #endif
                if store.privateSession {
                    HStack { Label("Private session · Changes stay in memory", systemImage: "eye.slash"); Spacer(); Button("End Session") { store.endPrivateSession() } }
                        .font(.caption).padding(12).background(.orange.opacity(0.12))
                }
                MeetAttendanceBanner(store: store, attendance: store.meetAttendance)
                BrowserControlBanner(store: store, workspace: store.browserWorkspace)
                if store.demo {
                    HStack {
                        Label("Demo", systemImage: "flask").fontWeight(.semibold)
                        Text("Sample connections and fixture responses").foregroundStyle(.secondary)
                        Spacer()
                        Button("Use my local model") { store.leaveDemo() }
                    }.font(.caption).padding(.horizontal, 24).padding(.vertical, 10).background(.orange.opacity(0.08))
                }
                if let error = store.errorMessage {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(error).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { store.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                            .accessibilityLabel("Dismiss error")
                    }.padding(16).background(.orange.opacity(0.07))
                }
                Group {
                    switch store.section {
                    case .today: TodayView(store: store)
                    case .chat: ConversationView(store: store, voice: store.voiceInput)
                    case .developer: DeveloperView(store: store, workspace: store.developerWorkspace)
                    case .browser: BrowserView(store: store, workspace: store.browserWorkspace)
                    case .history: ConversationHistoryView(store: store)
                    case .meetings: MeetingsView(store: store, workspace: store.meetingWorkspace)
                    case .tasks: TasksView(store: store)
                    case .calendar: CalendarView(store: store)
                    case .mail: MailView(store: store)
                    case .actions: ActionsView(store: store)
                    case .routines: RoutinesView(store: store)
                    case .knowledge: KnowledgeView(store: store)
                    case .portfolio: WorkHubView(store: store)
                    case .memory: MemoryView(store: store)
                    case .connections: ConnectionsView(store: store)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let approval = store.pendingApproval {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(approval.title, systemImage: "hand.raised").fontWeight(.semibold)
                        Text(approval.detail).font(.callout).textSelection(.enabled)
                        HStack {
                            Text("Puddle is waiting for your decision.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Decline") { store.resolveApproval(false) }
                            Button("Allow") { store.resolveApproval(true) }.buttonStyle(.borderedProminent)
                        }
                    }.padding(20).background(PuddleStyle.teal.opacity(0.07))
                        .overlay(alignment: .top) { Divider() }
                }
            }.background(PuddleStyle.background)
                .navigationTitle(store.section == .chat ? "Puddle" : store.section.rawValue)
        }.tint(PuddleStyle.teal)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if store.isThinking { Button("Stop") { store.stopAI() } }
                    if store.section == .chat {
                        Button { store.clearChat() } label: { Label("New Conversation", systemImage: "square.and.pencil") }
                            .help("Start a new conversation; keep memory and tasks")
                    }
                    Button { store.showCommands = true } label: { Label("Search & Commands", systemImage: "magnifyingglass") }
                        .help("Search your workspace and commands · ⌘K")
                    Button { store.showAssistantPanel.toggle() } label: { Label("Assistant Panel", systemImage: "sidebar.right") }
                        .disabled(store.section == .chat)
                        .help("Show the assistant beside your current workspace")
                }
            }
            .sheet(isPresented: $store.showSetup) { GoogleSetupView(store: store) }
            .sheet(isPresented: $store.showLocalSetup) { SplashSetupView(store: store, setup: store.splashSetup) }
            .sheet(item: $store.editingAction) { ActionEditorView(store: store, initial: $0) }
            .sheet(isPresented: $store.showCommands) { CommandPaletteView(store: store) }
            .sheet(isPresented: $store.showQuickCapture) { CommitmentEditor(store: store) }
            .sheet(item: $store.editingCommitment) { CommitmentEditor(store: store, task: $0) }
            .sheet(item: $store.editingWorkProject) { WorkProjectEditor(store: store, project: $0) }
            .sheet(item: $store.editingPerson) { PersonContextEditor(store: store, person: $0) }
            .sheet(item: $store.editingDecision) { WorkDecisionEditor(store: store, decision: $0) }
            .inspector(isPresented: Binding(get: { store.showAssistantPanel && store.section != .chat }, set: { store.showAssistantPanel = $0 })) {
                ConversationView(store: store, voice: store.voiceInput, compact: true).inspectorColumnWidth(min: 340, ideal: 410, max: 600)
            }
    }
}

private struct ConversationView: View {
    @ObservedObject var store: PuddleStore
    @ObservedObject var voice: VoiceInputController
    @Environment(\.openSettings) private var openSettings
    @State private var input = ""
    @State private var visibleMessageLimit = 200
    var compact = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Puddle").font(.system(size: 17, weight: .semibold, design: .rounded))
                Label(store.state.profileLibrary.active.title, systemImage: store.state.profileLibrary.active.kind.icon).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let model = store.splashModel {
                    Label("Local model", systemImage: "desktopcomputer").font(.caption).foregroundStyle(PuddleStyle.teal).help(model)
                } else if !store.demo {
                    Button { store.showLocalSetup = true } label: { Label("Set up local AI", systemImage: "bolt.horizontal") }.font(.caption)
                }
            }.padding(.horizontal, compact ? 18 : 30).padding(.vertical, 16)
                .background(PuddleStyle.panel.opacity(0.6))
                .overlay(alignment: .bottom) { Rectangle().fill(PuddleStyle.line).frame(height: 1) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if store.state.chat.isEmpty {
                            if compact { Text("Ask about your work, draft a reply, or prepare an event.").foregroundStyle(.secondary) }
                            else { welcome }
                        }
                        if store.state.chat.count > visibleMessageLimit {
                            HStack {
                                Text("Showing the latest \(visibleMessageLimit) of \(store.state.chat.count) messages").font(.caption).foregroundStyle(.secondary)
                                Button("Load earlier messages") { visibleMessageLimit += 200 }
                            }
                        }
                        ForEach(store.state.chat.suffix(visibleMessageLimit)) { line in
                            HStack(alignment: .top, spacing: 14) {
                                if line.role == "user" { Spacer(minLength: compact ? 18 : 60) }
                                if line.role == "assistant" { PuddleMark(size: 30) }
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(line.role == "user" ? "YOU" : line.profileName.map { "PUDDLE · \($0)" } ?? "PUDDLE")
                                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                    Group {
                                        if line.role == "user" { Text(verbatim: line.content) }
                                        else { Text(.init(line.content)) }
                                    }.font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack {
                                        Button("Copy") {
                                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(line.content, forType: .string)
                                        }
                                        if line.role == "user" { Button("Use as draft") { input = line.content } }
                                        if line.role == "assistant" {
                                            Button(store.speakingMessageID == line.id ? "Stop reading" : "Read aloud") { store.readAloud(line) }
                                                .disabled(voice.isActive)
                                                .help("Read up to 8,000 characters using an installed system voice; code blocks are omitted.")
                                        }
                                        if let metrics = line.metrics {
                                            Text("\(metrics.totalSeconds, specifier: "%.1f")s total · \(metrics.firstTokenSeconds ?? 0, specifier: "%.1f")s first token · \(metrics.extractionSeconds, specifier: "%.1f")s learning")
                                                .foregroundStyle(.secondary)
                                        }
                                    }.font(.caption2).buttonStyle(PuddleTextButtonStyle())
                                    ForEach(line.receipts ?? []) { receipt in
                                        DisclosureGroup("\(AgentTool(rawValue: receipt.tool)?.label ?? receipt.tool) · \(receipt.status)") {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(receipt.detail).textSelection(.enabled)
                                                ForEach(Array(receipt.references.enumerated()), id: \.offset) { _, reference in
                                                    Link(reference.title, destination: reference.url)
                                                }
                                            }
                                        }.font(.caption)
                                    }
                                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(line.role == "user" ? PuddleStyle.inset : PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 14))
                                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PuddleStyle.line.opacity(0.7)))
                            }.id(line.id)
                        }
                        if store.isThinking {
                            if !store.streamingReply.isEmpty {
                                Text(.init(store.streamingReply)).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(PuddleStyle.teal.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                            }
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text(store.pendingApproval != nil ? "Waiting for your approval…" : store.toolActivities.last ?? "Puddle is thinking…")
                                    .font(.callout).foregroundStyle(.secondary)
                            }.id("thinking")
                        }
                    }.frame(maxWidth: 760).padding(compact ? 18 : 30).frame(maxWidth: .infinity)
                }
                .onChange(of: store.state.chat.count) { _, _ in
                    if let id = store.state.chat.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
                .onChange(of: store.streamingReply) { _, _ in proxy.scrollTo("thinking", anchor: .bottom) }
                .task(id: store.state.currentConversationID) {
                    visibleMessageLimit = 200
                    await Task.yield()
                    if !Task.isCancelled, let id = store.state.chat.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            if !store.toolActivities.isEmpty {
                Text("Tools: " + store.toolActivities.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 32).padding(.bottom, 8)
            }
            if !store.isThinking, store.state.chat.contains(where: { $0.role == "user" }) {
                Button("Retry last message") { store.retryLastQuestion() }.font(.caption).buttonStyle(PuddleTextButtonStyle()).padding(.bottom, 8)
            }
            if voice.isActive {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "mic.fill").foregroundStyle(.red)
                        Text(voice.status == .requestingPermission ? "Waiting for microphone permission…" : voice.status == .finishing ? "Finishing speech…" : "Listening on this Mac…")
                        Spacer()
                        if voice.status == .listening { Button("Done") { voice.finish() } }
                        Button("Cancel") { voice.cancel() }
                    }
                    if !voice.transcript.isEmpty { Text(voice.transcript).lineLimit(4).textSelection(.enabled) }
                    Text("Up to 50 seconds. Review the transcript in your draft before sending.").font(.caption).foregroundStyle(.secondary)
                }.font(.callout).padding(16).background(.red.opacity(0.04), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 30).padding(.bottom, 10)
            }
            if let error = voice.errorMessage {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Spacer(); Button("Dismiss") { voice.dismissError() }.buttonStyle(PuddleTextButtonStyle())
                }.padding(.horizontal, 30).padding(.bottom, 8)
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Message Puddle…", text: $input, axis: .vertical).lineLimit(1...6).textFieldStyle(.plain)
                    .font(.system(size: 14)).onSubmit(send).accessibilityLabel("Message Puddle")
                Button { store.toggleVoiceInput() } label: {
                    Image(systemName: voice.isActive ? "stop.circle.fill" : "mic.fill").font(.system(size: 16))
                }.buttonStyle(.borderless).disabled(store.isThinking || store.demo)
                    .accessibilityLabel(voice.isActive ? "Stop voice input" : "Start voice input")
                    .help(store.demo ? "Voice input requires the live app." : "Dictate on this Mac, then review and send. Command-Shift-M.")
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button(action: send) { Image(systemName: "arrow.up").fontWeight(.semibold).frame(width: 21, height: 21) }
                    .buttonStyle(PuddlePrimaryButtonStyle()).disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isThinking || voice.isActive)
                    .accessibilityLabel("Send message")
            }.padding(16).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(PuddleStyle.line))
                .frame(maxWidth: 820).padding(.horizontal, compact ? 18 : 30)
            Text("Local conversation · Memory you control · Optional connections")
                .font(.caption2).foregroundStyle(PuddleStyle.muted).padding(.vertical, 12)
        }.background(PuddleStyle.background).onChange(of: voice.completedTranscript?.id) { _, _ in
            if let draft = voice.completedTranscript { input += (input.isEmpty ? "" : " ") + draft.text }
        }.onDisappear { voice.cancel() }
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 23) {
            PuddleMark(size: 64)
            VStack(alignment: .leading, spacing: 10) {
                Text("A little help,\nwith whatever’s next.")
                    .font(.system(size: 34, weight: .semibold, design: .rounded)).tracking(-0.8).foregroundStyle(PuddleStyle.ink)
                Text(store.state.profileLibrary.active.kind.summary + "\nI’m here on your Mac, with memory that stays with you.")
                    .font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(4)
            }
            if !store.demo && store.splashModel == nil {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A little setup, then we're ready.").font(.callout.weight(.medium))
                        Text("Connect Splash to start a local conversation.").font(.caption).foregroundStyle(PuddleStyle.muted)
                    }
                    Spacer(minLength: 0)
                    Button("Set up local AI") { store.showLocalSetup = true }.buttonStyle(PuddlePrimaryButtonStyle())
                }.puddleCard(padding: 16)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200))], spacing: 12) {
                ForEach(store.state.profileLibrary.active.kind.starters) { starter in
                    prompt(starter.title, icon: starter.icon, message: starter.question)
                }
                prompt("Remember a preference", icon: "brain", message: "Remember that I prefer short, practical answers.")
                prompt("Set a reminder", icon: "bell", message: "Remind me to take a break in one minute.")
            }
            HStack(spacing: 10) {
                Text("Connect mail and calendar whenever you need them.").font(.caption).foregroundStyle(.secondary)
                Button("Connections") { store.section = .connections }.buttonStyle(PuddleTextButtonStyle()).font(.caption)
            }
            if !store.demo { Button("Explore the demo") { store.enterDemo() }.buttonStyle(PuddleTextButtonStyle()).font(.caption) }
        }.padding(.top, 16).padding(.bottom, 20)
    }
    private func prompt(_ title: String, icon: String, message: String) -> some View {
        Button { store.ask(message) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(PuddleStyle.teal)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(PuddleStyle.ink)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(PuddleStyle.muted)
            }.padding(14).frame(maxWidth: .infinity).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(PuddleStyle.line))
        }.buttonStyle(.plain).disabled(store.isThinking || (!store.demo && store.splashModel == nil))
    }
    private func send() {
        guard !store.isThinking, !voice.isActive, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let question = input; input = ""; store.ask(question)
    }
}

private struct ConversationHistoryView: View {
    @ObservedObject var store: PuddleStore
    @State private var search = ""
    @State private var matches: [Conversation] = []
    @State private var searching = true
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Conversation history").font(.system(size: 29, weight: .semibold, design: .rounded))
            TextField("Search conversations", text: $search).textFieldStyle(.roundedBorder)
            if searching { ProgressView("Searching conversations…").controlSize(.small) }
            else { Text("\(matches.count) conversations").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(matches) { conversation in
                        HStack {
                            Button { store.openConversation(conversation.id) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(conversation.title).lineLimit(2)
                                    if conversation.id == store.state.currentConversationID {
                                        Text("Current · \(conversation.lines.count) messages").font(.caption).foregroundStyle(PuddleStyle.teal)
                                    } else {
                                        Text("\(conversation.lines.count) messages · \(conversation.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).accessibilityLabel("Open conversation: \(conversation.title)")
                            Button("Delete") { store.deleteConversation(conversation.id) }.buttonStyle(PuddleTextButtonStyle())
                        }.padding(16).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }.overlay {
                if matches.isEmpty, !searching {
                    Text(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "No conversations yet. Start chatting with Puddle to see them here."
                         : "No conversations match your search.").foregroundStyle(.secondary)
                }
            }
        }.padding(30).task(id: "\(store.workspaceRevision):\(search)") {
            searching = true
            if !search.isEmpty { do { try await Task.sleep(for: .milliseconds(150)) } catch { return } }
            let snapshot = store.state, query = search
            let work = Task.detached(priority: .userInitiated) { snapshot.matchingConversations(query) }
            let found = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            matches = found; searching = false
        }
    }
}

private struct MemoryView: View {
    @ObservedObject var store: PuddleStore
    @State private var title = ""
    @State private var content = ""
    @State private var search = ""
    @State private var matches: [MemoryNote] = []
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text("What Puddle remembers").font(.system(size: 29, weight: .semibold, design: .rounded))
                Text(store.state.settings.automaticallyLearn
                     ? "Puddle learns useful facts and preferences from your conversations automatically. Review or forget them here."
                     : "Automatic learning is off. Review existing memories, forget them, or add a memory manually.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Title, e.g. How I like to work", text: $title).textFieldStyle(.roundedBorder)
                    TextField("What should Puddle remember?", text: $content, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder)
                    HStack {
                        Text("Saved locally and available across conversations.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Save Memory") { store.saveMemory(title: title, content: content); title = ""; content = "" }
                            .buttonStyle(.borderedProminent)
                            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 200 || content.count > 4000)
                    }
                }.padding(18).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 12))
                TextField("Search memories", text: $search).textFieldStyle(.roundedBorder).accessibilityLabel("Search saved memories")
                Text("\(matches.count) of \(store.state.memories.count) memories").font(.caption).foregroundStyle(.secondary)
                ForEach(matches) { note in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(note.title).fontWeight(.semibold)
                            Spacer()
                            Button("Forget") { store.removeMemory(note.id) }.buttonStyle(PuddleTextButtonStyle()).font(.caption)
                        }
                        Text(note.content).textSelection(.enabled)
                        if let source = note.source {
                            Text("From you: “\(source)”").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.tertiary)
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(PuddleStyle.teal.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                }
                if store.state.memories.isEmpty { Label("Your memories will appear here.", systemImage: "brain").foregroundStyle(.secondary) }
                else if matches.isEmpty, !search.isEmpty { Text("No matching memories.").foregroundStyle(.secondary) }
            }.frame(maxWidth: 720, alignment: .leading).padding(36).frame(maxWidth: .infinity)
        }.task(id: "\(store.workspaceRevision):\(search)") {
            if !search.isEmpty { do { try await Task.sleep(for: .milliseconds(150)) } catch { return } }
            let snapshot = store.state, query = search
            let work = Task.detached(priority: .userInitiated) { snapshot.matchingMemories(query) }
            let found = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            if !Task.isCancelled { matches = found }
        }
    }
}

private struct ConnectionsView: View {
    @ObservedObject var store: PuddleStore
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Connections").font(.system(size: 29, weight: .semibold, design: .rounded))
                Text("Give Puddle context when it helps. You can chat, save memories, and set local reminders without connecting an account.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 14) {
                    Label("Local intelligence", systemImage: "desktopcomputer").font(.headline)
                    Text(store.splashModel ?? "Connect a running Splash server to start chatting with your local model.")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button("Configure Splash…") { store.settingsTab = "localAI"; openSettings() }
                        Button("Test Connection") { Task { await store.testSplash() } }.disabled(store.isTestingSplash)
                        if store.isTestingSplash { ProgressView().controlSize(.small) }
                    }
                }.connectionCard()
                WorkConnectionsView(store: store)
                OutlookConnectionsView(store: store)
                WorkSourcesView(store: store, workspace: store.workSources)
                VStack(alignment: .leading, spacing: 14) {
                    Label("Google", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
                    Text("Optional Gmail search and upcoming Google Calendar events. Puddle reads them when you ask a relevant question.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 18) {
                        Label(store.googleMailConnected ? "Gmail available" : "Gmail not connected", systemImage: "envelope")
                        Label(store.calendarConnected ? "Calendar available" : "Calendar not connected", systemImage: "calendar")
                    }.font(.caption).foregroundStyle(.secondary)
                    if let account = store.state.account { Text(account).font(.caption).foregroundStyle(.secondary) }
                    GoogleAccountsView(store: store)
                    HStack {
                        Button(store.isSigningIn ? "Connecting Google…" : store.connected ? "Manage Google Permissions…" : "Connect Google") { store.requestGoogleConnection() }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.isSigningIn)
                        if store.isSigningIn {
                            ProgressView().controlSize(.small)
                            Text(store.googleSignInStatus).font(.caption).foregroundStyle(.secondary)
                            Button("Cancel") { store.cancelSignIn() }
                        }
                        if store.connected {
                            Button("Refresh") { store.refresh() }.disabled(store.isSyncing)
                            Button("Disconnect This Google Account") { store.disconnect() }
                        }
                    }
                    if let error = store.errorMessage {
                        Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    Text("Read access is the default. Optional action permissions require separate consent and exact-content review. Your saved work stays when a connection is removed.")
                        .font(.caption).foregroundStyle(.secondary)
                }.connectionCard()
            }.frame(maxWidth: 760, alignment: .leading).padding(36).frame(maxWidth: .infinity)
        }
    }
}

private extension View {
    func connectionCard() -> some View {
        padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
}
