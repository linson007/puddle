import SwiftUI
import PuddleCore

struct MeetAttendanceView: View {
    @ObservedObject var store: PuddleStore
    @ObservedObject var attendance: MeetAttendanceController
    var note: MeetingNote?
    @State private var address = ""
    @State private var guestName = "Puddle notes"
    private var link: MeetingJoinLink? {
        if let stored = note?.joinLink, stored.provider == .googleMeet { return stored }
        guard let result = try? MeetingJoinLink(address), result.provider == .googleMeet else { return nil }; return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Google Meet attendance · Experimental").font(.headline)
            if note?.joinLink?.provider != .googleMeet {
                TextField("Google Meet invitation link", text: $address).textFieldStyle(.roundedBorder)
            }
            TextField("Guest name (when guest joining is allowed)", text: $guestName).textFieldStyle(.roundedBorder)
            Text("Uses a dedicated Chrome profile. Sign in there yourself if required; the call uses that Google account or the guest name above. Camera and microphone are blocked. Organizer admission may be required.")
                .font(.caption).foregroundStyle(.secondary)
            if !attendance.message.isEmpty { Text(attendance.message).font(.callout).textSelection(.enabled) }
            HStack {
                if attendance.isActive {
                    if attendance.status != .joined { ProgressView().controlSize(.small) }
                    Button(attendance.status == .joined ? "Leave meeting" : "Cancel attendance") { attendance.leave() }.disabled(attendance.status == .leaving)
                } else if attendance.mayStillBeInCall {
                    Button("I closed the Meet tab manually") { attendance.confirmClosedManually() }
                } else {
                    Button("Join Google Meet") { if let link { store.joinGoogleMeet(link, noteID: note?.id, guestName: guestName) } }
                        .buttonStyle(.borderedProminent).disabled(store.demo || link == nil || guestName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || guestName.count > 60)
                }
                if let joined = attendance.joinedAt { Text("Joined \(joined.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
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
