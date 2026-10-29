import AppKit
import SwiftUI

@main
struct PuddleApp: App {
    @NSApplicationDelegateAdaptor(PuddleLifecycle.self) private var lifecycle
    @StateObject private var store = PuddleStore()
    var body: some Scene {
        WindowGroup("Puddle", id: "main") {
            AssistantWindow(store: store)
                .frame(minWidth: 960, minHeight: 640)
                .task { lifecycle.attendance = store.meetAttendance; await store.start() }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    store.refresh()
                }
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") { store.clearChat(); store.section = .chat }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        Settings { PuddleSettingsView(store: store) }
        MenuBarExtra {
            PuddleMenu(store: store)
        } label: { Image(systemName: store.isThinking ? "drop.circle.fill" : "drop") }
    }
}

private struct PuddleMenu: View {
    @ObservedObject var store: PuddleStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(store.demo ? "Puddle · Demo" : "Puddle · Your personal AI")
        Text("\(store.state.tasks.filter { !$0.completed }.count) open tasks · \(store.state.memories.count) memories")
        Divider()
        Button("Talk to Puddle") { show(.chat) }
        Button("Tasks & Reminders") { show(.tasks) }
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
