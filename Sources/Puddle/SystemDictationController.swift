import AppKit
import ApplicationServices
import Carbon
import Combine
import SwiftUI
import PuddleCore

@MainActor protocol DictationTargeting: AnyObject {
    var isAuthorized: Bool { get }
    func requestAuthorization()
    func captureTarget() throws
    func insert(_ text: String) throws
}
@MainActor final class AccessibilityDictationTarget: DictationTargeting {
    private var target: AXUIElement?
    private var pid: pid_t?
    var isAuthorized: Bool { AXIsProcessTrusted() }
    func requestAuthorization() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
    private func focused() throws -> AXUIElement {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { throw PuddleError("Focus an editable text field first.") }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        var role: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &role)
        guard role as? String != kAXSecureTextFieldSubrole else { throw PuddleError("Dictation is disabled in password fields.") }
        return element
    }
    func captureTarget() throws {
        guard isAuthorized else { throw PuddleError("Enable Puddle in Accessibility settings, then refresh permissions.") }
        let element = try focused(); var process: pid_t = 0
        guard AXUIElementGetPid(element, &process) == .success else { throw PuddleError("Could not identify the target application.") }
        target = element; pid = process
    }
    func insert(_ text: String) throws {
        guard let target, let pid, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              CFEqual(try focused(), target) else { throw PuddleError("The focused field changed. Your transcript is retained; copy it into the intended field.") }
        guard AXUIElementSetAttributeValue(target, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            throw PuddleError("This app does not support direct text insertion. Copy the retained transcript and paste it yourself.")
        }
    }
}

@MainActor final class SystemDictationController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var status = "Hold ⌘⇧Space to dictate into the focused field."
    @Published private(set) var retainedText = ""
    let voice: VoiceInputController
    var canStart: () -> Bool = { true }
    private let target: any DictationTargeting
    private var settings = PuddleSettings()
    private var subscription: AnyCancellable?
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var panel: NSPanel?
    private var held = false
    private let displaysOverlay: Bool
    init(capture: (any SpeechCapturing)? = nil, target: (any DictationTargeting)? = nil, displaysOverlay: Bool = true) {
        self.displaysOverlay = displaysOverlay
        self.target = target ?? AccessibilityDictationTarget()
        voice = VoiceInputController(capture: capture ?? SystemSpeechCapture(), maximumSeconds: 180)
        subscription = voice.$completedTranscript.compactMap { $0 }.sink { [weak self] draft in self?.completed(draft.text) }
    }
    func configure(_ settings: PuddleSettings, requestPermission: Bool = false, registerShortcut: Bool = true) {
        stop(); self.settings = settings
        guard settings.systemDictationEnabled else { return }
        if requestPermission { target.requestAuthorization() }
        guard target.isAuthorized else { status = "Enable Puddle in System Settings → Privacy & Security → Accessibility, then refresh permissions here."; return }
        enabled = true; status = "Hold ⌘⇧Space to dictate into the focused field. Release to insert."
        guard registerShortcut else { return }
        var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)), EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<SystemDictationController>.fromOpaque(context).takeUnretainedValue()
            let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            Task { @MainActor in if down { owner.press() } else { owner.release() } }
            return noErr
        }
        let installed = InstallEventHandler(GetApplicationEventTarget(), callback, 2, &events, context, &handler)
        let registered = RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x5044444C, id: 1), GetApplicationEventTarget(), 0, &hotkey)
        if installed != noErr || registered != noErr { stop(); status = "The shortcut could not register. Another application may already use ⌘⇧Space." }
    }
    func press() {
        guard enabled, !held, !voice.isActive, canStart() else { return }
        do {
            try target.captureTarget(); held = true; retainedText = ""; status = "Listening on this Mac… Release ⌘⇧Space when finished."
            showPanel(); voice.start(language: settings.speechLanguage)
        } catch { status = error.localizedDescription; showPanel() }
    }
    func release() { guard held else { return }; held = false; voice.finish() }
    private func completed(_ text: String) {
        let cleaned = DictationCleanup.apply(text, replacements: settings.dictationVocabulary, punctuation: settings.dictationPunctuation)
        retainedText = cleaned
        do { try target.insert(cleaned); status = "Inserted into the original field."; panel?.orderOut(nil) }
        catch { status = error.localizedDescription; showPanel() }
    }
    func cancel() { held = false; voice.cancel(); retainedText = ""; panel?.orderOut(nil) }
    func stop() {
        cancel(); enabled = false
        if let hotkey { UnregisterEventHotKey(hotkey); self.hotkey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        panel?.contentView = nil; panel?.close(); panel = nil
    }
    private func showPanel() {
        guard displaysOverlay else { return }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Puddle Dictation"; panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: SystemDictationOverlay(controller: self, voice: voice)); panel.center(); self.panel = panel
        }
        panel?.orderFrontRegardless()
    }
}

private struct SystemDictationOverlay: View {
    @ObservedObject var controller: SystemDictationController
    @ObservedObject var voice: VoiceInputController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(voice.isActive ? "Listening locally" : "Dictation", systemImage: voice.isActive ? "mic.fill" : "text.cursor").foregroundStyle(voice.isActive ? .red : PuddleStyle.teal)
            Text(controller.status).font(.caption)
            Text(voice.isActive ? voice.transcript : controller.retainedText).font(.callout).lineLimit(5).textSelection(.enabled)
            if let error = voice.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                if voice.isActive { Button("Finish") { controller.release() } }
                if !controller.retainedText.isEmpty { Button("Copy Transcript") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(controller.retainedText, forType: .string) } }
                Spacer(); Button("Dismiss") { controller.cancel() }
            }
        }.padding(16).frame(width: 440)
    }
}
