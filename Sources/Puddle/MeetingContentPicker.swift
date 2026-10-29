import Foundation
import PuddleCore
@preconcurrency import ScreenCaptureKit

/// The OS scopes access to a single application selected by the user.
@available(macOS 26, *)
@MainActor final class MeetingContentPicker: NSObject, SCContentSharingPickerObserver {
    private var pending: CheckedContinuation<SCContentFilter, Error>?
    private var observing = false
    func select() async throws -> SCContentFilter {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                var configuration = SCContentSharingPickerConfiguration()
                configuration.allowedPickerModes = [.singleApplication]
                configuration.allowsChangingSelectedContent = false
                configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier].compactMap { $0 }
                let picker = SCContentSharingPicker.shared
                picker.defaultConfiguration = configuration; picker.add(self); observing = true
                picker.isActive = true; picker.present()
            }
        } onCancel: { [weak self] in Task { @MainActor in self?.cancel() } }
    }
    func cancel() {
        let continuation = pending; pending = nil
        if observing {
            SCContentSharingPicker.shared.remove(self); SCContentSharingPicker.shared.isActive = false; observing = false
        }
        continuation?.resume(throwing: CancellationError())
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in self?.cancel() }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in
            guard let self, let continuation = self.pending else { return }
            self.pending = nil; continuation.resume(returning: filter)
        }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, let continuation = self.pending else { return }
            self.pending = nil; self.cancel()
            continuation.resume(throwing: PuddleError("The meeting-app picker could not open: \(message)"))
        }
    }
}
