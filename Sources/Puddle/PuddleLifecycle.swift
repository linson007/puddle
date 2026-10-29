import AppKit

@MainActor final class PuddleLifecycle: NSObject, NSApplicationDelegate {
    weak var attendance: MeetAttendanceController?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let attendance, attendance.isActive || attendance.mayStillBeInCall else { return .terminateNow }
        Task { @MainActor in
            let closed = await attendance.leaveAndWait()
            if closed { sender.reply(toApplicationShouldTerminate: true); return }
            let alert = NSAlert()
            alert.messageText = "The Meet tab may still be in a call"
            alert.informativeText = "Puddle could not verify leaving. Close the dedicated Meet browser tab yourself before quitting."
            alert.addButton(withTitle: "Keep Puddle open"); alert.addButton(withTitle: "Quit anyway")
            sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
        }
        return .terminateLater
    }
}
