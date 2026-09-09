import SwiftUI
import QuotaPetsShared

/// Art slots (§14).
///
/// The app ships with NO mascot artwork. Drop images into the watch target's asset
/// catalog under exactly these names and they appear with no code change; until then the
/// placeholder below renders, which is deliberately obvious rather than a generic emoji
/// silently standing in for real art.
///
/// Required assets, per provider and energy state:
///     claudeMascot-hyper, claudeMascot-happy, claudeMascot-normal,
///     claudeMascot-tired, claudeMascot-exhausted, claudeMascot-empty
///     codexMascot-<same six>
/// A single `claudeMascot` / `codexMascot` is used as a fallback when a per-state image
/// is missing, so partial art sets still work.
public enum MascotAsset {
    public static func name(for provider: AIProvider, state: MascotEnergyState) -> String {
        "\(provider.rawValue)Mascot-\(state.rawValue)"
    }

    public static func fallbackName(for provider: AIProvider) -> String {
        "\(provider.rawValue)Mascot"
    }
}

/// The dominant visual (§13). Animation is foreground-only and driven entirely by the
/// energy state — no timers, no Core Motion, nothing that survives backgrounding (§20).
public struct MascotView: View {
    public let provider: AIProvider
    public let state: MascotEnergyState
    /// Set false when the scene is inactive or the display dimmed, which stops every
    /// animation rather than merely hiding it (§16, §20).
    public let isAnimating: Bool

    @State private var breathing = false

    public init(provider: AIProvider, state: MascotEnergyState, isAnimating: Bool) {
        self.provider = provider
        self.state = state
        self.isAnimating = isAnimating
    }

    public var body: some View {
        artwork
            .frame(maxWidth: .infinity)
            .scaleEffect(breathing ? idle.scale : 1.0)
            .offset(y: breathing ? idle.drift : 0)
            .opacity(state == .empty ? 0.55 : 1.0)
            .animation(idle.animation, value: breathing)
            .onAppear { breathing = shouldAnimate }
            .onChange(of: isAnimating) { _, running in breathing = running && state.wantsIdleAnimation }
            .onChange(of: state) { _, _ in breathing = shouldAnimate }
            .accessibilityLabel("\(provider.displayName) mascot, \(state.rawValue)")
    }

    private var shouldAnimate: Bool { isAnimating && state.wantsIdleAnimation }

    @ViewBuilder
    private var artwork: some View {
        // `Image(_:)` on a missing asset renders empty rather than trapping, so the
        // placeholder is chosen explicitly instead of relying on that.
        if let ui = MascotImageLoader.image(named: MascotAsset.name(for: provider, state: state))
            ?? MascotImageLoader.image(named: MascotAsset.fallbackName(for: provider)) {
            Image(uiImage: ui).resizable().scaledToFit()
        } else {
            MascotPlaceholder(provider: provider, state: state)
        }
    }

    /// Per-state idle motion (§16). Slower and lower as quota drains.
    private var idle: (scale: CGFloat, drift: CGFloat, animation: Animation?) {
        guard shouldAnimate else { return (1, 0, nil) }
        switch state {
        case .hyper:     return (1.06, -3, .easeInOut(duration: 0.9).repeatForever(autoreverses: true))
        case .happy:     return (1.04, -2, .easeInOut(duration: 1.6).repeatForever(autoreverses: true))
        case .normal:    return (1.03, -1, .easeInOut(duration: 2.4).repeatForever(autoreverses: true))
        case .tired:     return (1.02, 1, .easeInOut(duration: 3.6).repeatForever(autoreverses: true))
        case .exhausted: return (1.01, 2, .easeInOut(duration: 5.0).repeatForever(autoreverses: true))
        case .empty:     return (1, 3, nil)
        }
    }
}

enum MascotImageLoader {
    static func image(named name: String) -> UIImage? { UIImage(named: name) }
}

/// Obvious stand-in so a missing asset reads as "art not supplied yet", never as a
/// finished design (§14).
struct MascotPlaceholder: View {
    let provider: AIProvider
    let state: MascotEnergyState

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                .foregroundStyle(.secondary)
            VStack(spacing: 2) {
                Text(provider.displayName.prefix(1))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("no art")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 64)
    }
}
