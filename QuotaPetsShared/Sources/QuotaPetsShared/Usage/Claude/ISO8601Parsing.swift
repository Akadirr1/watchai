import Foundation

/// ISO-8601 parsing accepting both the fractional-seconds and whole-second forms.
/// A single configured `ISO8601DateFormatter` will not accept both, which is a classic
/// source of "parses in tests, returns nil in production".
///
/// Formatters are constructed per call rather than cached in a `static let`:
/// `ISO8601DateFormatter` is a non-`Sendable` class, so a shared static instance is a
/// data race under Swift 6 strict concurrency (the compiler rejects it outright). This
/// runs roughly twice per refresh, so the allocation is irrelevant next to the network
/// call it accompanies.
enum ISO8601 {
    static func date(from string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: string) { return d }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
