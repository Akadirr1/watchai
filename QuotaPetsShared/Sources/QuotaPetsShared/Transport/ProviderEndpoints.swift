import Foundation

/// Every provider-specific constant lives here and nowhere else.
///
/// The brief (§2) is explicit that the version-bearing strings must be isolated rather
/// than scattered, and it is right: `anthropic-beta` and both User-Agents are dated
/// values that will rot. When a provider changes, this file is the only edit.
///
/// Every hostname reachable by QuotaPets is listed here, satisfying §28's requirement to
/// document each external host:
///   - api.anthropic.com  (Claude usage)
///   - chatgpt.com        (Codex usage)
public enum ClaudeEndpoint {
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let betaHeader = "oauth-2025-04-20"
    public static let userAgent = "claude-code/2.1.0"
    public static let timeout: TimeInterval = 10

    public static func headers(accessToken: String) -> [String: String] {
        [
            "Authorization": "Bearer \(accessToken)",
            "anthropic-beta": betaHeader,
            "User-Agent": userAgent,
        ]
    }
}

public enum CodexEndpoint {
    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    public static let userAgent = "codex-cli"
    public static let betaHeader = "codex-1"
    public static let originator = "Codex Desktop"
    public static let timeout: TimeInterval = 10

    public static func headers(accessToken: String, accountID: String?) -> [String: String] {
        var h = [
            "Authorization": "Bearer \(accessToken)",
            "User-Agent": userAgent,
            "OpenAI-Beta": betaHeader,
            "originator": originator,
        ]
        // Orca sends this only when the auth file carried one.
        if let accountID, !accountID.isEmpty {
            h["ChatGPT-Account-Id"] = accountID
        }
        return h
    }
}
