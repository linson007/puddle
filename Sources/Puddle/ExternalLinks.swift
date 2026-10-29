import AppKit
import Foundation

@MainActor protocol ExternalURLOpening: AnyObject { func open(_ url: URL) -> Bool }
@MainActor final class WorkspaceURLOpener: ExternalURLOpening {
    func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
}
