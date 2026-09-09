import Foundation

/// The abstraction every usage source sits behind — real adapters, the mock provider
/// (§30), and the helper relay alike.
///
/// Keeping this protocol Foundation-only is what lets the Codex and Claude decoders be
/// tested on Linux without a network or an Apple platform.
public protocol UsageProvider: Sendable {
    var provider: AIProvider { get }
    func fetchUsage() async throws -> ProviderUsage
}
