import Foundation

/// The one build-time setting the watch still carries.
///
/// `Secrets.xcconfig` supplies `QUOTAPETS_API_URL` and nothing else — the token arrives
/// over the air through QR pairing. That leaves the bundle with no credential in it at
/// all, and lets the server's `AUTH_TOKEN` rotate without touching the app.
enum ServerConfig {
    static func baseURL(bundle: Bundle = .main) -> URL? {
        guard let raw = bundle.object(forInfoDictionaryKey: "QUOTAPETS_API_URL") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else { return nil }
        return url
    }
}
