import Combine
import Foundation
import PuddleCore

enum MeetAttendanceStatus: Equatable { case idle, opening, ready, joining, signIn, waiting, joined, leaving, ended, failed }

@MainActor final class MeetAttendanceController: ObservableObject {
    @Published private(set) var status = MeetAttendanceStatus.idle
    @Published private(set) var noteID: UUID?
    @Published private(set) var message = ""
    @Published private(set) var joinedAt: Date?
    @Published private(set) var mayStillBeInCall = false
    @Published private(set) var checkingBrowser = false
    var isActive: Bool { ![.idle, .ended, .failed].contains(status) }
    private let launcher: any MeetBrowserLaunching
    private let pollSeconds: Double
    private let admissionTimeout: Double
    private let maximumCallSeconds: Double
    private var generation = UUID()
    private var work: Task<Void, Never>?
    private var browser: GoogleMeetBrowserSession?
    var onEnded: (@MainActor (UUID) -> Void)?

    init(launcher: any MeetBrowserLaunching, pollSeconds: Double = 2, admissionTimeout: Double = 600, maximumCallSeconds: Double = 7200) {
        self.launcher = launcher; self.pollSeconds = pollSeconds; self.admissionTimeout = admissionTimeout; self.maximumCallSeconds = maximumCallSeconds
    }
    func checkBrowser() {
        guard !isActive, !mayStillBeInCall else { return }
        generation = UUID(); let expected = generation
        checkingBrowser = true
        status = .opening; noteID = nil; joinedAt = nil; message = "Checking Chrome on a blank page. No meeting will be opened…"
        work = Task { [weak self] in
            guard let self else { return }
            var session: GoogleMeetBrowserSession?
            do {
                let connection = try await launcher.connect()
                guard !Task.isCancelled, generation == expected else { await connection.close(); return }
                let current = GoogleMeetBrowserSession(connection: connection); session = current; browser = current
                mayStillBeInCall = true
                let version = try await current.checkConnection()
                let closed = await current.leave()
                guard generation == expected else { return }
                browser = nil; mayStillBeInCall = !closed; status = closed ? .ended : .failed
                message = "\(version): browser commands passed. " + (closed ? "The blank test tab was verified closed. No meeting was opened." : "Close the blank test tab manually; cleanup could not be verified. No meeting was opened.")
            } catch {
                guard generation == expected else { return }
                let closed = await session?.leave() ?? true
                guard generation == expected else { return }
                browser = nil; mayStillBeInCall = !closed; status = .failed
                message = error.localizedDescription + (closed ? " No meeting was opened." : " Close the dedicated test tab manually; cleanup could not be verified. No meeting was opened.")
            }
        }
    }
    func join(link: MeetingJoinLink, noteID: UUID?, guestName: String) {
        guard !isActive, !mayStillBeInCall else { return }
        let name = guestName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60, link.provider == .googleMeet else { status = .failed; message = "Use a Google Meet link and a guest name up to 60 characters."; return }
        generation = UUID(); let expected = generation
        checkingBrowser = false
        status = .opening; self.noteID = noteID; joinedAt = nil; message = "Opening Puddle's dedicated Chrome profile…"
        work = Task { [weak self] in
            guard let self else { return }
            var session: GoogleMeetBrowserSession?
            do {
                try Task.checkCancellation()
                let connection = try await launcher.connect()
                guard !Task.isCancelled, generation == expected else { await connection.close(); return }
                let current = GoogleMeetBrowserSession(connection: connection); session = current; browser = current
                mayStillBeInCall = true
                try await current.open(link: link)
                let started = Date(); var attemptedJoin = false; var unknownCount = 0
                while generation == expected {
                    try Task.checkCancellation()
                    let state = try await current.inspect(join: !attemptedJoin, guestName: name)
                    guard generation == expected else { return }
                    if state.clickedJoin { attemptedJoin = true }
                    switch state.stage {
                    case .joined:
                        status = .joined; message = "In call. Camera and microphone are blocked in this browser."
                        if joinedAt == nil { joinedAt = Date() }
                    case .signIn: status = .signIn; message = "Sign in manually in the dedicated Chrome window. The assistant will continue joining afterward."
                    case .waiting: status = .waiting; message = "Waiting for the organizer to admit you."
                    case .prejoin: status = .ready; message = "Preparing the join request. Check the Chrome window if it needs your input."
                    case .joining: status = .joining; message = "Submitting the join request…"
                    case .ended:
                        mayStillBeInCall = false
                        status = .ended; message = "The Meet page reports that the call ended or the join request was denied."
                        let closed = await current.leave(); browser = nil
                        if !closed { message += " Close the dedicated tab manually before starting another session." }
                        if let noteID { onEnded?(noteID) }; return
                    case .unsupported:
                        unknownCount += 1
                        if unknownCount > 15 { throw PuddleError("The Meet page needs manual attention or its layout changed. Continue in the dedicated Chrome window.") }
                        message = "Waiting for the Meet page. Check the dedicated Chrome window."
                    }
                    if state.stage != .unsupported { unknownCount = 0 }
                    if let joinedAt {
                        if Date().timeIntervalSince(joinedAt) > maximumCallSeconds { throw PuddleError("The two-hour attendance limit was reached.") }
                    } else if Date().timeIntervalSince(started) > admissionTimeout { throw PuddleError("The sign-in or admission wait timed out. Check the meeting and try again.") }
                    try await Task.sleep(for: .seconds(pollSeconds))
                }
            } catch {
                guard generation == expected else { return }
                let reason = error is CancellationError ? "Attendance was cancelled." : error.localizedDescription
                if let session {
                    let owned = await session.hasOwnedTarget
                    let left = await session.leave()
                    guard generation == expected else { return }
                    message = reason + (left ? (owned ? " The managed Meet tab was closed." : "") : " Close the dedicated Meet tab manually; leaving could not be verified.")
                    mayStillBeInCall = !left
                } else { message = reason }
                status = .failed; browser = nil
                if let noteID { onEnded?(noteID) }
            }
        }
    }
    func leave() {
        guard isActive, status != .leaving else { return }
        generation = UUID(); let expected = generation; work?.cancel()
        let session = browser; browser = nil; status = .leaving; message = "Closing the managed Meet tab…"
        work = Task { [weak self] in
            let closed = await session?.leave() ?? true
            guard let self, self.generation == expected else { return }
            self.status = closed ? .ended : .failed
            self.mayStillBeInCall = !closed
            self.message = closed ? (session == nil ? "Attendance stopped before a call was opened." : (self.checkingBrowser ? "The blank test tab was verified closed. No meeting was opened." : "The managed Meet tab was verified closed.")) : (self.checkingBrowser ? "Close the dedicated test tab manually; cleanup could not be verified. No meeting was opened." : "Close the dedicated Meet tab manually; leaving could not be verified.")
            if let noteID = self.noteID { self.onEnded?(noteID) }
        }
    }
    func leaveAndWait() async -> Bool {
        if isActive { leave(); await work?.value }
        return !mayStillBeInCall
    }
    func confirmClosedManually() {
        guard !isActive else { return }
        mayStillBeInCall = false; status = .idle; checkingBrowser = false; message = "Tracking stopped after you confirmed the browser tab is closed."
    }
}
