import AppKit
import Combine
import PuddleCore

@MainActor final class BrowserWorkspace: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var isBusy = false
    @Published private(set) var page: CuaBrowserPage?
    @Published private(set) var error: String?
    private let controller: any CuaBrowserControlling
    private var revision = UUID()
    private var cleanup: Task<Void, Never>?

    init(controller: any CuaBrowserControlling = CuaBrowser()) { self.controller = controller }

    static var defaultDriverPath: String {
        let paths = ["/Applications/CuaDriver.app/Contents/MacOS/cua-driver",
                     NSHomeDirectory() + "/.local/bin/cua-driver", "/opt/homebrew/bin/cua-driver", "/usr/local/bin/cua-driver"]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? paths[1]
    }

    func connect(path: String) async {
        guard !isBusy, !isConnected else { return }
        let expected = UUID(); revision = expected; isBusy = true; error = nil
        defer { if revision == expected { isBusy = false } }
        do {
            guard path.hasPrefix("/"), !path.contains("\n") else { throw PuddleError("Choose the installed cua-driver executable.") }
            await cleanup?.value
            guard revision == expected else { return }
            let result = try await controller.connect(executable: URL(fileURLWithPath: path))
            guard revision == expected else { return }
            page = result; isConnected = true
        } catch is CancellationError {
            if revision == expected { stop() }
        } catch { if revision == expected { self.error = error.localizedDescription } }
    }

    func observe(tabID: String = "", query: String = "") async throws -> CuaBrowserPage {
        try await perform { try await self.controller.observe(tabID: tabID, query: query) }
    }
    func act(_ action: CuaBrowserAction) async throws -> CuaBrowserPage {
        try await perform { try await self.controller.act(action) }
    }
    private func perform(_ work: () async throws -> CuaBrowserPage) async throws -> CuaBrowserPage {
        guard isConnected, !isBusy else { throw PuddleError("Start a browser session and wait for the current operation to finish.") }
        let expected = revision; isBusy = true; error = nil
        defer { if revision == expected { isBusy = false } }
        do {
            let result = try await work()
            try Task.checkCancellation()
            guard revision == expected else { throw CancellationError() }
            page = result; return result
        } catch is CancellationError {
            if revision == expected { stop() }
            throw CancellationError()
        } catch {
            if revision == expected { self.error = error.localizedDescription }
            throw error
        }
    }
    func stop() {
        revision = UUID(); isConnected = false; isBusy = false; page = nil; error = nil
        let controller = controller, previous = cleanup
        cleanup = Task { await previous?.value; await controller.disconnect() }
    }
    func showBrowser() {
        if let page { NSRunningApplication(processIdentifier: page.processID)?.activate() }
    }
}
