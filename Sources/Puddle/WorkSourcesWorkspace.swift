import Combine
import Foundation
import PuddleCore

@MainActor final class WorkSourcesWorkspace: ObservableObject {
    @Published private(set) var results: [WorkReadResult] = []
    @Published private(set) var errors: [WorkService: String] = [:]
    @Published private(set) var isSearching = false
    @Published private(set) var currentQuery = ""
    @Published private(set) var detail: WorkReadResult?
    @Published private(set) var isReading = false
    private var task: Task<Void, Never>?
    private var reading: Task<Void, Never>?
    private var revision = UUID()
    private var readRevision = UUID()
    func search(query: String, services: [WorkService], github: GitHubConnector, atlassian: AtlassianConnector) {
        cancel(); currentQuery = query; isSearching = true; let expected = revision
        task = Task {
            await withTaskGroup(of: (WorkService, WorkReadResult?, String?).self) { group in
                for service in services { group.addTask {
                    do {
                        let result = service == .github ? try await github.search(query) : try await atlassian.search(query, service: service)
                        return (service, result, nil)
                    } catch is CancellationError { return (service, nil, nil) }
                    catch { return (service, nil, error.localizedDescription) }
                } }
                for await (service, result, error) in group {
                    guard revision == expected, !Task.isCancelled else { group.cancelAll(); continue }
                    if let result { results.append(result); results.sort { $0.service.rawValue < $1.service.rawValue } }
                    if let error { errors[service] = error }
                }
            }
            if revision == expected { isSearching = false }
        }
    }
    func read(_ item: WorkItem, view: String = "details", github: GitHubConnector, atlassian: AtlassianConnector) {
        reading?.cancel(); readRevision = UUID(); let expectedRead = readRevision
        isReading = true; detail = nil; errors[item.service] = nil; let expected = revision
        reading = Task {
            do {
                let result: WorkReadResult
                if item.service == .github {
                    let pieces = item.locator.split(separator: "#")
                    guard pieces.count == 2, let number = Int(pieces[1]) else { throw PuddleError("Invalid GitHub item locator.") }
                    result = try await github.read(repository: String(pieces[0]), number: number, view: view)
                } else { result = try await atlassian.read(item.locator, service: item.service) }
                try Task.checkCancellation(); guard expected == revision, expectedRead == readRevision else { return }
                detail = result; isReading = false
            } catch is CancellationError { if expected == revision, expectedRead == readRevision { isReading = false } }
            catch { if expected == revision, expectedRead == readRevision { errors[item.service] = error.localizedDescription; isReading = false } }
        }
    }
    func clearDetail() { readRevision = UUID(); reading?.cancel(); isReading = false; detail = nil }
    func cancel() { revision = UUID(); task?.cancel(); reading?.cancel(); isSearching = false; isReading = false; results = []; errors = [:]; detail = nil }
}
