import SwiftUI
import PuddleCore

struct MeetAttendanceView: View {
    @ObservedObject var store: PuddleStore
    @ObservedObject var attendance: MeetAttendanceController
    var note: MeetingNote?
    var invitation: Binding<String>? = nil
    @State private var address = ""
    @State private var guestName = "Puddle notes"
    private var link: MeetingJoinLink? {
        if let stored = note?.joinLink, stored.provider == .googleMeet { return stored }
        guard let result = try? MeetingJoinLink(invitation?.wrappedValue ?? address), result.provider == .googleMeet else { return nil }; return result
    }
    private var joinDisabledReason: String? {
        guard !attendance.isActive && !attendance.mayStillBeInCall else { return nil }
        if store.demo { return "Exit Demo mode to join Google Meet." }
        if link == nil {
            let entered = (invitation?.wrappedValue ?? address).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entered.isEmpty else { return nil }
            do {
                let parsed = try MeetingJoinLink(entered)
                if parsed.provider != .googleMeet { return "Automatic attendance requires a Google Meet invitation link." }
            } catch { return error.localizedDescription }
        }
        let name = guestName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || guestName.count > 60 { return "Enter a guest name between 1 and 60 characters to join." }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Google Meet attendance · Experimental").font(.headline)
            if invitation == nil && note?.joinLink?.provider != .googleMeet {
                TextField("Google Meet invitation link", text: $address).textFieldStyle(.roundedBorder)
            }
            TextField("Guest name (when guest joining is allowed)", text: $guestName).textFieldStyle(.roundedBorder)
            Text("Uses a dedicated Chrome profile. Sign in there yourself if required; the call uses that Google account or the guest name above. Camera and microphone are blocked. Organizer admission may be required.")
                .font(.caption).foregroundStyle(.secondary)
            if !attendance.message.isEmpty { Text(attendance.message).font(.callout).textSelection(.enabled) }
            HStack {
                if attendance.isActive {
                    if attendance.status != .joined { ProgressView().controlSize(.small) }
                    Button(attendance.status == .joined ? "Leave meeting" : (attendance.checkingBrowser ? "Cancel check" : "Cancel attendance")) { attendance.leave() }.disabled(attendance.status == .leaving)
                } else if attendance.mayStillBeInCall {
                    Button(attendance.checkingBrowser ? "I closed the test tab manually" : "I closed the Meet tab manually") { attendance.confirmClosedManually() }
                } else {
                    Button("Join Google Meet") { if let link { store.joinGoogleMeet(link, noteID: note?.id, guestName: guestName) } }
                        .buttonStyle(.borderedProminent).disabled(store.demo || link == nil || guestName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || guestName.count > 60)
                    Button("Check browser setup") { store.checkMeetBrowser() }.disabled(store.demo || store.privateSession || store.isLocked || store.state.settings.networkDisabled)
                        .help("Test Chrome commands on a blank page and verify cleanup without opening a meeting")
                }
                if let joined = attendance.joinedAt { Text("Joined \(joined.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            }
            if let reason = joinDisabledReason {
                Text(reason).font(.caption).foregroundStyle(.orange)
            }
            Text("After admission, use Live transcription and select this Chrome app in the macOS audio-sharing picker. Meeting-page automation can need manual help after Meet UI changes. Only the dedicated tab is closed when leaving.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16).background(PuddleStyle.background, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct MeetAttendanceBanner: View {
    @ObservedObject var store: PuddleStore
    @ObservedObject var attendance: MeetAttendanceController
    var body: some View {
        if attendance.isActive || attendance.mayStillBeInCall {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "video.fill").foregroundStyle(PuddleStyle.teal)
                Text(attendance.message).font(.caption).textSelection(.enabled)
                Spacer()
                Button("Meetings") {
                    if let id = attendance.noteID { store.meetingWorkspace.selectedID = id }
                    store.section = .meetings
                }
                if attendance.isActive { Button("Leave") { attendance.leave() }.disabled(attendance.status == .leaving) }
            }.padding(12).background(PuddleStyle.teal.opacity(0.09))
        }
    }
}
