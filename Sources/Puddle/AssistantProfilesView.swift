import SwiftUI
import PuddleCore

struct ProfileSwitcher: View {
    @ObservedObject var store: PuddleStore
    @State private var managing = false
    var body: some View {
        Menu {
            ForEach(store.state.profileLibrary.profiles) { profile in
                Button { store.switchAssistantProfile(profile.id) } label: {
                    Label(profile.title, systemImage: profile.id == store.state.profileLibrary.activeID ? "checkmark" : profile.kind.icon)
                }
            }
            Divider()
            Button("Manage Profiles…") { managing = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: store.state.profileLibrary.active.kind.icon)
                    .frame(width: 28, height: 28).background(PuddleStyle.inset, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.state.profileLibrary.active.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text("Shared workspace").font(.system(size: 10)).foregroundStyle(PuddleStyle.muted)
                }
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.menuStyle(.borderlessButton)
            .padding(10).background(PuddleStyle.inset.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(PuddleStyle.line))
            .accessibilityLabel("Assistant profile: \(store.state.profileLibrary.active.title)")
            .help("Switch role guidance and profile tools. Shared conversations, memory and work stay available; switching stops the current reply.")
            .sheet(isPresented: $managing) { AssistantProfilesView(store: store) }
    }
}

private struct ProfileEditorRequest: Identifiable {
    var id: UUID { profile.id }
    let profile: AssistantProfile
    let isNew: Bool
}

struct AssistantProfilesView: View {
    @ObservedObject var store: PuddleStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ProfileEditorRequest?
    @State private var deleting: AssistantProfile?
    @State private var confirmingDelete = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Assistant profiles").font(.title2).fontWeight(.semibold)
                Spacer()
                Menu("New Profile") {
                    ForEach(AssistantProfileKind.allCases, id: \.self) { kind in
                        Button { newProfile(kind) } label: { Label(kind.title, systemImage: kind.icon) }
                    }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Each profile has its own role, work context and guidance. Chats, memories, tasks, meetings and connections are shared. Switching stops the current reply.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.state.profileLibrary.profiles) { profile in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: profile.kind.icon).font(.title3).foregroundStyle(PuddleStyle.teal).frame(width: 28)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(profile.title).font(.headline)
                                    if profile.id == store.state.profileLibrary.activeID { Text("Active").font(.caption).foregroundStyle(PuddleStyle.teal) }
                                }
                                Text(profile.kind.summary).font(.callout).foregroundStyle(.secondary)
                                if !profile.context.role.isEmpty || !profile.context.organization.isEmpty {
                                    Text([profile.context.role, profile.context.organization].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .trailing, spacing: 8) {
                                Button(profile.id == store.state.profileLibrary.activeID ? "Selected" : "Use Profile") { store.switchAssistantProfile(profile.id) }
                                    .disabled(profile.id == store.state.profileLibrary.activeID)
                                HStack {
                                    Button("Edit") { editing = ProfileEditorRequest(profile: profile, isNew: false) }.buttonStyle(.link)
                                    Menu {
                                        Button("Duplicate") { store.duplicateAssistantProfile(profile.id) }
                                        Button("Remove…", role: .destructive) { deleting = profile; confirmingDelete = true }
                                            .disabled(profile.id == store.state.profileLibrary.activeID || store.state.profileLibrary.profiles.count <= 1)
                                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
                                        .accessibilityLabel("Actions for profile \(profile.title)")
                                }
                            }
                        }.padding(16).background(PuddleStyle.panel, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Text("Profiles change how Puddle helps. Source access still requires a project folder you choose. Removing an inactive profile deletes only its saved role configuration.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(26).frame(width: 720, height: 610)
            .sheet(item: $editing) { request in AssistantProfileEditor(store: store, profile: request.profile, isNew: request.isNew) }
            .confirmationDialog("Remove \(deleting?.title ?? "this profile")?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Remove Profile", role: .destructive) { if let deleting { store.deleteAssistantProfile(deleting.id) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This removes only the role configuration. Shared chats, memories and work remain available.") }
    }
    private func newProfile(_ kind: AssistantProfileKind) {
        var context = ExecutiveProfile(); context.name = store.state.profile.name; context.organization = store.state.profile.organization
        let profile = AssistantProfile(kind: kind, title: store.state.profileLibrary.availableTitle(kind.title), context: context)
        editing = ProfileEditorRequest(profile: profile, isNew: true)
    }
}

struct AssistantProfileEditor: View {
    @ObservedObject var store: PuddleStore
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AssistantProfile
    init(store: PuddleStore, profile: AssistantProfile, isNew: Bool) {
        self.store = store; self.isNew = isNew; _draft = State(initialValue: profile)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New assistant profile" : "Edit assistant profile").font(.title2).fontWeight(.semibold)
            ScrollView {
                Form {
                    TextField("Profile name", text: $draft.title).textFieldStyle(.roundedBorder)
                    Picker("Approach", selection: $draft.kind) {
                        ForEach(AssistantProfileKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text(draft.kind.summary).font(.callout).foregroundStyle(.secondary)
                    TextField("Your name (optional)", text: $draft.context.name).textFieldStyle(.roundedBorder)
                    TextField("Your role (optional)", text: $draft.context.role).textFieldStyle(.roundedBorder)
                    TextField("Organization (optional)", text: $draft.context.organization).textFieldStyle(.roundedBorder)
                    TextField(draft.kind.objectivesLabel, text: $draft.context.objectives, axis: .vertical).lineLimit(3...5).textFieldStyle(.roundedBorder)
                    TextField("Additional guidance (optional)", text: $draft.additionalGuidance, axis: .vertical).lineLimit(3...5).textFieldStyle(.roundedBorder)
                    DisclosureGroup("Built-in role guidance") { Text(draft.kind.guidance).font(.caption).textSelection(.enabled) }
                }
            }
            Text("Saved locally. General response preferences, memory and work remain shared across profiles.").font(.caption).foregroundStyle(.secondary)
            if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create & Use Profile" : "Save Profile") {
                    if store.saveAssistantProfile(draft, isNew: isNew) { dismiss() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 590, height: 610)
    }
}
