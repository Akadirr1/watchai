import Foundation
import QuotaPetsShared

/// Reads `<CODEX_HOME|~/.codex>/auth.json`, written by the user's own `codex` CLI.
/// Ported from Orca `src/main/rate-limits/codex-backend-auth.ts:70-96`.
struct CodexCredentialReader: CredentialSupplier {
    var home: URL = {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }()

    private struct AuthFile: Decodable {
        struct Tokens: Decodable {
            let access_token: String?
            let account_id: String?
        }
        let tokens: Tokens?
    }

    private func load() -> AuthFile.Tokens? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let file = try? JSONDecoder().decode(AuthFile.self, from: data) else { return nil }
        return file.tokens
    }

    func accessToken() async throws -> String {
        guard let token = load()?.access_token, !token.isEmpty else {
            throw ProviderError.notAuthenticated
        }
        return token
    }

    func accountID() async throws -> String? { load()?.account_id }
}
