import SwiftUI

struct PuddleSidebar: View {
    @ObservedObject var store: PuddleStore
    @State private var hoveredSection: PuddleStore.Section?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SidebarActivity(store: store, voice: store.voiceInput)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Puddle").font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(PuddleStyle.ink)
                    Text("Your personal AI.").font(.caption).foregroundStyle(PuddleStyle.muted)
                }
            }.padding(.horizontal, 18).padding(.top, 18)
            ProfileSwitcher(store: store).padding(.horizontal, 14)
            Button { store.showCommands = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text("Search anything").font(.system(size: 12))
                    Spacer(minLength: 0)
                    Text("⌘K").font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(PuddleStyle.inset, in: RoundedRectangle(cornerRadius: 4))
                }.foregroundStyle(PuddleStyle.muted).padding(9)
                    .background(PuddleStyle.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PuddleStyle.line))
            }.buttonStyle(.plain).padding(.horizontal, 14).accessibilityLabel("Search workspace and commands")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(PuddleStore.SidebarGroup.allCases, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.rawValue.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(PuddleStyle.muted)
                                .padding(.horizontal, 11).padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.sections(for: store.state.profileLibrary.active.kind), id: \.self) { navigationRow($0) }
                        }
                    }
                }.padding(.horizontal, 12).padding(.vertical, 4)
            }
            VStack(alignment: .leading, spacing: 3) {
                Divider().padding(.bottom, 8)
                navigationRow(.connections)
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 7) {
                    Label("Private by default", systemImage: "lock.shield")
                    HStack(spacing: 6) {
                        Circle().fill(store.splashModel != nil ? PuddleStyle.teal : Color.secondary).frame(width: 6, height: 6)
                        Text(store.demo ? "Demo mode" : store.splashModel != nil ? "Splash connected" : "Connect local Splash")
                            .lineLimit(1)
                    }
                    if store.demo { Button("Exit demo") { store.leaveDemo() }.buttonStyle(PuddleTextButtonStyle()) }
                }.font(.system(size: 10)).foregroundStyle(PuddleStyle.muted).padding(.horizontal, 10).padding(.top, 8)
            }.padding(.horizontal, 12).padding(.bottom, 18)
        }.background(PuddleStyle.sidebar)
    }

    private func navigationRow(_ section: PuddleStore.Section) -> some View {
        Button { store.section = section } label: {
            HStack(spacing: 10) {
                Image(systemName: section.icon).font(.system(size: 14)).frame(width: 18)
                Text(section.rawValue).font(.system(size: 13, weight: .medium))
                Spacer()
                if section == .tasks {
                    let count = store.state.tasks.filter { !$0.completed }.count
                    if count > 0 {
                        Text(String(count)).font(.system(size: 10, weight: .medium)).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(PuddleStyle.inset, in: Capsule())
                    }
                }
            }.padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
                .background(store.section == section ? PuddleStyle.inset : hoveredSection == section ? PuddleStyle.inset.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).foregroundStyle(store.section == section ? PuddleStyle.teal : PuddleStyle.ink)
            .onHover { hoveredSection = $0 ? section : nil }
            .accessibilityAddTraits(store.section == section ? .isSelected : [])
    }
}

private struct SidebarActivity: View {
    @ObservedObject var store: PuddleStore
    @ObservedObject var voice: VoiceInputController
    private var activity: String {
        if store.pendingApproval != nil || store.editingAction != nil { return "Review needed" }
        if voice.isActive { return "Listening" }
        if store.speakingMessageID != nil { return "Speaking" }
        return store.isThinking ? "Thinking" : "Ready"
    }
    var body: some View { PuddleMark(size: 38, activity: activity).help(activity) }
}
