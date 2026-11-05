import AppKit
import PuddleCore

@MainActor final class PuddleLifecycle: NSObject, NSApplicationDelegate {
    weak var store: PuddleStore?
    weak var attendance: MeetAttendanceController?
    weak var systemDictation: SystemDictationController?
    private(set) var terminationTask: Task<Void, Never>?
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
        guard needsBrowserCleanup || store?.meetingCapture.isActive == true || store?.isCompletingMeetingCapture == true || store?.meetingCaptureNeedsQuitReview == true || (store?.pendingSaves ?? 0) > 0 || store?.persistenceFailure != nil else { return .terminateNow }
        terminationTask = Task { @MainActor in
            defer { terminationTask = nil }
            let captureFinished = await store?.finishMeetingCaptureForTermination() ?? true
            await store?.waitForPersistence()
            if let failure = store?.persistenceFailure ?? (captureFinished ? nil : store?.meetingCapture.errorMessage) {
                if !confirmQuit(L10n.text("Workspace changes or meeting text could not be saved"), failure) { reply(false); return }
            }
            guard let attendance, needsBrowserCleanup else { reply(true); return }
            let closed = await attendance.leaveAndWait()
            if closed { reply(true); return }
            let title = attendance.checkingBrowser ? "The browser test tab may still be open" : "The Meet tab may still be in a call"
            let detail = attendance.checkingBrowser ? "Puddle could not verify closing its blank test tab. Close it yourself before quitting. No meeting was opened by this check." : "Puddle could not verify leaving. Close the dedicated Meet browser tab yourself before quitting."
            reply(confirmQuit(title, detail))
        }
        return .terminateLater
    }
}
