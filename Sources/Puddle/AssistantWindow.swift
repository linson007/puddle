import SwiftUI
import PuddleCore

enum PuddleStyle {
    static let teal = Color(red: 0.12, green: 0.48, blue: 0.44)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
}

struct PuddleMark: View {
    var size: CGFloat = 48
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
    }
}

/// The conversation is the main experience; connections supply optional tools.
struct AssistantWindow: View {
    @ObservedObject var store: PuddleStore
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    PuddleMark(size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Puddle").font(.system(size: 22, weight: .semibold, design: .rounded))
                        Text("Your personal AI.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 18).padding(.top, 22)
                VStack(spacing: 5) {
                    ForEach(PuddleStore.Section.allCases, id: \.self) { section in
                        Button { store.section = section } label: {
                            HStack(spacing: 10) {
                                Image(systemName: section.icon).frame(width: 18)
                                Text(section.rawValue).font(.system(size: 13, weight: .medium))
                                Spacer()
                                if section == .tasks {
                                    let count = store.state.tasks.filter { !$0.completed }.count
                                    if count > 0 { Text(String(count)).font(.caption).foregroundStyle(.secondary) }
                                }
                            }.padding(11).contentShape(Rectangle())
                                .background(store.section == section ? PuddleStyle.teal.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).foregroundStyle(store.section == section ? PuddleStyle.teal : Color.primary)
                    }
                }.padding(.horizontal, 12)
                Spacer()
                VStack(alignment: .leading, spacing: 11) {
                    Label("Private by default", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Circle().fill(store.splashModel != nil ? PuddleStyle.teal : Color.secondary).frame(width: 6, height: 6)
                        Text(store.demo ? "Demo mode" : store.splashModel != nil ? "Splash connected" : "Connect local Splash")
                            .font(.caption).lineLimit(1)
                        Spacer()
                        SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Puddle settings")
                    }
                    if store.demo { Button("Exit demo") { store.leaveDemo() }.font(.caption).buttonStyle(.link) }
                }.padding(18)
            }.background(PuddleStyle.panel.opacity(0.5))
                .navigationSplitViewColumnWidth(min: 210, ideal: 225, max: 280)
        } detail: {
            VStack(spacing: 0) {
                MeetAttendanceBanner(store: store, attendance: store.meetAttendance)
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
                    case .chat: ConversationView(store: store, voice: store.voiceInput)
                    case .history: ConversationHistoryView(store: store)
                    case .meetings: MeetingsView(store: store, workspace: store.meetingWorkspace)
                    case .tasks: TasksView(store: store)
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
        }.tint(PuddleStyle.teal)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if store.isThinking { Button("Stop") { store.stopAI() } }
                    if store.section == .chat {
                        Button { store.clearChat() } label: { Label("New Conversation", systemImage: "square.and.pencil") }
                            .help("Start a new conversation; keep memory and tasks")
                    }
                    SettingsLink { Label("Settings", systemImage: "gearshape") }
                }
            }
            .sheet(isPresented: $store.showSetup) { GoogleSetupView(store: store) }
    }
}

private struct ConversationView: View {
    @ObservedObject var store: PuddleStore
    @ObservedObject var voice: VoiceInputController
    @Environment(\.openSettings) private var openSettings
    @State private var input = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Puddle").font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("On your Mac").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let model = store.splashModel {
                    Label("Local model", systemImage: "desktopcomputer").font(.caption).foregroundStyle(PuddleStyle.teal).help(model)
                } else if !store.demo {
                    Button { store.settingsTab = "localAI"; openSettings() } label: { Label("Connect Splash", systemImage: "bolt.horizontal") }.font(.caption)
                }
            }.padding(.horizontal, 30).padding(.vertical, 18)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if store.state.chat.isEmpty { welcome }
                        ForEach(store.state.chat) { line in
                            HStack(alignment: .top, spacing: 14) {
                                if line.role == "assistant" { PuddleMark(size: 30) }
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(line.role == "user" ? "YOU" : "PUDDLE")
                                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                    Text(.init(line.content)).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
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
                                    }.font(.caption2).buttonStyle(.link)
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
                                    .background(line.role == "user" ? Color.primary.opacity(0.035) : PuddleStyle.teal.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
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
                    }.frame(maxWidth: 760).padding(30).frame(maxWidth: .infinity)
                }
                .onChange(of: store.state.chat.count) { _, _ in
                    if let id = store.state.chat.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
                .onChange(of: store.streamingReply) { _, _ in proxy.scrollTo("thinking", anchor: .bottom) }
            }
            if !store.toolActivities.isEmpty {
                Text("Tools: " + store.toolActivities.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 32).padding(.bottom, 8)
            }
            if !store.isThinking, store.state.chat.contains(where: { $0.role == "user" }) {
                Button("Retry last message") { store.retryLastQuestion() }.font(.caption).buttonStyle(.link).padding(.bottom, 8)
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
                    Spacer(); Button("Dismiss") { voice.dismissError() }.buttonStyle(.link)
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
                    .buttonStyle(.borderedProminent).disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isThinking || voice.isActive)
                    .accessibilityLabel("Send message")
            }.padding(16).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
                .padding(.horizontal, 30)
            Text("Local conversation · Memory you control · Optional connections")
                .font(.caption2).foregroundStyle(.tertiary).padding(.vertical, 12)
        }.onChange(of: voice.completedTranscript?.id) { _, _ in
            if let draft = voice.completedTranscript { input += (input.isEmpty ? "" : " ") + draft.text }
        }.onDisappear { voice.cancel() }
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 23) {
            PuddleMark(size: 82)
            VStack(alignment: .leading, spacing: 10) {
                Text("A little help,\nwith whatever’s next.")
                    .font(.system(size: 37, weight: .semibold, design: .rounded)).tracking(-0.8)
                Text("Think out loud, make a plan, or hand me a reminder.\nI’m here on your Mac, with memory that stays with you.")
                    .font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(4)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                prompt("Think through an idea", icon: "lightbulb", message: "Help me think through a new project idea. Ask me a few useful questions.")
                prompt("Make a plan", icon: "list.bullet.clipboard", message: "Help me plan my day. Let's start with my priorities.")
                prompt("Remember a preference", icon: "brain", message: "Remember that I prefer short, practical answers.")
                prompt("Set a reminder", icon: "bell", message: "Remind me to take a break in one minute.")
            }
            HStack(spacing: 10) {
                Text("Connect mail and calendar whenever you need them.").font(.caption).foregroundStyle(.secondary)
                Button("Connections") { store.section = .connections }.buttonStyle(.link).font(.caption)
            }
            if !store.demo { Button("Explore the demo") { store.enterDemo() }.buttonStyle(.link).font(.caption) }
        }.padding(.top, 24).padding(.bottom, 20)
    }
    private func prompt(_ title: String, icon: String, message: String) -> some View {
        Button { store.ask(message) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(PuddleStyle.teal)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }.padding(14).frame(maxWidth: .infinity).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain).disabled(store.isThinking)
    }
    private func send() {
        guard !store.isThinking, !voice.isActive, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let question = input; input = ""; store.ask(question)
    }
}

private struct ConversationHistoryView: View {
    @ObservedObject var store: PuddleStore
    @State private var search = ""
    var body: some View {
        let matches = store.state.matchingConversations(search)
        VStack(alignment: .leading, spacing: 20) {
            Text("Conversation history").font(.system(size: 29, weight: .semibold, design: .rounded))
            TextField("Search conversations", text: $search).textFieldStyle(.roundedBorder)
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
                            Button("Delete") { store.deleteConversation(conversation.id) }.buttonStyle(.link)
                        }.padding(16).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }.overlay {
                if matches.isEmpty {
                    Text(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "No conversations yet. Start chatting with Puddle to see them here."
                         : "No conversations match your search.").foregroundStyle(.secondary)
                }
            }
        }.padding(30)
    }
}

private struct TasksView: View {
    @ObservedObject var store: PuddleStore
    @State private var title = ""
    @State private var dated = false
    @State private var due = Date().addingTimeInterval(3600)
    @State private var editing: AssistantTask?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Tasks & reminders").font(.system(size: 29, weight: .semibold, design: .rounded))
                Text("Add a task or ask Puddle. Enable notifications in Settings for macOS reminders while Puddle is closed.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    TextField("What would you like to do?", text: $title).textFieldStyle(.roundedBorder)
                    HStack {
                        Toggle("Remind me", isOn: $dated).toggleStyle(.checkbox)
                        if dated { DatePicker("When", selection: $due, in: Date()...).labelsHidden() }
                        Spacer()
                        Button("Add Task") { store.addTask(title: title, dueAt: dated ? due : nil); title = "" }
                            .buttonStyle(.borderedProminent).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(18).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 12))
                ForEach(store.state.tasks) { task in
                    HStack(alignment: .top, spacing: 12) {
                        Button { store.toggleTask(task.id) } label: {
                            Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                                .font(.title3).foregroundStyle(task.completed ? PuddleStyle.teal : .secondary)
                        }.buttonStyle(.plain).accessibilityLabel(task.completed ? "Mark task incomplete" : "Complete task")
                        VStack(alignment: .leading, spacing: 6) {
                            Text(task.title).strikethrough(task.completed).foregroundStyle(task.completed ? .secondary : .primary)
                            if let due = task.dueAt {
                                Text(due.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            if let source = task.meetingSource {
                                if let note = store.state.meetings.first(where: { $0.id == source.meetingID }) {
                                    Button("From meeting: \(note.title)") { store.meetingWorkspace.selectedID = note.id; store.section = .meetings }.buttonStyle(.link).font(.caption)
                                }
                                DisclosureGroup("Source quote") { Text(source.quote).font(.caption).textSelection(.enabled) }
                            }
                        }
                        Spacer()
                        Button("Edit") { editing = task }.buttonStyle(.link)
                        Menu {
                            Button("Snooze 10 minutes") { store.snoozeTask(task.id) }
                            Button("Delete", role: .destructive) { store.deleteTask(task.id) }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
                    }.padding(16).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 11))
                }
                if store.state.tasks.isEmpty { Label("No tasks yet. Try “Remind me to…” in chat.", systemImage: "checklist").foregroundStyle(.secondary).padding(.top, 20) }
            }.frame(maxWidth: 720, alignment: .leading).padding(36).frame(maxWidth: .infinity)
        }.sheet(item: $editing) { task in TaskEditor(store: store, task: task) }
    }
}

private struct TaskEditor: View {
    @ObservedObject var store: PuddleStore
    let task: AssistantTask
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var dated = false
    @State private var due = Date()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit task").font(.title2)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            Toggle("Remind me", isOn: $dated)
            if dated { DatePicker("When", selection: $due, in: Date()...) }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }
                Button("Save") { store.updateTask(task.id, title: title, dueAt: dated ? due : nil); dismiss() }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 300)
                    .buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 430)
            .onAppear { title = task.title; dated = task.dueAt != nil; due = task.dueAt ?? Date().addingTimeInterval(3600) }
    }
}

private struct MemoryView: View {
    @ObservedObject var store: PuddleStore
    @State private var title = ""
    @State private var content = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
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
                ForEach(store.state.memories) { note in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(note.title).fontWeight(.semibold)
                            Spacer()
                            Button("Forget") { store.removeMemory(note.id) }.buttonStyle(.link).font(.caption)
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
            }.frame(maxWidth: 720, alignment: .leading).padding(36).frame(maxWidth: .infinity)
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
                VStack(alignment: .leading, spacing: 14) {
                    Label("Google", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
                    Text("Optional Gmail search and upcoming Google Calendar events. Puddle reads them when you ask a relevant question.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 18) {
                        Label(store.mailConnected ? "Gmail available" : "Gmail not connected", systemImage: "envelope")
                        Label(store.calendarConnected ? "Calendar available" : "Calendar not connected", systemImage: "calendar")
                    }.font(.caption).foregroundStyle(.secondary)
                    if let account = store.state.account { Text(account).font(.caption).foregroundStyle(.secondary) }
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
                            Button("Disconnect Google") { store.disconnect() }
                        }
                    }
                    if let error = store.errorMessage {
                        Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    Text("Read-only access. Your conversation, memory, and tasks belong to Puddle and stay when a connection is removed.")
                        .font(.caption).foregroundStyle(.secondary)
                }.connectionCard()
                if store.mailConnected {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("Recent mail", systemImage: "envelope").font(.headline)
                            Spacer()
                            Button("Ask about my mail") { store.ask("Check my recent email and tell me what needs my attention.") }.disabled(store.isThinking)
                        }
                        ForEach(store.state.messages.prefix(5)) { message in
                            DisclosureGroup {
                                if let summary = message.summary {
                                    Text(.init(summary)).font(.callout).textSelection(.enabled).padding(.vertical, 8)
                                    Divider()
                                }
                                Button("Summarize") { store.summarize(message.id) }.disabled(store.isThinking)
                                Text(message.body).font(.callout).textSelection(.enabled).padding(.vertical, 8)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(message.subject).font(.callout)
                                    Text(message.sender).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if store.state.messages.isEmpty { Text("Ask Puddle to search mail, or refresh this connection.").font(.caption).foregroundStyle(.secondary) }
                    }.connectionCard()
                }
                if store.calendarConnected {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("Upcoming calendar", systemImage: "calendar").font(.headline)
                            Spacer()
                            Button("Ask about my day") { store.ask("Check my calendar and help me plan the rest of my day.") }.disabled(store.isThinking)
                        }
                        ForEach(store.state.calendarEvents.prefix(8)) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.title).font(.callout)
                                Text(AssistantDates.parse(event.start)?.formatted(date: .abbreviated, time: .shortened) ?? event.start)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if store.state.calendarEvents.isEmpty { Text("Ask Puddle what is on your calendar, or refresh the connection.").font(.caption).foregroundStyle(.secondary) }
                        if store.state.calendarHasMore { Text("More events exist in this window. Ask Puddle for a shorter time range.").font(.caption).foregroundStyle(.orange) }
                    }.connectionCard()
                }
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
