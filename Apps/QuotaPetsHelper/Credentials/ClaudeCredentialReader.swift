import Foundation
import Security
import QuotaPetsShared

/// Reads the Claude credential the user's own `claude` CLI already wrote.
///
/// Ported from Orca `src/main/rate-limits/claude-oauth-credentials.ts:135-148`: Keychain
/// first, then `~/.claude/.credentials.json`. QuotaPets performs no login of its own —
/// see docs/provider-research.md §4.3 for why.
///
/// This type never logs a token and never returns one to any caller outside this
/// process (§28).
struct ClaudeCredentialReader: CredentialSupplier {
    /// The service name the Claude CLI stores under. Isolated here because it is exactly
    /// the kind of value that changes between CLI versions.
    static let keychainService = "Claude Code-credentials"

    var configDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent(".claude")

    private struct CredentialsFile: Decodable {
        struct OAuth: Decodable {
            let accessToken: String?
            let refreshToken: String?
            let expiresAt: Double?
        }
        let claudeAiOauth: OAuth?
    }

    func accessToken() async throws -> String {
        if let token = readKeychain() ?? readFile() { return token }
        throw ProviderError.notAuthenticated
    }

    private func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return parse(data)
    }

    private func readFile() -> String? {
        let url = configDirectory.appendingPathComponent(".credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    private func parse(_ data: Data) -> String? {
        guard let file = try? JSONDecoder().decode(CredentialsFile.self, from: data),
              let token = file.claudeAiOauth?.accessToken, !token.isEmpty else { return nil }
        // Orca's note at claude-oauth-credentials.ts:47 is worth preserving: expiresAt is
        // NOT authoritative for the usage endpoint. Firing the request and reacting to a
        // 401 avoids a spurious "expired" state caused by local clock skew.
        return token
    }
}
