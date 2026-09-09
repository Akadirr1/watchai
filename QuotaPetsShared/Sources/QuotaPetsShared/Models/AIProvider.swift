import Foundation

/// The two providers QuotaPets tracks. Deliberately closed: the brief (§1) rules out
/// Gemini, Antigravity and everything else, and a closed enum keeps exhaustive
/// `switch`es honest at every call site.
public enum AIProvider: String, Codable, Sendable, CaseIterable, Hashable {
    case claude
    case codex

    /// Display name for UI. Kept here rather than in a View so the Watch, phone and
    /// widget cannot drift apart.
    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}
