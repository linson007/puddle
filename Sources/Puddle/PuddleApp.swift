import AppKit
import SwiftUI

@main
struct PuddleApp: App {
    @NSApplicationDelegateAdaptor(PuddleLifecycle.self) private var lifecycle
    @StateObject private var store = Self.makeStore()
    @MainActor private static func makeStore() -> PuddleStore {
        #if DEBUG
        if UITestWorkspace.enabled { return UITestWorkspace.makeStore() }
        #else
        if ProcessInfo.processInfo.arguments.contains("--ui-test-workspace") || Bundle.main.object(forInfoDictionaryKey: "PuddleUITestWorkspace") != nil {
            FileHandle.standardError.write(Data("UI fixture mode requires a debug build. Refusing to open a personal workspace.\n".utf8)); exit(64)
        }
        #endif
        return PuddleStore()
    }
    var body: some Scene {
        WindowGroup("Puddle", id: "main") {
            AssistantWindow(store: store)
                .frame(minWidth: 960, minHeight: 640)
                .task { lifecycle.attendance = store.meetAttendance; lifecycle.splashSetup = store.splashSetup; lifecycle.systemDictation = store.systemDictation; await store.start() }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    store.refresh()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    if store.state.settings.lockOnBackground { store.lockWorkspace() }
                }
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") { store.clearChat(); store.section = .chat }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(store.isLocked)
            }
            CommandMenu("Puddle") {
                Button("Search & Commands") { store.showCommands = true }.keyboardShortcut("k", modifiers: .command)
                Button("Capture a Commitment") { store.showQuickCapture = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Assistant Panel") { store.showAssistantPanel.toggle() }.keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(store.section == .chat || store.isLocked)
                Button("Guided Local AI Setup") { store.showLocalSetup = true }
                Button("Review Actions") { store.section = .actions }.keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Lock Puddle") { store.lockWorkspace() }
                Button(store.privateSession ? "End Private Session" : "Start Private Session") {
                    if store.privateSession { store.endPrivateSession() } else { store.beginPrivateSession() }
                }.disabled(store.isLocked || store.meetingCapture.isActive || !store.executingActions.isEmpty)
            }
        }
        Settings { PuddleSettingsView(store: store) }
        Window("Meeting Companion", id: "meeting-companion") {
            MeetingCompanionView(store: store, capture: store.meetingCapture, workspace: store.meetingWorkspace)
        }.defaultSize(width: 410, height: 580)
        MenuBarExtra {
            PuddleMenu(store: store)
        } label: { Image(systemName: store.isThinking ? "drop.circle.fill" : "drop") }
    }
}

private struct PuddleMenu: View {
    @ObservedObject var store: PuddleStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Group {
            if store.isLocked {
                Text("Puddle is locked")
                Button("Open Puddle to Unlock") { openWindow(id: "main"); NSApplication.shared.activate(ignoringOtherApps: true) }
            } else { unlockedMenu }
        }
    }
    @ViewBuilder private var unlockedMenu: some View {
        Text(store.demo ? "Puddle · Demo" : "Puddle · Your personal AI")
        Text("\(store.state.tasks.filter { !$0.completed }.count) open tasks · \(store.state.memories.count) memories")
        Menu("Profile: \(store.state.profileLibrary.active.title)") {
            ForEach(store.state.profileLibrary.profiles) { profile in
                Button { store.switchAssistantProfile(profile.id) } label: {
                    Label(profile.title, systemImage: profile.id == store.state.profileLibrary.activeID ? "checkmark" : profile.kind.icon)
                }
            }
        }
        Divider()
        Button("Today") { show(.today) }
        Button("Talk to Puddle") { show(.chat) }
        Button("Browser") { show(.browser) }
        if store.state.profileLibrary.active.kind == .developer {
            Button("Developer Workspace") { show(.developer) }
        }
        Button("Tasks & Reminders") { show(.tasks) }
        Button("Calendar") { show(.calendar) }
        Button("Mail") { show(.mail) }
        Button("Review Actions") { show(.actions) }
        Button("Meetings") { show(.meetings) }
        Button("Connections") { show(.connections) }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Puddle") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
    private func show(_ section: PuddleStore.Section) {
        store.section = section; openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
