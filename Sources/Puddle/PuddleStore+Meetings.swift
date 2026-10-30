import AppKit
import Foundation
import PuddleCore
import UniformTypeIdentifiers

extension PuddleStore {
    @discardableResult func createMeetingNote(event: CalendarEvent? = nil) -> UUID? {
        if let event, let existing = state.meetings.first(where: { $0.calendarEventID == event.id }) {
            meetingWorkspace.selectedID = existing.id; section = .meetings; return existing.id
        }
        let note = MeetingNote(title: String((event?.title ?? "Meeting notes").prefix(200)),
            meetingDate: event.flatMap { AssistantDates.calendarDate($0.start) } ?? Date(),
            calendarEventID: event?.id, joinLink: event?.joinLinks.first, calendarSeriesID: event?.seriesID)
        do {
            try commit { $0.meetings.insert(note, at: 0) }
            meetingWorkspace.selectedID = note.id; section = .meetings; return note.id
        } catch { fail(error); return nil }
    }

    @discardableResult func saveMeetingNote(_ id: UUID) -> Bool {
        guard let original = state.meetings.first(where: { $0.id == id }) else { return false }
        do {
            var next = try meetingWorkspace.draft(for: original).applying(to: original)
            if let project = next.projectID, !state.workProjects.contains(where: { $0.id == project }) { next.projectID = nil }
            try commit { snapshot in
                if let index = snapshot.meetings.firstIndex(where: { $0.id == id }) { snapshot.meetings[index] = next }
                snapshot.meetingCaptureRecoveries.removeAll { $0.noteID == id && next.transcript.contains($0.text) }
            }
            meetingWorkspace.saved(id); errorMessage = nil; return true
        } catch { fail(error); return false }
    }

    func deleteMeetingNote(_ id: UUID) {
        do {
            try commit { $0.meetings.removeAll { $0.id == id }; $0.meetingCaptureRecoveries.removeAll { $0.noteID == id } }
            if meetingWorkspace.summarizingID == id { cancelMeetingSummary() }
            if meetingCapture.noteID == id { meetingCapture.cancel() }
            if meetAttendance.noteID == id { meetAttendance.leave() }
            meetingWorkspace.deleted(id)
        }
        catch { fail(error) }
    }

    func chooseMeetingTranscript(_ id: UUID) {
        guard !meetingCapture.isActive, meetingWorkspace.pendingImport == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["txt", "md", "vtt", "srt"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true; panel.allowsMultipleSelection = false
        panel.message = "Choose a text, Markdown, WebVTT, or SubRip transcript up to 2 MB."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        meetingWorkspace.importTranscript(from: url, into: id)
    }

    @discardableResult func useImportedTranscript(append: Bool) -> Bool {
        guard let pending = meetingWorkspace.pendingImport,
              let note = state.meetings.first(where: { $0.id == pending.noteID }) else { return false }
        let previous = meetingWorkspace.draft(for: note).transcript
        let combined = append && !previous.isEmpty ? previous + "\n\n" + pending.result.text : pending.result.text
        guard combined.count <= TranscriptImport.maximumCharacters else {
            fail(PuddleError("The combined transcript exceeds 200,000 characters. Replace the transcript or import a smaller file.")); return false
        }
        meetingWorkspace.edit(note) { $0.transcript = combined }
        meetingWorkspace.pendingImport = nil; meetingWorkspace.selectedID = note.id
        return true
    }

    func resetMeetingWorkspace() {
        meetAttendance.leave()
        meetingCapture.cancel(); cancelMeetingSummary(); meetingWorkspace.reset()
    }

    func checkMeetBrowser() {
        guard !demo, storageAvailable, !privateSession, !isLocked, !state.settings.networkDisabled else { return }
        meetAttendance.checkBrowser()
    }

    func joinGoogleMeet(_ link: MeetingJoinLink, noteID: UUID?, guestName: String) {
        guard !privateSession, !isLocked, !state.settings.networkDisabled else { return }
        guard !demo, storageAvailable, link.provider == .googleMeet, !meetAttendance.isActive, !meetAttendance.mayStillBeInCall else { return }
        var selected = noteID
        if selected == nil {
            let note = MeetingNote(title: "Google Meet notes", joinLink: link)
            do { try commit { $0.meetings.insert(note, at: 0) }; selected = note.id; meetingWorkspace.selectedID = note.id; section = .meetings }
            catch { fail(error); return }
        }
        guard let selected, state.meetings.contains(where: { $0.id == selected }) else { return }
        if state.meetings.first(where: { $0.id == selected })?.joinLink == nil {
            do { try commit { snapshot in if let index = snapshot.meetings.firstIndex(where: { $0.id == selected }) { snapshot.meetings[index].joinLink = link } } }
            catch { fail(error); return }
        }
        meetAttendance.join(link: link, noteID: selected, guestName: guestName)
    }

    func startMeetingTranscription(_ id: UUID, source: MeetingAudioSource) {
        guard !state.meetingCaptureRecoveries.contains(where: { $0.noteID == id }) else {
            fail(PuddleError("Review and save or discard the recovered transcript before starting another capture.")); return
        }
        guard !demo, storageAvailable, state.meetings.contains(where: { $0.id == id }),
              !meetingCapture.isActive, meetingWorkspace.pendingImport == nil, !meetingWorkspace.isImporting else { return }
        stopSpeaking(); voiceInput.cancel(); cancelMeetingSummary()
        meetingCapture.start(noteID: id, language: state.settings.speechLanguage, source: source)
    }

    var canInstallMeetingSpeechLanguage: Bool {
        !demo && !isLocked && !privateSession && !state.settings.networkDisabled && meetingCapture.isSupported && !meetingCapture.isActive
    }

    func installMeetingSpeechLanguage() {
        guard canInstallMeetingSpeechLanguage else { return }
        meetingCapture.installLanguage(state.settings.speechLanguage)
    }

    func exportMeetingNote(_ id: UUID, format: MeetingExportFormat, includeTranscript: Bool, includeJoinLink: Bool) async throws -> Bool {
        let access = try workspaceAccess()
        guard let note = state.meetings.first(where: { $0.id == id }) else { throw PuddleError("These meeting notes are no longer available.") }
        let draft = meetingWorkspace.draft(for: note)
        let data = try MeetingExport.data(note: note, draft: draft, format: format, includeTranscript: includeTranscript, includeJoinLink: includeJoinLink)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.nameFieldStringValue = MeetingExport.filename(title: draft.title, format: format)
        panel.canCreateDirectories = true
        let response = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
        guard response == .OK, let url = panel.url else { return false }
        try checkWorkspaceAccess(access)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try await writeWorkspaceExport(to: url, access: access) { data }
        return true
    }

    func cancelMeetingSummary() {
        meetingSummaryGeneration = UUID(); meetingSummaryTask?.cancel(); meetingSummaryTask = nil
        meetingWorkspace.summarizingID = nil; meetingWorkspace.summaryProgress = ""
    }

    func updateMeetingSummaryProgress(generation: UUID, index: Int, total: Int) {
        guard meetingSummaryGeneration == generation else { return }
        meetingWorkspace.summaryProgress = "Extracting section \(index) of \(total)…"
    }

    func generateMeetingSummary(_ id: UUID) {
        guard let note = state.meetings.first(where: { $0.id == id }) else { return }
        guard !demo else { meetingWorkspace.summaryError = "Summary generation uses your local model outside Demo mode."; return }
        guard storageAvailable else { meetingWorkspace.summaryError = "Load saved state successfully before generating a summary."; return }
        guard !meetingWorkspace.isDirty(note) else { meetingWorkspace.summaryError = "Save your notes and transcript before generating a summary."; return }
        guard !(note.notes + note.transcript).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            meetingWorkspace.summaryError = "Add notes or a transcript before generating a summary."; return
        }
        cancelMeetingSummary(); meetingWorkspace.summaryError = nil
        let expected = meetingSummaryGeneration
        meetingWorkspace.summarizingID = id; meetingWorkspace.summaryProgress = "Connecting to local model…"
        meetingSummaryTask = Task { [weak self] in
            guard let self else { return }
            defer { if meetingSummaryGeneration == expected { meetingWorkspace.summarizingID = nil; meetingWorkspace.summaryProgress = ""; meetingSummaryTask = nil } }
            do {
                try Task.checkCancellation()
                let summarizer: any MeetingSummarizing
                if let suppliedMeetingSummarizer { summarizer = suppliedMeetingSummarizer }
                else { summarizer = LocalMeetingSummarizer(connection: try connection()) }
                var summary = try await summarizer.summarize(note: note, contextTokens: state.settings.contextTokens) { [weak self] index, total in
                    await self?.updateMeetingSummaryProgress(generation: expected, index: index, total: total)
                }
                try Task.checkCancellation()
                guard meetingSummaryGeneration == expected, let current = state.meetings.first(where: { $0.id == id }) else { return }
                let draft = meetingWorkspace.draft(for: current)
                guard summary.isCurrent(notes: draft.notes, transcript: draft.transcript) else {
                    throw PuddleError("The meeting text changed during generation. Save your changes and generate again; the previous summary was retained.")
                }
                for index in summary.actions.indices {
                    summary.actions[index].taskID = taskForMeetingAction(noteID: id, action: summary.actions[index])?.id
                }
                try commit { snapshot in
                    if let index = snapshot.meetings.firstIndex(where: { $0.id == id }) {
                        snapshot.meetings[index].summary = summary; snapshot.meetings[index].updatedAt = Date()
                    }
                }
            } catch is CancellationError {}
            catch { if meetingSummaryGeneration == expected { meetingWorkspace.summaryError = error.localizedDescription } }
        }
    }

    func taskForMeetingAction(noteID: UUID, action: MeetingAction) -> AssistantTask? {
        state.tasks.first { task in
            if let source = task.meetingSource, source.meetingID == noteID {
                return source.actionID == action.id || Self.normalizedMeetingQuote(source.quote) == Self.normalizedMeetingQuote(action.quote)
            }
            return task.id == action.taskID
        }
    }

    private static func normalizedMeetingQuote(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    @discardableResult func createTaskFromMeeting(noteID: UUID, actionID: UUID, title: String, dueAt: Date?, owner: String = "", workflow: TaskWorkflow = .active) -> UUID? {
        guard let note = state.meetings.first(where: { $0.id == noteID }), let summary = note.summary,
              let action = summary.actions.first(where: { $0.id == actionID }) else { return nil }
        if let existing = taskForMeetingAction(noteID: noteID, action: action) { return existing.id }
        let draft = meetingWorkspace.draft(for: note)
        guard summary.isCurrent(notes: draft.notes, transcript: draft.transcript) else {
            fail(PuddleError("The action came from an older version of the meeting text. Save and regenerate the summary before creating a task.")); return nil
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 300, dueAt.map({ $0.timeIntervalSinceReferenceDate.isFinite && $0 > Date() }) ?? true else {
            fail(PuddleError("Use a task title up to 300 characters and choose a future reminder time, or leave it undated.")); return nil
        }
        var task = AssistantTask(title: title, dueAt: dueAt)
        var commitment = TaskDraft(task); commitment.owner = owner; commitment.workflow = workflow
        do { task = try commitment.applying(to: task) } catch { fail(error); return nil }
        task.meetingSource = MeetingTaskSource(meetingID: noteID, actionID: actionID, quote: action.quote)
        guard let noteIndex = state.meetings.firstIndex(where: { $0.id == noteID }),
              let actionIndex = state.meetings[noteIndex].summary?.actions.firstIndex(where: { $0.id == actionID }) else { return nil }
        do {
            try commit { snapshot in
                snapshot.tasks.append(task)
                snapshot.meetings[noteIndex].summary?.actions[actionIndex].taskID = task.id
            }
            scheduleReminders(); errorMessage = nil; return task.id
        } catch { fail(error); return nil }
    }
}
