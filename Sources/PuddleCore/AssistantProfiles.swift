import Foundation

public enum AssistantProfileKind: String, Codable, CaseIterable, Sendable {
    case personal, developer, custom

    public var title: String {
        switch self {
        case .personal: "Personal"
        case .developer: "Developer"
        case .custom: "Custom"
        }
    }
    public var icon: String {
        switch self {
        case .personal: "person.crop.circle"
        case .developer: "chevron.left.forwardslash.chevron.right"
        case .custom: "slider.horizontal.3"
        }
    }
    public var summary: String {
        switch self {
        case .personal: "Everyday planning, writing, learning and follow-through."
        case .developer: "Project context, source inspection, debugging and focused work."
        case .custom: "Your own approach, with editable guidance and work context."
        }
    }
    public var guidance: String {
        switch self {
        case .personal:
            "Help with everyday planning, writing, learning and follow-through. Adapt to the user's needs without imposing a business or technical framing. Offer practical next steps."
        case .developer:
            "Act as a developer's assistant. Clarify expected behavior, errors, relevant code and constraints. Use available read-only project tools to ground repository claims and cite paths and line numbers. Keep evidence, hypotheses, decisions and proposed verification distinct. Help reason about debugging, design, tradeoffs, tests and delivery. Protect focused work when planning. Do not claim to have inspected a repository, run code or tests, or changed files without an available tool and successful receipt."
        case .custom:
            "Adapt to the user's saved role, objectives and additional guidance. Ask for missing context when it materially affects the answer."
        }
    }
    public var objectivesLabel: String {
        switch self {
        case .developer: "Current projects and technical goals"
        case .personal, .custom: "Current goals and priorities"
        }
    }
    public var planLabel: String { self == .developer ? "Plan my focus" : "Brief me on today" }
    public var planQuestion: String {
        let focus: String
        switch self {
        case .developer: focus = "Help me protect focused development time, identify blockers and plan the next concrete steps. Use saved developer context where relevant; project inspection is read-only and does not run checks."
        case .personal, .custom: focus = "Help me choose a practical plan aligned with my saved goals."
        }
        return "Read my daily brief and help me plan today. Start with my chosen priorities, overdue commitments, waiting-on follow-ups and calendar conflicts. State source freshness and limits. \(focus) Suggest next steps without inventing commitments or changing anything."
    }
    public var starters: [ProfileStarter] {
        switch self {
        case .developer:
            [ProfileStarter(title: "Debug an issue", icon: "ladybug", question: "Help me debug an issue. Ask for the error, relevant code, expected behavior and what I have tried. Use connected project tools for relevant evidence when available, otherwise ask me for source excerpts. Do not claim commands or tests ran."),
             ProfileStarter(title: "Explore a technical design", icon: "point.3.connected.trianglepath.dotted", question: "Help me evaluate a technical design. Ask about the requirements, current architecture and constraints, then compare practical options and meaningful ways to test them.")]
        case .personal, .custom:
            [ProfileStarter(title: "Think through an idea", icon: "lightbulb", question: "Help me think through a new project idea. Ask me a few useful questions."),
             ProfileStarter(title: "Make a plan", icon: "list.bullet.clipboard", question: planQuestion)]
        }
    }
}

public struct ProfileStarter: Identifiable, Sendable {
    public var id: String { title }
    public let title: String
    public let icon: String
    public let question: String
}

/// Retired prompt-only presets are accepted only when reading saved profiles.
private enum RetiredAssistantProfileKind: String {
    case cxo, productManager, researcher

    var title: String {
        switch self {
        case .cxo: "CXO"
        case .productManager: "Product Manager"
        case .researcher: "Researcher"
        }
    }
    var presetID: UUID {
        let number = switch self {
        case .cxo: 2
        case .productManager: 4
        case .researcher: 5
        }
        return UUID(uuidString: String(format: "54A8D675-2837-42F1-B7D0-%012d", number))!
    }
}

public struct AssistantProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var kind: AssistantProfileKind
    public var context: ExecutiveProfile
    public var additionalGuidance: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), kind: AssistantProfileKind = .custom, title: String? = nil, context: ExecutiveProfile = ExecutiveProfile(), additionalGuidance: String = "") {
        self.id = id; self.kind = kind; self.title = title ?? kind.title
        self.context = context; self.additionalGuidance = additionalGuidance
        createdAt = Date(); updatedAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, title, kind, context, additionalGuidance, createdAt, updatedAt }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try values.decode(String.self, forKey: .kind)
        guard let savedKind = AssistantProfileKind(rawValue: rawKind)
            ?? (RetiredAssistantProfileKind(rawValue: rawKind) != nil ? .custom : nil) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: values, debugDescription: "Unknown assistant profile approach.")
        }
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        kind = savedKind
        context = try values.decode(ExecutiveProfile.self, forKey: .context)
        additionalGuidance = try values.decode(String.self, forKey: .additionalGuidance)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }

    public func validated() throws -> Self {
        var copy = self
        copy.title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        copy.additionalGuidance = additionalGuidance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.title.isEmpty, copy.title.count <= 80, copy.additionalGuidance.count <= 4000 else {
            throw PuddleError("Give the profile a name of 1–80 characters and keep additional guidance under 4,000 characters.")
        }
        copy.context = try context.validated()
        return copy
    }
}

private struct SavedAssistantProfile: Decodable {
    let profile: AssistantProfile
    let isEmptyRetiredPreset: Bool

    private enum CodingKeys: String, CodingKey { case kind }
    init(from decoder: Decoder) throws {
        profile = try AssistantProfile(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let retired = RetiredAssistantProfileKind(rawValue: try values.decode(String.self, forKey: .kind))
        isEmptyRetiredPreset = retired?.presetID == profile.id && retired?.title == profile.title
            && profile.context == ExecutiveProfile() && profile.additionalGuidance.isEmpty
    }
}

/// Role profiles share the workspace. Only work context and approach change on selection.
public struct AssistantProfileLibrary: Codable, Equatable, Sendable {
    public static let maximumCount = 50
    public private(set) var profiles: [AssistantProfile]
    public private(set) var activeID: UUID
    public var active: AssistantProfile { profiles.first(where: { $0.id == activeID }) ?? profiles[0] }
    public var context: ExecutiveProfile {
        get { active.context }
        set {
            guard let index = profiles.firstIndex(where: { $0.id == activeID }) else { return }
            profiles[index].context = newValue; profiles[index].updatedAt = Date()
        }
    }

    public init(legacyContext: ExecutiveProfile = ExecutiveProfile()) {
        // Stable preset IDs make migration and repeated backup imports idempotent.
        let presets: [(kind: AssistantProfileKind, number: Int)] = [(.personal, 1), (.developer, 3)]
        profiles = presets.map { preset in
            AssistantProfile(id: UUID(uuidString: String(format: "54A8D675-2837-42F1-B7D0-%012d", preset.number))!, kind: preset.kind)
        }
        activeID = profiles[0].id
        context = legacyContext
    }

    private enum CodingKeys: String, CodingKey { case profiles, activeID }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let saved = try values.decode([SavedAssistantProfile].self, forKey: .profiles)
        profiles = saved.map(\.profile)
        activeID = try values.decode(UUID.self, forKey: .activeID)
        guard !profiles.isEmpty, profiles.count <= Self.maximumCount,
              Set(profiles.map(\.id)).count == profiles.count,
              Set(profiles.map { Self.identity($0.title) }).count == profiles.count,
              profiles.contains(where: { $0.id == activeID }) else {
            throw PuddleError("Saved profiles have an invalid selection, duplicate names or IDs, or an unsupported count.")
        }
        for profile in profiles { _ = try profile.validated() }
        profiles = saved.filter { !$0.isEmptyRetiredPreset }.map(\.profile)
        if profiles.isEmpty { profiles = AssistantProfileLibrary().profiles.filter { $0.kind == .personal } }
        if !profiles.contains(where: { $0.id == activeID }) {
            activeID = (profiles.first(where: { $0.kind == .personal }) ?? profiles[0]).id
        }
    }

    public mutating func add(_ profile: AssistantProfile, activate: Bool = true) throws {
        let next = try profile.validated()
        guard profiles.count < Self.maximumCount else { throw PuddleError("You can save up to \(Self.maximumCount) profiles. Remove an unused profile first.") }
        guard !profiles.contains(where: { $0.id == next.id }) else { throw PuddleError("This profile already exists.") }
        try checkTitle(next)
        profiles.append(next)
        if activate { activeID = next.id }
    }
    public mutating func update(_ profile: AssistantProfile) throws {
        var next = try profile.validated()
        guard let index = profiles.firstIndex(where: { $0.id == next.id }) else { throw PuddleError("This profile was removed. Your draft has been retained.") }
        try checkTitle(next)
        next.updatedAt = Date(); profiles[index] = next
    }
    public mutating func activate(_ id: UUID) throws {
        guard profiles.contains(where: { $0.id == id }) else { throw PuddleError("This profile is no longer available.") }
        activeID = id
    }
    public mutating func remove(_ id: UUID) throws {
        guard profiles.count > 1 else { throw PuddleError("Keep at least one assistant profile.") }
        guard id != activeID else { throw PuddleError("Switch to another profile before removing the active one.") }
        guard profiles.contains(where: { $0.id == id }) else { throw PuddleError("This profile is no longer available.") }
        profiles.removeAll { $0.id == id }
    }
    public func availableTitle(_ proposed: String) -> String {
        let base = String(proposed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(65))
        if !profiles.contains(where: { Self.identity($0.title) == Self.identity(base) }) { return base }
        for number in 2...Self.maximumCount + 1 {
            let title = "\(base) \(number)"
            if !profiles.contains(where: { Self.identity($0.title) == Self.identity(title) }) { return title }
        }
        return "\(base) copy"
    }
    private static func identity(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private func checkTitle(_ profile: AssistantProfile) throws {
        guard !profiles.contains(where: { $0.id != profile.id && Self.identity($0.title) == Self.identity(profile.title) }) else {
            throw PuddleError("A profile with this name already exists. Choose a different name.")
        }
    }
}
