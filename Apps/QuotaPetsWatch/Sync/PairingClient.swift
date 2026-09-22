import Foundation
import QuotaPetsShared

/// The watch's half of QR pairing.
///
/// The watch asks the server for a code, shows a QR that encodes
/// `https://<server>/pair?c=<code>`, and polls until the phone has opened that link while
/// signed in. Then a device token — not the server's admin token — lands in the Keychain.
///
/// The QR encodes a *URL* because iOS Safari has no `BarcodeDetector`: a scanner inside
/// the web page would have been broken on the one device that has to scan this. The
/// iPhone's own Camera app reads it, Safari opens the link, and the session cookie the
/// user already has from `/setup` completes the claim.
///
/// None of these calls carry a credential, because the watch does not have one yet. What
/// keeps the flow safe is that the code is inert: claiming it requires the admin cookie,
/// and the `secret` that authorises this poll never appears in the QR.
struct PairingClient: Sendable {
    struct Session: Sendable {
        let code: String
        let secret: String
        let expiresAt: Date
        let qrURL: URL
    }

    enum Failure: Error, Sendable {
        case offline
        case server(status: Int)
        case malformed
    }

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func start() async throws -> Session {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pair/start"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15

        let (data, response) = try await perform(request)
        try expectOK(response)

        // NOT `.iso8601`: that strategy cannot read the server's timestamps at all, which
        // is what made a healthy server report "SERVER ERROR". See ISO8601Decoding.swift.
        guard let body = try? JSONDecoder.quotaPets().decode(StartResponse.self, from: data) else {
            throw Failure.malformed
        }
        // The QR image is fetched from the URL the watch is configured with, not from the
        // `qrUrl` the server returns. Those differ when PUBLIC_URL is set to an origin
        // the watch cannot reach; this one is reachable by definition, since the start
        // call just succeeded against it.
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/pair/qr"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "c", value: body.code)]
        guard let qrURL = components?.url else { throw Failure.malformed }

        return Session(
            code: body.code,
            secret: body.secret,
            expiresAt: body.expiresAt,
            qrURL: qrURL)
    }

    func qrImageData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await perform(request)
        try expectOK(response)
        guard !data.isEmpty else { throw Failure.malformed }
        return data
    }

    /// `nil` means "not claimed yet" — keep polling. The server answers unknown, expired,
    /// unclaimed and wrong-secret with the same 404, so this call cannot distinguish them
    /// either; expiry is detected from the session's own `expiresAt`.
    func poll(code: String, secret: String) async throws -> String? {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pair/poll"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(PollRequest(code: code, secret: secret))

        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else {
            throw Failure.server(status: http.statusCode)
        }
        guard let body = try? JSONDecoder().decode(PollResponse.self, from: data),
              !body.deviceToken.isEmpty
        else { throw Failure.malformed }
        return body.deviceToken
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw Failure.offline
        }
    }

    private func expectOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
        guard (200...299).contains(http.statusCode) else {
            throw Failure.server(status: http.statusCode)
        }
    }

    private struct StartResponse: Decodable {
        let code: String
        let secret: String
        let expiresAt: Date
    }

    private struct PollRequest: Encodable {
        let code: String
        let secret: String
    }

    private struct PollResponse: Decodable {
        let deviceToken: String
    }
}
