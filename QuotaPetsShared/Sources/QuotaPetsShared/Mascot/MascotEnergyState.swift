import Foundation

/// How alive the mascot looks (§15).
public enum MascotEnergyState: String, Codable, Sendable, CaseIterable, Hashable {
    case hyper, happy, normal, tired, exhausted, empty

    /// Ordered least- to most-depleted, so UI can compare severity without a switch.
    public var severity: Int {
        switch self {
        case .hyper: 0
        case .happy: 1
        case .normal: 2
        case .tired: 3
        case .exhausted: 4
        case .empty: 5
        }
    }

    /// Whether continuous idle animation is worth running at all (§16, §20).
    /// `.empty` is asleep and should be near-static.
    public var wantsIdleAnimation: Bool { self != .empty }
}

/// Which window is squeezing the mascot, and by how much.
///
/// The brief (§17) requires the UI to make the *cause* legible: a tired pet must be
/// explainable as "5-hour nearly gone" vs "weekly nearly gone".
public struct MascotPressure: Sendable, Hashable {
    public let state: MascotEnergyState
    /// The tighter of the two remaining percentages.
    public let remainingPercent: Double
    /// Which window produced it. Nil only when no window data exists at all.
    public let constrainingWindow: UsageWindowKind?

    public init(state: MascotEnergyState, remainingPercent: Double, constrainingWindow: UsageWindowKind?) {
        self.state = state
        self.remainingPercent = remainingPercent
        self.constrainingWindow = constrainingWindow
    }
}
