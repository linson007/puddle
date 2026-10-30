import SwiftUI
import ServiceManagement

struct StartupSettingsView: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var message: String?
    var body: some View {
        Section("Availability") {
            Toggle("Open Puddle at login", isOn: Binding(get: { enabled }, set: { value in
                do {
                    if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    enabled = SMAppService.mainApp.status == .enabled
                    message = SMAppService.mainApp.status == .requiresApproval ? "Approve Puddle in macOS Login Items to finish setup." : nil
                } catch { message = error.localizedDescription }
            }))
            Text("The menu bar keeps routines available when the main window closes. After Quit, work resumes on the next launch; Puddle does not claim to execute while its process is stopped.").font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if SMAppService.mainApp.status == .requiresApproval { Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() } }
        }
    }
}
