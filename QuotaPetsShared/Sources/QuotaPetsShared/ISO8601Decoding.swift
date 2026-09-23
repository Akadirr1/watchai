import Foundation

/// Date decoding that survives what the server actually sends.
///
/// `JSONDecoder.DateDecodingStrategy.iso8601` is built on `ISO8601DateFormatter` with only
/// `.withInternetDateTime`, which **rejects fractional seconds**. The server is Node, and
/// `Date.prototype.toISOString()` always emits milliseconds:
///
///     "2026-09-22T20:13:00.250Z"
///
/// So the stock strategy failed on every timestamp the API produces — and because the
/// failure surfaced as a generic decode error, the watch showed "SERVER ERROR" while the
/// server was answering 200 with a perfectly good body.
///
/// Both shapes are accepted here: a server that one day stops emitting milliseconds
/// (`toISOString` on a whole-second date still includes `.000`, but a different
/// serialiser might not) must not break the app either.
public enum ISO8601 {
    public static func date(from text: String) -> Date? {
        // Built per call rather than cached in a `static let`: `ISO8601DateFormatter` is
        // not `Sendable`, and Swift 6 strict concurrency rejects sharing one.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

public extension JSONDecoder {
    /// A decoder configured for this API's timestamps. Use it instead of setting
    /// `.dateDecodingStrategy = .iso8601`, which cannot read them.
    static func quotaPets() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = ISO8601.date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "not an ISO 8601 timestamp: \(text)")
            }
            return date
        }
        return decoder
    }
}
