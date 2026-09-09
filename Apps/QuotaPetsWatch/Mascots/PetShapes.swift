import SwiftUI
import QuotaPetsShared

/// The mascots are DRAWN, not shipped as images.
///
/// This matters for three reasons: no third-party artwork is copied (§14), the character
/// can actually animate per energy state rather than swapping static frames, and it
/// scales cleanly from a 41mm watch face to a complication without an asset pipeline.
///
/// Supplying real art still works — `MascotView` prefers an asset catalog image when one
/// exists and falls back to these shapes otherwise.

/// Per-state pose. Everything the animation needs is a value here, so the drawing code
/// stays declarative and the states can be diffed at a glance.
struct PetPose: Equatable {
    var bodyScaleY: CGFloat      // squash / stretch
    var sink: CGFloat            // how far the whole body drops
    var tilt: Double             // slump angle
    var eyeOpen: CGFloat         // 1 = wide, 0 = shut
    var mouthCurve: CGFloat      // +up = smile, -down = frown
    var breathDuration: Double
    var breathAmount: CGFloat
    var showsZzz: Bool
    var showsSpark: Bool

    static func pose(for state: MascotEnergyState) -> PetPose {
        switch state {
        case .hyper:
            PetPose(bodyScaleY: 1.00, sink: 0, tilt: 0, eyeOpen: 1.15, mouthCurve: 1.0,
                    breathDuration: 0.55, breathAmount: 0.10, showsZzz: false, showsSpark: true)
        case .happy:
            PetPose(bodyScaleY: 1.00, sink: 0, tilt: 0, eyeOpen: 1.0, mouthCurve: 0.8,
                    breathDuration: 1.5, breathAmount: 0.05, showsZzz: false, showsSpark: false)
        case .normal:
            PetPose(bodyScaleY: 1.00, sink: 1, tilt: 0, eyeOpen: 0.9, mouthCurve: 0.35,
                    breathDuration: 2.4, breathAmount: 0.035, showsZzz: false, showsSpark: false)
        case .tired:
            PetPose(bodyScaleY: 0.95, sink: 4, tilt: 4, eyeOpen: 0.45, mouthCurve: -0.15,
                    breathDuration: 3.8, breathAmount: 0.025, showsZzz: false, showsSpark: false)
        case .exhausted:
            PetPose(bodyScaleY: 0.88, sink: 8, tilt: 9, eyeOpen: 0.2, mouthCurve: -0.5,
                    breathDuration: 5.4, breathAmount: 0.02, showsZzz: false, showsSpark: false)
        case .empty:
            PetPose(bodyScaleY: 0.78, sink: 13, tilt: 13, eyeOpen: 0.0, mouthCurve: -0.2,
                    breathDuration: 6.5, breathAmount: 0.015, showsZzz: true, showsSpark: false)
        }
    }
}

/// Provider identity. Two visually distinct characters so a glance tells them apart even
/// on a corner complication: Claude is soft and round, Codex is angular and terminal-ish.
struct PetSkin {
    let bodyCorner: CGFloat      // large = round blob, small = boxy
    let tint: Color
    let deepTint: Color
    let hasTuft: Bool            // Claude's spark tuft
    let hasCursor: Bool          // Codex's blinking cursor

    static func skin(for provider: AIProvider) -> PetSkin {
        switch provider {
        case .claude:
            PetSkin(bodyCorner: 0.5,
                    tint: Color(red: 0.85, green: 0.47, blue: 0.32),
                    deepTint: Color(red: 0.55, green: 0.26, blue: 0.16),
                    hasTuft: true, hasCursor: false)
        case .codex:
            PetSkin(bodyCorner: 0.28,
                    tint: Color(red: 0.40, green: 0.72, blue: 0.60),
                    deepTint: Color(red: 0.16, green: 0.36, blue: 0.31),
                    hasTuft: false, hasCursor: true)
        }
    }
}

/// A mouth that bends from smile to frown through a single -1...1 parameter, so the
/// transition between energy states is continuous rather than a set of discrete faces.
struct MouthShape: Shape {
    var curve: CGFloat

    var animatableData: CGFloat {
        get { curve }
        set { curve = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midY
        let lift = rect.height * curve * 0.5
        path.move(to: CGPoint(x: rect.minX, y: mid))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: mid),
            control: CGPoint(x: rect.midX, y: mid + lift)
        )
        return path
    }
}

/// The drawn pet.
struct PetShapeView: View {
    let provider: AIProvider
    let state: MascotEnergyState
    let isAnimating: Bool

    @State private var breathing = false
    @State private var blinkClosed = false

    private var pose: PetPose { PetPose.pose(for: state) }
    private var skin: PetSkin { PetSkin.skin(for: provider) }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                if pose.showsZzz { zzz(side: side) }
                body(side: side)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { startIdle() }
        .onChange(of: isAnimating) { _, _ in startIdle() }
        .onChange(of: state) { _, _ in startIdle() }
        .accessibilityHidden(true)
    }

    private func body(side: CGFloat) -> some View {
        let w = side * 0.72
        let h = side * 0.62

        return ZStack {
            if skin.hasTuft { tuft(side: side).offset(y: -h * 0.62) }

            RoundedRectangle(cornerRadius: w * skin.bodyCorner, style: .continuous)
                .fill(
                    LinearGradient(colors: [skin.tint, skin.deepTint],
                                   startPoint: .top, endPoint: .bottom)
                )
                .frame(width: w, height: h)
                .overlay(face(width: w, height: h))

            if pose.showsSpark { spark(side: side).offset(x: w * 0.52, y: -h * 0.45) }
        }
        // Breathing is a squash on Y only, so the silhouette keeps its footprint —
        // scaling both axes reads as zooming, not living.
        .scaleEffect(x: 1, y: pose.bodyScaleY * (breathing ? 1 + pose.breathAmount : 1), anchor: .bottom)
        .rotationEffect(.degrees(pose.tilt), anchor: .bottom)
        .offset(y: pose.sink)
        .animation(.easeInOut(duration: 0.6), value: state)
        .animation(idleAnimation, value: breathing)
    }

    private func face(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: height * 0.13) {
            HStack(spacing: width * 0.22) {
                eye(size: width * 0.13)
                eye(size: width * 0.13)
            }
            MouthShape(curve: pose.mouthCurve)
                .stroke(Color.black.opacity(0.55), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: width * 0.30, height: height * 0.16)
                .animation(.easeInOut(duration: 0.6), value: pose.mouthCurve)
        }
        .offset(y: -height * 0.04)
    }

    /// Eyes are capsules scaled on Y. A blink is the same mechanism as a droop, which is
    /// why a tired pet's blink reads as heavier without any extra artwork.
    private func eye(size: CGFloat) -> some View {
        Capsule()
            .fill(Color.black.opacity(0.72))
            .frame(width: size, height: size * 1.15)
            .scaleEffect(x: 1, y: blinkClosed ? 0.08 : max(0.08, pose.eyeOpen), anchor: .center)
            .animation(.easeInOut(duration: 0.12), value: blinkClosed)
            .animation(.easeInOut(duration: 0.6), value: pose.eyeOpen)
            .overlay {
                if skin.hasCursor && pose.eyeOpen > 0.3 {
                    Rectangle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: size * 0.28, height: size * 0.28)
                        .offset(x: size * 0.12, y: -size * 0.15)
                }
            }
    }

    private func tuft(side: CGFloat) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(skin.tint)
                    .frame(width: side * 0.035, height: side * 0.13)
                    .rotationEffect(.degrees(Double(i - 1) * 32))
            }
        }
        .opacity(state == .empty ? 0.5 : 1)
    }

    private func spark(side: CGFloat) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: side * 0.13, weight: .bold))
            .foregroundStyle(.yellow)
            .opacity(breathing ? 1 : 0.35)
    }

    private func zzz(side: CGFloat) -> some View {
        VStack(spacing: 1) {
            ForEach(0..<2, id: \.self) { i in
                Text("z")
                    .font(.system(size: side * (0.11 - CGFloat(i) * 0.02), weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .offset(x: CGFloat(i) * side * 0.05)
            }
        }
        .offset(x: side * 0.26, y: -side * 0.26)
        .opacity(breathing ? 0.9 : 0.3)
    }

    private var idleAnimation: Animation? {
        guard isAnimating else { return nil }
        return .easeInOut(duration: pose.breathDuration).repeatForever(autoreverses: true)
    }

    /// Starts (or stops) idle motion. Everything is driven off `isAnimating`, so a
    /// backgrounded or dimmed screen leaves no repeating animation running (§16, §20).
    private func startIdle() {
        breathing = isAnimating
        guard isAnimating, state.wantsIdleAnimation else {
            blinkClosed = false
            return
        }
        scheduleBlink()
    }

    /// Blinks are irregular on purpose — a perfectly periodic blink reads as mechanical.
    /// An exhausted pet blinks slowly and often; an empty one not at all.
    private func scheduleBlink() {
        guard isAnimating, pose.eyeOpen > 0 else { return }
        let gap = Double.random(in: 2.0...5.5) * (state == .exhausted ? 0.5 : 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) {
            guard isAnimating else { return }
            blinkClosed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (state == .tired || state == .exhausted ? 0.35 : 0.14)) {
                blinkClosed = false
                scheduleBlink()
            }
        }
    }
}
