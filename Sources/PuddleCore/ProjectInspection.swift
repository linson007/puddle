import Foundation

public enum ProjectInspectionRequest: Sendable {
    case files(String), read(String, Int), search(String), status, diff(String, Bool)
}
public enum ProjectInspectionResult: Sendable {
    case files(ProjectFileList), excerpt(ProjectFileExcerpt), search(ProjectSearchResult), status(ProjectGitStatus), diff(ProjectGitDiff)
    public var text: String {
        func json<T: Encodable>(_ value: T) -> String {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            return String(decoding: (try? encoder.encode(value)) ?? Data("{}".utf8), as: UTF8.self)
        }
        switch self {
        case .files(let value): return json(value)
        case .excerpt(let value): return json(value)
        case .search(let value): return json(value)
        case .status(let value): return json(value)
        case .diff(let value): return json(value)
        }
    }
}
public enum ProjectInspection {
    public static func run(_ request: ProjectInspectionRequest, project: DeveloperProject) async throws -> ProjectInspectionResult {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let files = try ProjectFiles(project: project)
            switch request {
            case .files(let query): return ProjectInspectionResult.files(try files.inventory(matching: query))
            case .read(let path, let line): return .excerpt(try files.read(path, startLine: line))
            case .search(let query): return .search(try files.search(query))
            case .status: return .status(try await ProjectGit.status(files))
            case .diff(let path, let staged): return .diff(try await ProjectGit.diff(files, path: path, staged: staged))
            }
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
