import SwiftUI
import PuddleCore

struct MeetingCaptureView: View {
    @ObservedObject var store: PuddleStore
    @ObservedObject var capture: MeetingCaptureController
    let note: MeetingNote
    @State private var source = MeetingAudioSource.microphone
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live transcription").font(.headline)
            if capture.isActive, capture.noteID == note.id {
                Label(capture.status == .listening ? "Audio capture active" : capture.message, systemImage: "waveform.circle.fill")
                    .foregroundStyle(capture.status == .listening ? .red : .secondary)
                if let start = capture.startedAt {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text("Elapsed \(MeetingTranscriptTimeline.timestamp(context.date.timeIntervalSince(start)))").font(.caption.monospacedDigit())
                    }
                }
                if !capture.timeline.segments.isEmpty {
                    Text(String(capture.timeline.text.suffix(2000))).font(.callout).textSelection(.enabled)
                }
                Button(capture.status == .preparing ? "Cancel start" : "Stop and review") { capture.stop() }.disabled(capture.status == .finishing)
            } else {
                HStack {
                    Picker("Capture", selection: $source) { ForEach(MeetingAudioSource.allCases) { Text($0.title).tag($0) } }
                    Button("Start transcription") { store.startMeetingTranscription(note.id, source: source) }.buttonStyle(.borderedProminent)
                        .disabled(store.demo || !store.storageAvailable || !capture.isSupported || capture.isActive || store.meetingWorkspace.pendingImport != nil || store.meetingWorkspace.isImporting)
                }
                HStack {
                    Button("Install speech language…") { store.installMeetingSpeechLanguage() }.disabled(store.demo || !capture.isSupported || capture.isActive)
                    if capture.status == .installingLanguage {
                        ProgressView().controlSize(.small); Button("Cancel download") { capture.cancel() }
                    }
                }
                if !capture.message.isEmpty { Text(capture.message).font(.caption).foregroundStyle(.secondary) }
            }
            if let error = capture.errorMessage { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            Text("Requires macOS 26+ and an installed speech language (\(store.state.settings.speechLanguage)). Speech stays on this Mac; raw audio is not saved. Tell participants before transcribing. Stop to review, apply the transcript, then Save.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Meeting app audio uses the macOS sharing picker. Select only the meeting app; browser selection can include audio from its other tabs. Channels identify audio sources, not individual speakers. Headphones reduce duplicate speech from the microphone.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16).background(PuddleStyle.background, in: RoundedRectangle(cornerRadius: 10))
            .onDisappear { if capture.noteID == note.id { capture.stop() } }
    }
}
