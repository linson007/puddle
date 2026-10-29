import SwiftUI

struct TranscriptImportSheet: View {
    @ObservedObject var store: PuddleStore
    let pending: PendingTranscriptImport
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Import transcript").font(.title2)
            Text(pending.result.sourceName).font(.headline)
            Text("\(pending.result.format.title) · \(pending.result.text.count) characters\(pending.result.cueCount > 0 ? " · \(pending.result.cueCount) cues" : "")")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(String(pending.result.text.prefix(4000))).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 240).padding(12).background(PuddleStyle.background, in: RoundedRectangle(cornerRadius: 10))
            Text("Preview shows the first 4,000 characters. Import keeps the complete bounded text in your draft; save notes to keep it across restarts.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { store.meetingWorkspace.pendingImport = nil }
                Spacer()
                Button("Append") { store.useImportedTranscript(append: true) }
                Button("Replace transcript") { store.useImportedTranscript(append: false) }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 620)
    }
}
