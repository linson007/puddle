import AppKit

@MainActor final class PuddleLifecycle: NSObject, NSApplicationDelegate {
    weak var store: PuddleStore?
    weak var attendance: MeetAttendanceController?
    weak var systemDictation: SystemDictationController?
    func applicationWillTerminate(_ notification: Notification) { systemDictation?.stop() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let needsBrowserCleanup = attendance.map { $0.isActive || $0.mayStillBeInCall } ?? false
        guard needsBrowserCleanup || (store?.pendingSaves ?? 0) > 0 || store?.persistenceFailure != nil else { return .terminateNow }
        Task { @MainActor in
            await store?.waitForPersistence()
            if let failure = store?.persistenceFailure {
                let alert = NSAlert(); alert.messageText = "Workspace changes could not be saved"
                alert.informativeText = failure
                alert.addButton(withTitle: "Keep Puddle open"); alert.addButton(withTitle: "Quit anyway")
                if alert.runModal() != .alertSecondButtonReturn { sender.reply(toApplicationShouldTerminate: false); return }
            }
            guard let attendance, needsBrowserCleanup else { sender.reply(toApplicationShouldTerminate: true); return }
            let closed = await attendance.leaveAndWait()
            if closed { sender.reply(toApplicationShouldTerminate: true); return }
            let alert = NSAlert()
            alert.messageText = attendance.checkingBrowser ? "The browser test tab may still be open" : "The Meet tab may still be in a call"
            alert.informativeText = attendance.checkingBrowser ? "Puddle could not verify closing its blank test tab. Close it yourself before quitting. No meeting was opened by this check." : "Puddle could not verify leaving. Close the dedicated Meet browser tab yourself before quitting."
            alert.addButton(withTitle: "Keep Puddle open"); alert.addButton(withTitle: "Quit anyway")
            sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
        }
        return .terminateLater
    }
}
