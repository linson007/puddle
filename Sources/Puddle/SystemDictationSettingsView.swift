import SwiftUI
import PuddleCore

struct SystemDictationSettingsView: View {
    @ObservedObject var store: PuddleStore
    @ObservedObject var controller: SystemDictationController
    @State private var vocabulary = ""
    var body: some View {
        Section("Dictate into other apps") {
            Toggle("Enable systemwide dictation · hold ⌘⇧Space", isOn: Binding(get: { store.state.settings.systemDictationEnabled }, set: { store.setSystemDictationEnabled($0) })).disabled(store.demo)
            Text(controller.status).font(.caption).foregroundStyle(.secondary)
            Button("Refresh Accessibility Permissions") { controller.configure(store.state.settings) }.disabled(!store.state.settings.systemDictationEnabled)
            Toggle("Capitalize and finish sentences", isOn: Binding(get: { store.state.settings.dictationPunctuation }, set: { enabled in
                do { try store.commit { $0.settings.dictationPunctuation = enabled }; controller.configure(store.state.settings) } catch { store.fail(error) }
            }))
            Text("Custom vocabulary · spoken phrase=written phrase").font(.caption)
            TextEditor(text: $vocabulary).frame(height: 70).accessibilityLabel("Dictation vocabulary")
            Button("Save Vocabulary") {
                do { let parsed = try DictationCleanup.vocabulary(vocabulary); try store.commit { $0.settings.dictationVocabulary = parsed }; controller.configure(store.state.settings) }
                catch { store.fail(error) }
            }
            Text("Focus a text field, hold the shortcut, speak, and release. Audio stays on this Mac. Password fields are excluded. If focus changes or an app cannot accept direct insertion, the transcript stays available to copy. No message is submitted. Up to three minutes per capture; unavailable while Puddle is locked or in a private session.").font(.caption).foregroundStyle(.secondary)
        }.onAppear { vocabulary = store.state.settings.dictationVocabulary.keys.sorted().map { $0 + "=" + store.state.settings.dictationVocabulary[$0]! }.joined(separator: "\n") }
    }
}
