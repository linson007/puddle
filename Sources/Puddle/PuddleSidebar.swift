import PuddleCore
import SwiftUI

struct PuddleSidebar: View {
    @ObservedObject var store: PuddleStore
    @AppStorage("pinnedSidebarSections") private var pinnedSectionNames = ""
    @State private var hoveredSection: PuddleStore.Section?
    @State private var showingMore = false

    private var actionsNeedingReview: Int {
        store.state.actionProposals.filter { $0.status == .draft || $0.status == .uncertain }.count
    }

    private var pinnedSections: Set<PuddleStore.Section> {
        Set(pinnedSectionNames.split(separator: "|").compactMap { PuddleStore.Section(rawValue: String($0)) })
    }

    private var pinnableSections: [PuddleStore.Section] {
        [PuddleStore.SidebarGroup.work, .workspace].flatMap {
            $0.sections(for: store.state.profileLibrary.active.kind)
        }
    }

    private var mainSections: [PuddleStore.Section] {
        PuddleStore.SidebarGroup.main.sections(for: store.state.profileLibrary.active.kind)
            + pinnableSections.filter { pinnedSections.contains($0) }
    }

    private func additionalSections(in group: PuddleStore.SidebarGroup) -> [PuddleStore.Section] {
        group.sections(for: store.state.profileLibrary.active.kind).filter { !pinnedSections.contains($0) }
    }

    private func isAdditionalSection(_ section: PuddleStore.Section) -> Bool {
        pinnableSections.contains(section) && !pinnedSections.contains(section)
    }

    private func togglePin(_ section: PuddleStore.Section) {
        var sections = pinnedSections
        if sections.contains(section) { sections.remove(section) }
        else { sections.insert(section) }
        pinnedSectionNames = PuddleStore.Section.allCases.filter { sections.contains($0) }.map(\.rawValue).joined(separator: "|")
    }

    private func pinLabel(for section: PuddleStore.Section) -> String {
        pinnedSections.contains(section) ? "Unpin \(section.rawValue) from sidebar" : "Pin \(section.rawValue) to sidebar"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SidebarActivity(store: store, voice: store.voiceInput)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Puddle")).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(PuddleStyle.ink)
                    Text("Your personal AI.").font(.caption).foregroundStyle(PuddleStyle.muted)
                }
            }.padding(.horizontal, 18).padding(.top, 18)
            ProfileSwitcher(store: store).padding(.horizontal, 14)
            Button { store.showCommands = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text(L10n.text("Search anything")).font(.system(size: 12))
                    Spacer(minLength: 0)
                    Text("⌘K").font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(PuddleStyle.inset, in: RoundedRectangle(cornerRadius: 4))
                }.foregroundStyle(PuddleStyle.muted).padding(9)
                    .background(PuddleStyle.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PuddleStyle.line))
            }.buttonStyle(.plain).padding(.horizontal, 14).accessibilityLabel(L10n.text("Search workspace and commands"))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(mainSections, id: \.self) { navigationRow($0) }
                        if !showingMore && actionsNeedingReview > 0 && !pinnedSections.contains(.actions) { navigationRow(.actions) }
                    }
                    if pinnableSections.contains(where: { !pinnedSections.contains($0) }) {
                        DisclosureGroup(isExpanded: $showingMore) {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach([PuddleStore.SidebarGroup.work, .workspace], id: \.self) { group in
                                    let sections = additionalSections(in: group)
                                    if !sections.isEmpty {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(L10n.text(group.rawValue).uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(PuddleStyle.muted)
                                                .padding(.horizontal, 11).padding(.bottom, 4)
                                                .accessibilityAddTraits(.isHeader)
                                            ForEach(sections, id: \.self) { navigationRow($0) }
                                        }
                                    }
                                }
                            }.padding(.top, 10)
                        } label: {
                            Label(L10n.text("More"), systemImage: "ellipsis.circle")
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(PuddleStyle.muted)
                                .padding(.vertical, 8)
                                .help("Optional workspaces. Use the pin buttons to keep favorites in the main sidebar.")
                        }.padding(.horizontal, 10)
                    }
                }.padding(.horizontal, 12).padding(.vertical, 4)
            }
            VStack(alignment: .leading, spacing: 3) {
                Divider().padding(.bottom, 8)
                navigationRow(.connections)
                SettingsLink {
                    Label(L10n.text("Settings"), systemImage: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 7) {
                    Label(L10n.text("Private by default"), systemImage: "lock.shield")
                    HStack(spacing: 6) {
                        Circle().fill(store.inferenceModel != nil ? PuddleStyle.teal : Color.secondary).frame(width: 6, height: 6).accessibilityHidden(true)
                        Text(store.demo ? "Demo mode" : store.inferenceModel != nil ? "Local AI connected" : "Connect local AI")
                            .lineLimit(1)
                    }
                    if store.demo { Button(L10n.text("Exit demo")) { Task { await store.leaveDemo() } }.buttonStyle(PuddleTextButtonStyle()) }
                }.font(.system(size: 10)).foregroundStyle(PuddleStyle.muted).padding(.horizontal, 10).padding(.top, 8)
            }.padding(.horizontal, 12).padding(.bottom, 18)
        }.background(PuddleStyle.sidebar)
            .onAppear { if isAdditionalSection(store.section) { showingMore = true } }
            .onChange(of: store.section) { _, section in
                if isAdditionalSection(section) { showingMore = true }
            }
            .onChange(of: pinnedSectionNames) { _, _ in
                if isAdditionalSection(store.section) { showingMore = true }
            }
    }

    private func navigationRow(_ section: PuddleStore.Section) -> some View {
        HStack(spacing: 0) {
            Button { store.section = section } label: {
                HStack(spacing: 10) {
                    Image(systemName: section.icon).font(.system(size: 14)).frame(width: 18)
                    Text(L10n.text(section.rawValue)).font(.system(size: 13, weight: .medium))
                    Spacer()
                    if section == .tasks || section == .actions {
                        let count = section == .tasks ? store.state.tasks.filter { !$0.completed }.count : actionsNeedingReview
                        if count > 0 {
                            Text(String(count)).font(.system(size: 10, weight: .medium)).monospacedDigit()
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(PuddleStyle.inset, in: Capsule())
                        }
                    }
                }.padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(L10n.text(section.rawValue))
                .accessibilityValue(store.section == section ? "Selected" : "")
                .accessibilityHint("Opens this workspace")
                .accessibilityIdentifier("navigation.\(section.nameForAccessibility)")
                .accessibilityAddTraits(store.section == section ? .isSelected : [])
            if pinnableSections.contains(section) {
                Button { togglePin(section) } label: {
                    Image(systemName: pinnedSections.contains(section) ? "pin.fill" : "pin")
                        .font(.system(size: 11)).frame(width: 28, height: 30).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.trailing, 4)
                    .foregroundStyle(pinnedSections.contains(section) ? PuddleStyle.teal : PuddleStyle.muted)
                    .accessibilityLabel(pinLabel(for: section))
                    .help(pinLabel(for: section))
            }
        }.buttonStyle(.plain).foregroundStyle(store.section == section ? PuddleStyle.teal : PuddleStyle.ink)
            .background(store.section == section ? PuddleStyle.inset : hoveredSection == section ? PuddleStyle.inset.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .onHover { hoveredSection = $0 ? section : nil }
            .contextMenu {
                if pinnableSections.contains(section) {
                    Button { togglePin(section) } label: {
                        Label(pinLabel(for: section), systemImage: pinnedSections.contains(section) ? "pin.slash" : "pin")
                    }
                }
            }
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
