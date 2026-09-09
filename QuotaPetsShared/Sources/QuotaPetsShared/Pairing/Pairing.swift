import Foundation

/// Pairing state machine (§23).
public enum PairingState: String, Codable, Sendable, Hashable {
    case idle, waitingForPhone, paired, expired, failed
}

/// The payload encoded into the pairing QR code.
///
/// Carries **no provider credential of any kind** (§4). It is a short-lived, single-use
/// nonce plus the helper endpoint to talk to. Even if the QR is photographed, it grants
/// nothing after `expiresAt`, and nothing at all once redeemed.
public struct PairingPayload: Codable, Sendable, Hashable {
    public static let scheme = "quotapets"
    public static let defaultLifetime: TimeInterval = 120

    public let nonce: String
    public let expiresAt: Date
    /// Optional helper endpoint discovered over Bonjour, so the phone need not re-scan.
    public let helperEndpoint: String?

    public init(nonce: String, expiresAt: Date, helperEndpoint: String? = nil) {
        self.nonce = nonce
        self.expiresAt = expiresAt
        self.helperEndpoint = helperEndpoint
    }

    /// Generates a payload with a cryptographically random nonce.
    ///
    /// The randomness source is injected so tests are deterministic — but the default is
    /// a real CSPRNG, not `Int.random`, because this value gates pairing.
    public static func generate(
        now: Date,
        lifetime: TimeInterval = defaultLifetime,
        helperEndpoint: String? = nil,
        randomBytes: (Int) -> [UInt8] = PairingPayload.secureRandomBytes
    ) -> PairingPayload {
        let nonce = randomBytes(24).map { String(format: "%02x", $0) }.joined()
        return PairingPayload(nonce: nonce,
                              expiresAt: now.addingTimeInterval(lifetime),
                              helperEndpoint: helperEndpoint)
    }

    public static func secureRandomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        return bytes
    }

    public func isValid(at now: Date) -> Bool { now < expiresAt }

    public func secondsRemaining(at now: Date) -> TimeInterval { max(0, expiresAt.timeIntervalSince(now)) }

    /// `quotapets://pair?nonce=…` — the deep link the QR encodes.
    public var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        var items = [URLQueryItem(name: "nonce", value: nonce),
                     URLQueryItem(name: "exp", value: String(Int(expiresAt.timeIntervalSince1970)))]
        if let helperEndpoint { items.append(URLQueryItem(name: "helper", value: helperEndpoint)) }
        components.queryItems = items
        return components.url
    }

    /// Parses a deep link back into a payload, rejecting anything malformed.
    public static func parse(_ url: URL) -> PairingPayload? {
        guard url.scheme == scheme, url.host == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let nonce = items.first(where: { $0.name == "nonce" })?.value, !nonce.isEmpty,
              let expRaw = items.first(where: { $0.name == "exp" })?.value,
              let exp = TimeInterval(expRaw)
        else { return nil }
        return PairingPayload(nonce: nonce,
                              expiresAt: Date(timeIntervalSince1970: exp),
                              helperEndpoint: items.first(where: { $0.name == "helper" })?.value)
    }
}

/// Tracks which nonces have been redeemed, enforcing single use (§4).
public struct PairingRedemption: Sendable {
    private var redeemed: Set<String> = []

    public init() {}

    public enum Outcome: Sendable, Hashable { case accepted, expired, alreadyUsed, malformed }

    public mutating func redeem(_ payload: PairingPayload, at now: Date) -> Outcome {
        guard !payload.nonce.isEmpty else { return .malformed }
        guard payload.isValid(at: now) else { return .expired }
        guard !redeemed.contains(payload.nonce) else { return .alreadyUsed }
        redeemed.insert(payload.nonce)
        return .accepted
    }
}
