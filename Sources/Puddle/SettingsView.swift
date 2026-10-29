import SwiftUI
import PuddleCore

struct GoogleSetupView: View {
    @ObservedObject var store: PuddleStore
    @Environment(\.dismiss) private var dismiss
    @State private var mail = true
    @State private var calendar = true
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                PuddleMark(size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect Google").font(.title2).fontWeight(.semibold)
                    Text("Your inbox and calendar, ready when you need them.").foregroundStyle(.secondary)
                }
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Puddle works without connected accounts. Connect Google when you want it to help with your email or schedule.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 24) {
                        Toggle("Read Gmail", isOn: $mail).toggleStyle(.checkbox)
                        Toggle("Read Calendar events", isOn: $calendar).toggleStyle(.checkbox)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(PuddleStyle.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    Text("Google will open in your browser. Choose your account and approve the services you want to connect. Puddle will then load your latest mail and upcoming events.")
                        .font(.callout).foregroundStyle(.secondary)
                    Picker("Sign-in browser", selection: $store.googleSignInBrowser) {
                        ForEach(GoogleSignInBrowser.allCases) { browser in Text(browser.title).tag(browser) }
                    }
                    if !store.configured {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Google sign-in needs a one-time setup in this build.", systemImage: "info.circle")
                                .font(.callout)
                            Text("The app owner can provide the Google client once. Everyone using that build can then connect through Google’s sign-in screen.")
                                .font(.callout).foregroundStyle(.secondary)
                            DisclosureGroup("App owner setup") {
                                VStack(alignment: .leading, spacing: 16) {
                                    step("1", "Enable Gmail and Calendar", "In your Google Cloud project, enable Gmail API and Google Calendar API.")
                                    step("2", "Configure Google Auth Platform", "Set the app name to Puddle. For personal Gmail, choose External audience and add your address under Audience → Test users.")
                                    step("3", "Create a Desktop app client", "Under Clients, create a Desktop app OAuth client. Download its JSON and import it once below.")
                                    Link("Open Google Cloud Console ↗", destination: URL(string: "https://console.cloud.google.com/auth/overview")!)
                                    Button("Import Google Client JSON…") { store.importClient() }.disabled(store.isSigningIn)
                                }.padding(.top, 12)
                            }
                        }.padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                    }
                    Label("Tokens stay in macOS Keychain. Selected data goes to your local model when you ask Puddle to use it.", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                    if store.configured {
                        DisclosureGroup("App owner settings") {
                            Button("Replace Google Client JSON…") { store.importClient() }
                                .disabled(store.isSigningIn || store.connected)
                            Text("Disconnect Google before replacing the app’s client configuration.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.font(.caption)
                    }
                    if let error = store.errorMessage { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                }
            }
            Divider()
            HStack {
                Spacer()
                if store.isSigningIn {
                    ProgressView().controlSize(.small)
                    Text(store.googleSignInStatus).font(.caption).foregroundStyle(.secondary)
                    Button("Cancel") { store.cancelSignIn() }
                } else {
                    Button("Close") { dismiss() }
                    Button("Sign in with Google") {
                        let scopes = (mail ? [OAuthFlow.scope] : []) + (calendar ? [OAuthFlow.calendarScope] : [])
                        store.connect(scopes: scopes)
                    }.buttonStyle(.borderedProminent).disabled(!store.configured || (!mail && !calendar))
                }
            }
        }.padding(28).frame(width: 620, height: store.configured ? 430 : 650).tint(PuddleStyle.teal)
            .onAppear {
                if store.connected { mail = store.mailConnected; calendar = store.calendarConnected }
            }
    }
    private func step(_ number: String, _ title: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.system(size: 12, weight: .semibold)).foregroundStyle(PuddleStyle.teal)
                .frame(width: 26, height: 26).background(PuddleStyle.teal.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PuddleSettingsView: View {
    @ObservedObject var store: PuddleStore
    @State private var showingGoogleSetup = false
    @State private var address = ""
    @State private var key = ""
    @State private var interval = 60
    @State private var automatic = true
    @State private var summarize = false
    @State private var persona = ""
    var body: some View {
        TabView(selection: $store.settingsTab) {
            Form {
                Section("Your assistant") {
                    Toggle("Automatically learn personal memories", isOn: Binding(
                        get: { store.state.settings.automaticallyLearn }, set: { store.setAutomaticLearning($0) }))
                    Text("Tell Puddle how you like to work and how you want it to respond.").foregroundStyle(.secondary)
                    TextEditor(text: $persona).font(.body).frame(height: 110)
                        .accessibilityLabel("Assistant preferences")
                    Button("Save Preferences") { store.savePersona(persona) }
                    Text("Saved memories and tasks carry across conversations. Manage them from the sidebar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Reminders & updates") {
                    Toggle("Allow desktop notifications", isOn: Binding(get: { store.state.settings.notifications }, set: { value in
                        Task { await store.enableNotifications(value) }
                    })).disabled(store.demo)
                    Text("macOS schedules enabled reminders even while Puddle is closed. Due reminders also appear in chat after launch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Voice") {
                    Toggle("Read new replies aloud", isOn: Binding(get: { store.state.settings.readRepliesAloud }, set: { store.setReadRepliesAloud($0) }))
                    Picker("Voice language", selection: Binding(get: { store.state.settings.speechLanguage }, set: { store.setSpeechLanguage($0) })) {
                        Text("English (US)").tag("en-US"); Text("English (India)").tag("en-IN")
                        Text("English (UK)").tag("en-GB"); Text("Hindi").tag("hi-IN")
                    }
                    Picker("Speaking speed", selection: Binding(get: { store.state.settings.speechSpeed }, set: { store.setSpeechSpeed($0) })) {
                        Text("Slower").tag(0.8); Text("Normal").tag(1.0); Text("Faster").tag(1.2)
                    }
                    Text("Uses an installed macOS voice. You can also read individual replies aloud from chat.").font(.caption).foregroundStyle(.secondary)
                    if store.speakingMessageID != nil { Button("Stop speaking") { store.stopSpeaking() } }
                }
                Section("Local storage") {
                    Button("Retry Loading State") { Task { await store.retryLoadingState() } }.disabled(store.demo)
                    Text("Conversation, memory, tasks, and cached connection data stay in Application Support/Puddle. The cache has owner-only permissions. Credentials use Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("Assistant", systemImage: "bubble.left.and.bubble.right") }.tag("assistant")

            Form {
                Section("Splash on this Mac") {
                    Picker("Context budget", selection: Binding(get: { store.state.settings.contextTokens }, set: { store.setContextTokens($0) })) {
                        Text("4K tokens").tag(4096); Text("8K tokens").tag(8192); Text("16K tokens").tag(16384); Text("32K tokens").tag(32768)
                    }
                    TextField("Server address", text: $address).textFieldStyle(.roundedBorder)
                    SecureField("API key (optional)", text: $key).textFieldStyle(.roundedBorder)
                    Text("Start Splash separately. Puddle uses its local model for conversation and tool decisions; Google sign-in is optional.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Save and Test Connection") {
                            Task { await store.saveSettings(address: address, key: key, interval: interval, automatic: automatic, summarize: summarize, testConnection: true) }
                        }.disabled(store.isTestingSplash)
                        if store.isTestingSplash { ProgressView().controlSize(.small) }
                    }
                    if let model = store.splashModel {
                        Label("Connected: \(model)", systemImage: "checkmark.circle.fill").foregroundStyle(PuddleStyle.teal).textSelection(.enabled)
                    }
                    if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                }
                Section("Data boundaries") {
                    Text("AI requests are restricted to loopback addresses on this Mac. Puddle automatically learns personal facts from your messages. Email and calendar are read-only reference material. Reminders wait for your approval.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("Local AI", systemImage: "desktopcomputer") }.tag("localAI")

            Form {
                Section("Optional Google connection") {
                    Picker("Sign-in browser", selection: $store.googleSignInBrowser) {
                        ForEach(GoogleSignInBrowser.allCases) { browser in Text(browser.title).tag(browser) }
                    }
                    if store.connected {
                        LabeledContent("Account", value: store.state.account ?? "Google account")
                        Text("\(store.mailConnected ? "Gmail" : "") \(store.calendarConnected ? "Calendar" : "") · read only")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Manage Permissions…") { showingGoogleSetup = true }
                        Button("Disconnect Google") { store.disconnect() }
                    } else {
                        Text("Connect Gmail, Calendar, or both when you want Puddle to use them.").foregroundStyle(.secondary)
                        Button(store.isSigningIn ? "Connecting Google…" : "Connect Google") {
                            if store.configured { store.connect() } else { showingGoogleSetup = true }
                        }
                            .disabled(store.isSigningIn)
                        if store.isSigningIn {
                            Text(store.googleSignInStatus).font(.caption).foregroundStyle(.secondary)
                            Button("Cancel") { store.cancelSignIn() }
                        }
                    }
                }
                Section("Mail updates") {
                    Toggle("Check new mail while Puddle is running", isOn: $automatic)
                    Picker("Check every", selection: $interval) {
                        Text("1 minute").tag(60); Text("2 minutes").tag(120)
                        Text("5 minutes").tag(300); Text("10 minutes").tag(600)
                    }
                    Toggle("Summarize up to 3 new emails per check", isOn: $summarize)
                    Button("Save Connection Preferences") {
                        Task { await store.saveSettings(address: address, key: key, interval: interval, automatic: automatic, summarize: summarize) }
                    }
                    Text("Mail checks use the 50 most recent inbox messages. Chat can search Gmail on demand. Calendar tools read up to 50 upcoming primary-calendar events over at most 14 days.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("Connections", systemImage: "point.3.connected.trianglepath.dotted") }.tag("connections")

            VStack(alignment: .leading, spacing: 16) {
                Text("Recent activity").font(.title3).fontWeight(.semibold)
                Text("Tool use, connections, and local actions. Tokens and email bodies are not included.")
                    .font(.caption).foregroundStyle(.secondary)
                List(store.state.activity) { event in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(event.text).font(.callout)
                        Text(event.date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }.overlay { if store.state.activity.isEmpty { Text("No activity yet").foregroundStyle(.secondary) } }
            }.padding(24).tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }.tag("activity")
        }.frame(width: 680, height: 570).tint(PuddleStyle.teal)
            .onAppear {
                address = store.state.settings.splashAddress; key = store.apiKey
                interval = store.state.settings.pollSeconds; automatic = store.state.settings.automaticallyCheck
                summarize = store.state.settings.automaticallySummarize; persona = store.state.assistantInstructions
            }
            .sheet(isPresented: $showingGoogleSetup) { GoogleSetupView(store: store) }
            .onChange(of: store.connected) { _, connected in if connected { showingGoogleSetup = false } }
    }
}
