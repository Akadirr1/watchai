import Testing
import Foundation
@testable import QuotaPetsShared

private let now = Date(timeIntervalSince1970: 1_757_000_000)

@Suite("Pairing")
struct PairingTests {

    @Test("a generated payload round-trips through its deep link")
    func roundTrip() throws {
        let payload = PairingPayload.generate(now: now, helperEndpoint: "192.168.1.10:8443")
        let url = try #require(payload.url)
        #expect(url.scheme == "quotapets")
        let parsed = try #require(PairingPayload.parse(url))
        #expect(parsed.nonce == payload.nonce)
        #expect(parsed.helperEndpoint == "192.168.1.10:8443")
        #expect(Int(parsed.expiresAt.timeIntervalSince1970) == Int(payload.expiresAt.timeIntervalSince1970))
    }

    // The QR is photographable, so this property is the one that matters.
    @Test("the payload carries no credential-shaped field")
    func carriesNoSecrets() throws {
        let payload = PairingPayload.generate(now: now)
        let json = try String(data: JSONEncoder().encode(payload), encoding: .utf8) ?? ""
        for forbidden in ["token", "access", "refresh", "secret", "password", "Bearer", "sk-ant"] {
            #expect(!json.lowercased().contains(forbidden.lowercased()))
        }
    }

    @Test("nonces are long and do not repeat")
    func nonceQuality() {
        let nonces = (0..<200).map { _ in PairingPayload.generate(now: now).nonce }
        #expect(Set(nonces).count == 200)
        #expect(nonces.allSatisfy { $0.count == 48 })   // 24 bytes hex-encoded
    }

    @Test("expiry is enforced")
    func expiry() {
        let payload = PairingPayload.generate(now: now, lifetime: 120)
        #expect(payload.isValid(at: now.addingTimeInterval(119)))
        #expect(!payload.isValid(at: now.addingTimeInterval(121)))
        #expect(payload.secondsRemaining(at: now.addingTimeInterval(200)) == 0)
    }

    @Test("a nonce is single-use")
    func singleUse() {
        var redemption = PairingRedemption()
        let payload = PairingPayload.generate(now: now)
        #expect(redemption.redeem(payload, at: now) == .accepted)
        #expect(redemption.redeem(payload, at: now) == .alreadyUsed)
    }

    @Test("an expired nonce is refused even if never used")
    func expiredRefused() {
        var redemption = PairingRedemption()
        let payload = PairingPayload.generate(now: now, lifetime: 60)
        #expect(redemption.redeem(payload, at: now.addingTimeInterval(61)) == .expired)
    }

    @Test("malformed links are rejected rather than half-parsed", arguments: [
        "https://example.com/pair?nonce=abc",
        "quotapets://other?nonce=abc",
        "quotapets://pair",
        "quotapets://pair?nonce=",
        "quotapets://pair?nonce=abc",          // missing exp
    ])
    func rejectsMalformed(raw: String) {
        #expect(PairingPayload.parse(URL(string: raw)!) == nil)
    }
}
