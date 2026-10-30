import Foundation
import PuddleCore

struct ConnectedWorkSearch: Encodable {
    struct Source: Encodable {
        let service: WorkService
        let scope: String
        let fetchedAt: Date
        let items: [WorkItem]
        let text: String
        let hasMore: Bool
    }
    let sources: [Source]
    let errors: [String: String]
    let scope = "Fresh bounded excerpts. Up to three items per source in this assistant response; refine searches or read a locator for details. Errors and hasMore mean incomplete evidence."
    var references: [SourceReference] { sources.flatMap { $0.items.map { SourceReference(title: $0.title, url: $0.url) } } }
    var encoded: String {
        get throws { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return String(decoding: try encoder.encode(self), as: UTF8.self) }
    }
    init(results: [WorkReadResult], errors: [String: String]) {
        self.errors = errors
        sources = results.map { result in
            let items = result.items.prefix(3).map { WorkItem(service: $0.service, locator: $0.locator, title: String($0.title.prefix(180)), detail: String($0.detail.prefix(120)), excerpt: String($0.excerpt.prefix(200)), url: $0.url) }
            return Source(service: result.service, scope: result.scope, fetchedAt: result.fetchedAt, items: items,
                text: String(result.text.prefix(1000)), hasMore: result.hasMore || result.items.count > 3 || result.text.count > 1000)
        }
    }
}

extension PuddleStore {
    var connectedWorkServices: [WorkService] {
        guard !demo else { return [] }
        return (githubConnection == nil ? [] : [.github]) + (atlassianConnection?.selectedSite == nil ? [] : [.jira, .confluence].filter { atlassianConnection?.services.contains($0) == true })
    }
    func loadWorkConnections() async {
        guard !demo else { return }
        do { let info = try await githubConnector.info(); if !demo { githubConnection = info } }
        catch { if !demo { workConnectionErrors[.github] = error.localizedDescription } }
        do { let info = try await atlassianConnector.info(); if !demo { atlassianConnection = info } }
        catch { if !demo { workConnectionErrors[.jira] = error.localizedDescription; workConnectionErrors[.confluence] = error.localizedDescription } }
    }
    @discardableResult func connectGitHub(token: String, repositoryText: String) async -> Bool {
        guard !demo, !privateSession, !isLocked, !state.settings.networkDisabled, !isConnectingGitHub else { return false }
        do {
            let repositories = try GitHubConnector.parseRepositories(repositoryText)
            return await connectGitHub(token: token, repositories: repositories)
        }
        catch { workConnectionErrors[.github] = error.localizedDescription; return false }
    }
    @discardableResult func connectGitHub(token: String, repositories: [String]) async -> Bool {
        guard !demo, !privateSession, !isLocked, !state.settings.networkDisabled, !isConnectingGitHub else { return false }
        isConnectingGitHub = true; workConnectionErrors[.github] = nil
        defer { isConnectingGitHub = false }
        do {
            let info = try await githubConnector.connect(token: token, repositories: repositories)
            guard !demo, !privateSession, !isLocked else { return false }
            stopAI(); workSources.cancel(); githubConnection = info; return true
        } catch is CancellationError { return false }
        catch { if !demo { workConnectionErrors[.github] = error.localizedDescription }; return false }
    }
    func beginAtlassianSignIn(services: Set<WorkService>) {
        guard !demo, !privateSession, !isLocked, !state.settings.networkDisabled, !isConnectingAtlassian else { return }
        cancelAtlassianSignIn(); isConnectingAtlassian = true
        workConnectionErrors[.jira] = nil; workConnectionErrors[.confluence] = nil
        let receiver = WorkOAuthCallback(); workOAuthCallback = receiver
        let expected = workOAuthRevision
        workOAuthTask = Task {
            defer { receiver.close(); if workOAuthRevision == expected { isConnectingAtlassian = false; workAuthorizationStatus = ""; workOAuthCallback = nil } }
            do {
                workAuthorizationStatus = "Preparing secure browser sign-in…"
                let redirect = try await receiver.start()
                let attempt = try await atlassianConnector.prepare(redirect: redirect, services: services)
                try Task.checkCancellation(); guard workOAuthRevision == expected else { throw CancellationError() }
                workAuthorizationStatus = "Complete Atlassian consent in your browser…"
                let code = try await receiver.wait(for: attempt)
                try Task.checkCancellation(); workAuthorizationStatus = "Verifying site access and read/search tools…"
                let info = try await atlassianConnector.finish(attempt, code: code)
                guard workOAuthRevision == expected, !demo else { return }
                stopAI(); workSources.cancel(); atlassianConnection = info
            } catch is CancellationError {}
            catch { if workOAuthRevision == expected, !demo { for service in services { workConnectionErrors[service] = error.localizedDescription } } }
        }
    }
    func cancelAtlassianSignIn() {
        workOAuthRevision = UUID(); workOAuthTask?.cancel(); workOAuthTask = nil; workOAuthCallback?.cancel(); workOAuthCallback = nil
        isConnectingAtlassian = false; workAuthorizationStatus = ""
    }
    func chooseAtlassianSite(_ id: String?) async {
        guard !demo, !privateSession, !isLocked else { return }
        do {
            let info = try await atlassianConnector.selectSite(id)
            stopAI(); workSources.cancel(); atlassianConnection = info
        } catch { workConnectionErrors[.jira] = error.localizedDescription; workConnectionErrors[.confluence] = error.localizedDescription }
    }
    func testWorkConnection(_ service: WorkService) async {
        guard !demo, !privateSession, !isLocked, !state.settings.networkDisabled, !testingWorkConnections.contains(service) else { return }
        testingWorkConnections.insert(service); workConnectionErrors[service] = nil
        defer { testingWorkConnections.remove(service) }
        do {
            if service == .github { let info = try await githubConnector.test(); if !demo { githubConnection = info } }
            else { let info = try await atlassianConnector.test(); if !demo { atlassianConnection = info } }
        } catch { if !demo { workConnectionErrors[service] = error.localizedDescription } }
    }
    func disconnectWorkConnection(_ service: WorkService) async {
        guard !demo, !privateSession, !isLocked else { return }
        stopAI(); workSources.cancel()
        if service != .github { cancelAtlassianSignIn() }
        do {
            if service == .github { try await githubConnector.disconnect(); githubConnection = nil }
            else { try await atlassianConnector.disconnect(); atlassianConnection = nil; workConnectionErrors[.jira] = nil; workConnectionErrors[.confluence] = nil }
            workConnectionErrors[service] = nil
        } catch { workConnectionErrors[service] = error.localizedDescription }
    }
    func searchConnectedWork(_ query: String, service: String, syntax: String) async throws -> ConnectedWorkSearch {
        let selected = service == "all" ? connectedWorkServices : connectedWorkServices.filter { $0.rawValue == service }
        guard !selected.isEmpty, ["text", "native"].contains(syntax), query.count <= 2000,
              syntax != "native" || (selected.count == 1 && selected[0] != .github) else { throw PuddleError("Choose a connected source. Native syntax is only available for one Jira (JQL) or Confluence (CQL) source.") }
        var results: [WorkReadResult] = [], errors: [String: String] = [:]
        let github = githubConnector, atlassian = atlassianConnector
        await withTaskGroup(of: (WorkService, WorkReadResult?, String?).self) { group in
            for provider in selected { group.addTask {
                do { return (provider, provider == .github ? try await github.search(query) : try await atlassian.search(query, service: provider, nativeQuery: syntax == "native"), nil) }
                catch is CancellationError { return (provider, nil, nil) }
                catch { return (provider, nil, error.localizedDescription) }
            } }
            for await (provider, result, error) in group {
                if let result { results.append(result) }
                if let error { errors[provider.rawValue] = error }
            }
        }
        try Task.checkCancellation()
        guard !results.isEmpty else { throw PuddleError("Connected work search failed. " + errors.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: " ")) }
        return ConnectedWorkSearch(results: results.sorted { $0.service.rawValue < $1.service.rawValue }, errors: errors)
    }
    func readConnectedWork(service: String, locator: String, view: String) async throws -> WorkReadResult {
        guard let provider = WorkService(rawValue: service), connectedWorkServices.contains(provider) else { throw PuddleError("Connect this source in Connections first.") }
        if provider == .github {
            let pieces = locator.split(separator: "#")
            guard pieces.count == 2, let number = Int(pieces[1]) else { throw PuddleError("Use a GitHub locator such as owner/repository#123 from search results.") }
            return try await githubConnector.read(repository: String(pieces[0]), number: number, view: view)
        }
        guard view == "details" else { throw PuddleError("Jira and Confluence support the details view.") }
        return try await atlassianConnector.read(locator, service: provider)
    }
}
