import Foundation

/// Everything rule matching can see about a window. Collected by the platform
/// layer from NSRunningApplication + Accessibility.
public struct WindowFacts: Equatable, Sendable {
    public var bundleID: String?
    public var appName: String?
    public var title: String?
    public var role: String?
    public var subrole: String?

    public init(bundleID: String? = nil, appName: String? = nil, title: String? = nil,
                role: String? = nil, subrole: String? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.role = role
        self.subrole = subrole
    }

    /// Standard document windows tile by default; dialogs, panels, sheets float.
    public var isStandardWindow: Bool {
        (role == nil || role == "AXWindow") && (subrole == nil || subrole == "AXStandardWindow")
    }
}

/// Compiled title regex. Reference type so rules stay cheap to copy.
public final class TitlePattern: Equatable, @unchecked Sendable {
    public let source: String
    let regex: NSRegularExpression

    public init(_ source: String) throws {
        self.source = source
        self.regex = try NSRegularExpression(pattern: source)
    }

    func matches(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func == (a: TitlePattern, b: TitlePattern) -> Bool { a.source == b.source }
}

public struct RuleMatch: Equatable, Sendable {
    public var appID: String?
    public var appName: String?
    public var titleRegex: TitlePattern?
    public var titleSubstring: String?
    public var axRole: String?
    public var axSubrole: String?

    public init(appID: String? = nil, appName: String? = nil, titleRegex: TitlePattern? = nil,
                titleSubstring: String? = nil, axRole: String? = nil, axSubrole: String? = nil) {
        self.appID = appID
        self.appName = appName
        self.titleRegex = titleRegex
        self.titleSubstring = titleSubstring
        self.axRole = axRole
        self.axSubrole = axSubrole
    }

    /// Number of non-empty match fields: the rule's specificity.
    public var specificity: Int {
        [appID != nil, appName != nil, titleRegex != nil, titleSubstring != nil, axRole != nil, axSubrole != nil]
            .filter { $0 }.count
    }

    public func matches(_ facts: WindowFacts) -> Bool {
        if let appID, facts.bundleID != appID { return false }
        if let appName {
            guard let name = facts.appName, name.range(of: appName, options: .caseInsensitive) != nil else { return false }
        }
        if let titleRegex {
            guard let title = facts.title, titleRegex.matches(title) else { return false }
        }
        if let titleSubstring {
            guard let title = facts.title, title.range(of: titleSubstring, options: .caseInsensitive) != nil else { return false }
        }
        if let axRole, facts.role != axRole { return false }
        if let axSubrole, facts.subrole != axSubrole { return false }
        return true
    }
}

public enum Placement: Equatable, Sendable {
    case center
    case mouse
    /// Display-fraction units (0...1) relative to the display's visible frame.
    case rect(x: Double, y: Double, w: Double, h: Double)
}

public enum SelfMovePolicy: String, Equatable, Sendable {
    case snapBack = "snap_back"
    case adopt
}

public struct RuleActions: Equatable, Sendable {
    public var weight: Double?
    public var manage: Bool?
    public var float: Bool?
    public var placement: Placement?
    /// Display-fraction size for floating windows.
    public var size: CGSize?
    public var sticky: Bool?
    public var onSelfMove: SelfMovePolicy?

    public init(weight: Double? = nil, manage: Bool? = nil, float: Bool? = nil, placement: Placement? = nil,
                size: CGSize? = nil, sticky: Bool? = nil, onSelfMove: SelfMovePolicy? = nil) {
        self.weight = weight
        self.manage = manage
        self.float = float
        self.placement = placement
        self.size = size
        self.sticky = sticky
        self.onSelfMove = onSelfMove
    }
}

public struct AppRule: Equatable, Sendable {
    public var match: RuleMatch
    public var actions: RuleActions

    public init(match: RuleMatch, actions: RuleActions) {
        self.match = match
        self.actions = actions
    }
}

/// Effective per-window policy after rule resolution.
public struct ResolvedRule: Equatable, Sendable {
    public var weight: Double = 1.0
    public var manage: Bool = true
    public var float: Bool = false
    public var placement: Placement?
    public var size: CGSize?
    public var sticky: Bool = false
    public var onSelfMove: SelfMovePolicy = .snapBack
    /// Index of the winning rule in file order, if any.
    public var ruleIndex: Int?

    public init() {}
}

public enum RuleResolver {
    /// Most-specific matching rule wins (most non-empty match fields); ties go
    /// to the earliest rule in file order. Unmatched windows get defaults
    /// (weight 1, managed, tiled iff a standard window).
    public static func resolve(_ facts: WindowFacts, rules: [AppRule]) -> ResolvedRule {
        var best: (index: Int, specificity: Int)?
        for (index, rule) in rules.enumerated() where rule.match.matches(facts) {
            let specificity = rule.match.specificity
            if best == nil || specificity > (best?.specificity ?? 0) {
                best = (index, specificity)
            }
        }
        var resolved = ResolvedRule()
        resolved.float = !facts.isStandardWindow
        guard let best, rules.indices.contains(best.index) else { return resolved }
        let actions = rules[best.index].actions
        resolved.ruleIndex = best.index
        if let weight = actions.weight { resolved.weight = weight }
        if let manage = actions.manage { resolved.manage = manage }
        if let float = actions.float { resolved.float = float }
        resolved.placement = actions.placement
        resolved.size = actions.size
        if let sticky = actions.sticky { resolved.sticky = sticky }
        if let policy = actions.onSelfMove { resolved.onSelfMove = policy }
        return resolved
    }
}
