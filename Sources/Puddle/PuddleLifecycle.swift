import AppKit
import PuddleCore

@MainActor final class PuddleLifecycle: NSObject, NSApplicationDelegate {
    weak var store: PuddleStore?
    weak var attendance: MeetAttendanceController?
    weak var systemDictation: SystemDictationController?
    private(set) var terminationTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var terminationID = UUID()
    private var observing = false
    var terminationTimeout: Duration = .seconds(20)
    func attach(_ store: PuddleStore) {
        self.store = store; attendance = store.meetAttendance; systemDictation = store.systemDictation
        guard !observing else { return }
        observing = true
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didResignActive), name: NSApplication.didResignActiveNotification, object: nil)
    }
    @objc private func didWake() { guard store?.isShuttingDown == false else { return }; Task { await store?.refresh() } }
    @objc private func didResignActive() {
        guard store?.isShuttingDown == false, store?.state.settings.lockOnBackground == true else { return }
        Task { await store?.lockWorkspace() }
    }
    var confirmQuit: @MainActor (String, String) -> Bool = { title, detail in
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: L10n.text("Keep Puddle open")); alert.addButton(withTitle: L10n.text("Quit anyway"))
        return alert.runModal() == .alertSecondButtonReturn
    }
    func applicationWillTerminate(_ notification: Notification) { systemDictation?.stop(); store?.meetingCapture.stopImmediately() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestTermination { sender.reply(toApplicationShouldTerminate: $0) }
    }
    func requestTermination(reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        let needsBrowserCleanup = attendance.map { $0.isActive || $0.mayStillBeInCall } ?? false
        guard store != nil || needsBrowserCleanup else { return .terminateNow }
        let id = UUID(); terminationID = id
        store?.isShuttingDown = true
        let finish: @MainActor (Bool) -> Void = { [weak self] allow in
            guard let self, self.terminationID == id else { return }
            self.terminationID = UUID(); self.deadlineTask?.cancel(); self.deadlineTask = nil
            self.terminationTask = nil
            if !allow { self.store?.resumeAfterCancelledTermination() }
            reply(allow)
        }
        deadlineTask = Task { @MainActor in
            do { try await Task.sleep(for: terminationTimeout) } catch { return }
            guard terminationID == id else { return }
            terminationTask?.cancel()
            finish(confirmQuit("Puddle is still finishing work", "Some work or saves have not finished. Quitting now may lose unsaved requests or leave provider outcomes uncertain. Keep Puddle open to finish recovery, or check the provider after quitting."))
        }
        terminationTask = Task { @MainActor in
            await store?.prepareForTermination()
            guard terminationID == id, !Task.isCancelled else { return }
            let captureFinished = await store?.finishMeetingCaptureForTermination() ?? true
            await store?.waitForPersistence()
            guard terminationID == id, !Task.isCancelled else { return }
            if store?.shutdownPendingWork.isEmpty == false || store?.executingActions.isEmpty == false {
                if !confirmQuit("Some work has not stopped", "A cancelled operation is still finishing. Unconfirmed actions are retained as uncertain. Keep Puddle open to finish saving outcomes, or check the provider after quitting.") { finish(false); return }
            }
            if store?.recoverablePrompts.isEmpty == false {
                if !confirmQuit("A request has not been saved", "Copy or retry your recovered requests before quitting. Quitting discards requests retained only in memory.") { finish(false); return }
            }
            if let failure = store?.persistenceFailure ?? (captureFinished ? nil : store?.meetingCapture.errorMessage) {
                if !confirmQuit(L10n.text("Workspace changes or meeting text could not be saved"), failure) { finish(false); return }
            }
            guard let attendance, needsBrowserCleanup else { finish(true); return }
            let closed = await attendance.leaveAndWait()
            guard terminationID == id, !Task.isCancelled else { return }
            if closed { finish(true); return }
            let title = attendance.checkingBrowser ? "The browser test tab may still be open" : "The Meet tab may still be in a call"
            let detail = attendance.checkingBrowser ? "Puddle could not verify closing its blank test tab. Close it yourself before quitting. No meeting was opened by this check." : "Puddle could not verify leaving. Close the dedicated Meet browser tab yourself before quitting."
            finish(confirmQuit(title, detail))
        }
        return .terminateLater
    }
}
