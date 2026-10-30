import AppKit

@MainActor final class PuddleLifecycle: NSObject, NSApplicationDelegate {
    weak var attendance: MeetAttendanceController?
    weak var splashSetup: SplashSetupController?
    weak var systemDictation: SystemDictationController?
    func applicationWillTerminate(_ notification: Notification) { splashSetup?.stop(); systemDictation?.stop() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let attendance, attendance.isActive || attendance.mayStillBeInCall else { return .terminateNow }
        Task { @MainActor in
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
