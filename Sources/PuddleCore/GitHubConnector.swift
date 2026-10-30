import Foundation

public actor GitHubConnector {
    private struct Credentials: Codable { let token: String; let login: String; let repositories: [String]; let verifiedAt: Date }
    private let secrets: any SecretStore
    private let transport: any HTTPTransport
    private let key = "github-connector-v1"
    private var revision = UUID()
    public init(secrets: any SecretStore = KeychainStore(), transport: any HTTPTransport = URLSessionTransport()) { self.secrets = secrets; self.transport = transport }
    private func credentials() throws -> Credentials? { try secrets.read(key).map { try JSONDecoder().decode(Credentials.self, from: $0) } }
    public func info() throws -> GitHubConnectionInfo? { try credentials().map { GitHubConnectionInfo(login: $0.login, repositories: $0.repositories, verifiedAt: $0.verifiedAt) } }
    public static func repository(_ value: String) -> Bool {
        guard let match = value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}/[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression),
              match == value.startIndex..<value.endIndex else { return false }
        return !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
    /// Parse form input without using a pasted URL as an API destination.
    public static func parseRepositories(_ input: String) throws -> [String] {
        let entries = input.split(whereSeparator: { $0.isWhitespace || $0 == "," })
        guard !entries.isEmpty else { throw PuddleError("Add at least one repository, such as owner/repository or https://github.com/owner/repository.") }
        var repositories = Set<String>()
        for (index, entry) in entries.enumerated() {
            guard let repository = normalizedRepository(String(entry)) else {
                // Do not echo pasted input: URLs can contain credentials or private query values.
                throw PuddleError("Repository entry \(index + 1) is invalid. Enter owner/repository or a repository URL on github.com, such as https://github.com/owner/repository. Use the repository's main URL, without an issue, branch or file path.")
            }
            repositories.insert(repository)
        }
        guard repositories.count <= 10 else { throw PuddleError("Choose up to 10 different repositories. Remove extra entries and try again.") }
        return repositories.sorted()
    }
    private static func normalizedRepository(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if repository(value) { return value.lowercased() }
        let urlText = value.lowercased().hasPrefix("github.com/") || value.lowercased().hasPrefix("www.github.com/") ? "https://" + value : value
        guard let url = URLComponents(string: urlText), url.scheme?.lowercased() == "https",
              ["github.com", "www.github.com"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              url.path.hasPrefix("/") else { return nil }
        var path = String(url.path.dropFirst())
        if path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard repository(path) else { return nil }
        return path.lowercased()
    }
    private func request(_ path: String, token: String, query: [URLQueryItem] = []) async throws -> (ConnectorJSON, HTTPURLResponse) {
        var url = URLComponents(string: "https://api.github.com" + path)!
        if !query.isEmpty { url.queryItems = query }
        var request = URLRequest(url: url.url!, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Puddle-local-assistant", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await WorkConnectorHTTP.send(request, transport: transport, service: "GitHub", hosts: ["api.github.com"])
        return (try WorkConnectorHTTP.decode(data), response)
    }
    public func connect(token: String, repositories: [String]) async throws -> GitHubConnectionInfo {
        let expected = revision
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw PuddleError("Paste a GitHub personal access token in the token field.") }
        guard WorkConnectorHTTP.credential(token) else { throw PuddleError("Paste only the GitHub token value, without spaces, line breaks or an Authorization header.") }
        let repositories = try Self.parseRepositories(repositories.joined(separator: "\n"))
        let (user, _) = try await request("/user", token: token)
        guard let login = user["login"]?.string, !login.isEmpty else { throw PuddleError("GitHub did not identify the account.") }
        for repository in repositories {
            let base = "/repos/" + repository
            _ = try await request(base, token: token)
            // Metadata access alone does not establish that a fine-grained token can read work.
            for collection in ["issues", "pulls"] {
                let (body, _) = try await request(base + "/" + collection, token: token, query: [URLQueryItem(name: "per_page", value: "1"), URLQueryItem(name: "state", value: "all")])
                guard body.array != nil else { throw PuddleError("GitHub did not verify issue and pull request access. Check the token's read permissions.") }
            }
        }
        guard revision == expected else { throw CancellationError() }
        let value = Credentials(token: token, login: login, repositories: repositories, verifiedAt: Date())
        try secrets.write(JSONEncoder().encode(value), key: key); revision = UUID()
        return GitHubConnectionInfo(login: login, repositories: repositories, verifiedAt: value.verifiedAt)
    }
    public func disconnect() throws { try secrets.delete(key); revision = UUID() }
    public func test() async throws -> GitHubConnectionInfo {
        guard let value = try credentials() else { throw PuddleError("Connect GitHub first.") }
        return try await connect(token: value.token, repositories: value.repositories)
    }
    private func source(repository: String, number: Int, pull: Bool) -> URL { URL(string: "https://github.com/\(repository)/\(pull ? "pull" : "issues")/\(number)")! }
    public func search(_ query: String, kind: String = "all") async throws -> WorkReadResult {
        guard let value = try credentials() else { throw PuddleError("Connect GitHub in Connections first.") }
        guard query.count <= 300, ["all", "issues", "pull_requests"].contains(kind) else { throw PuddleError("Use a search phrase up to 300 characters and a supported item type.") }
        let expected = revision
        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let scope = value.repositories.map { "repo:\($0)" }.joined(separator: " ")
        let q = (phrase.isEmpty ? "is:open" : "\"\(phrase)\"") + " " + scope + (kind == "issues" ? " is:issue" : kind == "pull_requests" ? " is:pr" : "")
        let (body, _) = try await request("/search/issues", token: value.token, query: [URLQueryItem(name: "q", value: q), URLQueryItem(name: "per_page", value: "10"), URLQueryItem(name: "sort", value: "updated")])
        guard revision == expected else { throw CancellationError() }
        guard let rows = body["items"]?.array else { throw PuddleError("GitHub returned an unsupported search response.") }
        let allowed = Set(value.repositories)
        let items: [WorkItem] = rows.compactMap { row in
            guard let repositoryURL = row["repository_url"]?.string, let url = URL(string: repositoryURL), url.host == "api.github.com", url.path.hasPrefix("/repos/") else { return nil }
            let repository = String(url.path.dropFirst(7)).lowercased()
            guard allowed.contains(repository), let number = row["number"]?.number, number > 0, number <= Double(Int32.max), number.rounded() == number, let title = row["title"]?.string else { return nil }
            let pull = row["pull_request"] != nil
            return WorkItem(service: .github, locator: "\(repository)#\(Int(number))", title: title,
                detail: "\(repository) · \(pull ? "PR" : "Issue") #\(Int(number)) · \(row["state"]?.string ?? "")",
                excerpt: row["body"]?.string ?? "", url: source(repository: repository, number: Int(number), pull: pull))
        }
        return WorkReadResult(service: .github, title: "GitHub search", items: items,
            hasMore: body["incomplete_results"]?.bool == true || (body["total_count"]?.number ?? 0) > Double(items.count) || rows.count != items.count,
            scope: "First 10 matches in your configured repositories only. Query is a literal phrase; empty searches open work. Results are not a complete repository review.")
    }
    public func read(repository: String, number: Int, view: String) async throws -> WorkReadResult {
        guard let value = try credentials() else { throw PuddleError("Connect GitHub first.") }
        let repository = repository.lowercased(), expected = revision
        guard Self.repository(repository), value.repositories.contains(repository), (1...Int(Int32.max)).contains(number), ["details", "diff", "checks"].contains(view) else {
            throw PuddleError("Choose an issue or PR in a configured repository, with details, diff or checks view.")
        }
        let base = "/repos/\(repository)", (issue, _) = try await request(base + "/issues/\(number)", token: value.token)
        let pull = issue["pull_request"] != nil, title = issue["title"]?.string ?? "\(repository)#\(number)"
        let url = source(repository: repository, number: number, pull: pull)
        let text: String, more: Bool, scope: String
        if view == "details" {
            let (comments, response) = try await request(base + "/issues/\(number)/comments", token: value.token, query: [URLQueryItem(name: "per_page", value: "5")])
            let replies = comments.array ?? []
            text = "\(title)\nState: \(issue["state"]?.string ?? "unknown")\nUpdated: \(issue["updated_at"]?.string ?? "unknown")\n\n" + String((issue["body"]?.string ?? "No description.").prefix(9000)) + "\n\nFirst comments:\n" + replies.map { "\($0["user"]?["login"]?.string ?? "User"): \(String(($0["body"]?.string ?? "").prefix(1000)))" }.joined(separator: "\n\n")
            more = (issue["comments"]?.number ?? 0) > Double(replies.count) || response.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") == true || (issue["body"]?.string?.count ?? 0) > 9000 || replies.contains { ($0["body"]?.string?.count ?? 0) > 1000 }
            scope = "Description plus up to five earliest comments. Bodies may be shortened; later comments are not included. Read only."
        } else {
            guard pull else { throw PuddleError("Diff and checks views require a pull request.") }
            if view == "diff" {
                let (files, response) = try await request(base + "/pulls/\(number)/files", token: value.token, query: [URLQueryItem(name: "per_page", value: "20")])
                let rows = files.array ?? []
                text = rows.map { "\($0["filename"]?.string ?? "File") · \($0["status"]?.string ?? "")\n" + String(($0["patch"]?.string ?? "[No text patch provided; binary or large changes may be omitted]").prefix(1500)) }.joined(separator: "\n\n")
                more = response.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") == true || rows.contains { $0["patch"]?.string == nil || ($0["patch"]?.string?.count ?? 0) > 1500 }
                scope = "First 20 changed files and bounded GitHub-provided patch excerpts; omissions are possible. No code or tests executed."
            } else {
                let (pr, _) = try await request(base + "/pulls/\(number)", token: value.token)
                guard let sha = pr["head"]?["sha"]?.string, sha.range(of: #"^[a-fA-F0-9]{40,64}$"#, options: .regularExpression) != nil else { throw PuddleError("GitHub did not return the PR head commit.") }
                let (checks, response) = try await request(base + "/commits/\(sha)/check-runs", token: value.token, query: [URLQueryItem(name: "per_page", value: "20")])
                text = checks.text; more = (checks["total_count"]?.number ?? 0) > 20 || response.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") == true
                scope = "Reported check runs for the PR head commit, up to 20; legacy commit statuses may not be represented. Puddle did not run these checks."
            }
        }
        guard revision == expected else { throw CancellationError() }
        return WorkReadResult(service: .github, title: title, text: text, hasMore: more, scope: scope, references: [SourceReference(title: title, url: url)])
    }
}
