import SwiftUI
import QuotaPetsShared

/// The Codex pet is DRAWN, not shipped as an image: a terminal window, whose cursor is
/// the pulse. It slows and its screen dims as quota drains, so the brand shape IS the
/// expression mechanism. (Claude has its own rig: `ClaudeMascotView`.)
///
/// No third-party artwork is copied or redistributed (§14). Supplying real images still
/// works — `MascotView` prefers an asset-catalog image when one exists.

/// Per-state pose. A value table, so tuning a mood means editing numbers.
struct PetPose: Equatable {
    var glow: CGFloat            // screen brightness, 0...1
    var cursorPeriod: Double     // blink seconds (higher = sleepier)
    var sink: CGFloat
    var tilt: Double
    var eyeOpen: CGFloat
    var mouthCurve: CGFloat
    var breathDuration: Double
    var showsZzz: Bool

    static func pose(for state: MascotEnergyState) -> PetPose {
        switch state {
        case .hyper:
            PetPose(glow: 1.00, cursorPeriod: 0.45,
                    sink: 0, tilt: 0, eyeOpen: 1.15, mouthCurve: 1.0,
                    breathDuration: 0.6, showsZzz: false)
        case .happy:
            PetPose(glow: 0.92, cursorPeriod: 0.7,
                    sink: 0, tilt: 0, eyeOpen: 1.0, mouthCurve: 0.8,
                    breathDuration: 1.5, showsZzz: false)
        case .normal:
            PetPose(glow: 0.80, cursorPeriod: 1.0,
                    sink: 1, tilt: 0, eyeOpen: 0.9, mouthCurve: 0.35,
                    breathDuration: 2.4, showsZzz: false)
        case .tired:
            PetPose(glow: 0.60, cursorPeriod: 1.8,
                    sink: 4, tilt: 4, eyeOpen: 0.45, mouthCurve: -0.15,
                    breathDuration: 3.8, showsZzz: false)
        case .exhausted:
            PetPose(glow: 0.38, cursorPeriod: 3.0,
                    sink: 8, tilt: 9, eyeOpen: 0.2, mouthCurve: -0.5,
                    breathDuration: 5.4, showsZzz: false)
        case .empty:
            PetPose(glow: 0.18, cursorPeriod: 0,
                    sink: 13, tilt: 12, eyeOpen: 0.0, mouthCurve: -0.2,
                    breathDuration: 6.5, showsZzz: true)
        }
    }
}

/// Eyes are capsules squashed on Y. A blink and a droop are the same mechanism, which is
/// why a tired pet's blink reads heavier with no extra artwork.
struct PetEyes: View {
    let size: CGFloat
    let gap: CGFloat
    let open: CGFloat
    let blinkClosed: Bool
    var color: Color = .black.opacity(0.75)

    var body: some View {
        HStack(spacing: gap) {
            ForEach(0..<2, id: \.self) { _ in
                Capsule()
                    .fill(color)
                    .frame(width: size, height: size * 1.2)
                    .scaleEffect(x: 1, y: blinkClosed ? 0.08 : max(0.08, open), anchor: .center)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: blinkClosed)
        .animation(.easeInOut(duration: 0.6), value: open)
    }
}

// MARK: - Codex

/// A terminal window. The prompt is always there; the cursor is the pulse, slowing and
/// dimming as quota drains until the screen goes dark.
struct CodexTerminalPet: View {
    let pose: PetPose
    let isAnimating: Bool
    let blinkClosed: Bool
    let cursorOn: Bool

    private let screen = Color(red: 0.07, green: 0.09, blue: 0.10)
    private let phosphor = Color(red: 0.40, green: 0.85, blue: 0.66)

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let w = side * 0.76, h = side * 0.60

            ZStack {
                RoundedRectangle(cornerRadius: side * 0.10, style: .continuous)
                    .fill(screen)
                    .overlay {
                        RoundedRectangle(cornerRadius: side * 0.10, style: .continuous)
                            .strokeBorder(phosphor.opacity(0.25 + 0.45 * pose.glow), lineWidth: 1.5)
                    }
                    .frame(width: w, height: h)
                    .overlay {
                        VStack(spacing: h * 0.13) {
                            PetEyes(size: w * 0.10, gap: w * 0.24,
                                    open: pose.eyeOpen, blinkClosed: blinkClosed,
                                    color: phosphor.opacity(0.35 + 0.65 * pose.glow))

                            HStack(spacing: w * 0.045) {
                                // The prompt chevron doubles as the mouth: it flips down
                                // as the mood sours.
                                Image(systemName: "chevron.right")
                                    .font(.system(size: w * 0.11, weight: .bold))
                                    .rotationEffect(.degrees(pose.mouthCurve < 0 ? 28 : 0))
                                Rectangle()
                                    .frame(width: w * 0.09, height: w * 0.11)
                                    .opacity(cursorOn ? 1 : 0.12)
                            }
                            .foregroundStyle(phosphor.opacity(0.35 + 0.65 * pose.glow))
                            .animation(.easeInOut(duration: 0.6), value: pose.mouthCurve)
                        }
                    }
                    // Faint screen bloom, strongest when the pet is lively.
                    .shadow(color: phosphor.opacity(0.35 * pose.glow), radius: side * 0.08)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .scaleEffect(x: 1, y: breathingScale, anchor: .bottom)
            .rotationEffect(.degrees(pose.tilt), anchor: .bottom)
            .offset(y: pose.sink)
            .animation(.easeInOut(duration: 0.7), value: pose.glow)
        }
    }

    private var breathingScale: CGFloat { 1 }
}

// MARK: - Host

/// Drives the Codex pet's timing (breathing, blinking, cursor).
struct PetShapeView: View {
    let state: MascotEnergyState
    let isAnimating: Bool

    @State private var breathing = false
    @State private var blinkClosed = false
    @State private var cursorOn = true

    private var pose: PetPose { PetPose.pose(for: state) }

    var body: some View {
        ZStack {
            if pose.showsZzz { zzz }
            CodexTerminalPet(pose: pose, isAnimating: isAnimating,
                             blinkClosed: blinkClosed, cursorOn: cursorOn)
        }
        .animation(.easeInOut(duration: 0.7), value: state)
        .animation(idleAnimation, value: breathing)
        .onAppear { restart() }
        .onChange(of: isAnimating) { _, _ in restart() }
        .onChange(of: state) { _, _ in restart() }
        .accessibilityHidden(true)
    }

    private var zzz: some View {
        VStack(spacing: 0) {
            Text("z").font(.system(size: 15, weight: .bold, design: .rounded))
            Text("z").font(.system(size: 11, weight: .bold, design: .rounded)).offset(x: 7, y: -2)
        }
        .foregroundStyle(.secondary)
        .offset(x: 34, y: -30)
        .opacity(breathing ? 0.9 : 0.3)
    }

    private var idleAnimation: Animation? {
        guard isAnimating else { return nil }
        return .easeInOut(duration: pose.breathDuration).repeatForever(autoreverses: true)
    }

    /// All motion is gated on `isAnimating`, so a backgrounded or dimmed screen leaves
    /// nothing repeating (§16, §20).
    private func restart() {
        breathing = isAnimating
        guard isAnimating, state.wantsIdleAnimation else {
            blinkClosed = false
            cursorOn = true
            return
        }
        scheduleBlink()
        scheduleCursor()
    }

    /// Irregular on purpose — a perfectly periodic blink reads as mechanical.
    private func scheduleBlink() {
        guard isAnimating, pose.eyeOpen > 0 else { return }
        let gap = Double.random(in: 2.0...5.5) * (state == .exhausted ? 0.5 : 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) {
            guard isAnimating else { return }
            blinkClosed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (pose.eyeOpen < 0.5 ? 0.35 : 0.14)) {
                blinkClosed = false
                scheduleBlink()
            }
        }
    }

    private func scheduleCursor() {
        guard isAnimating, pose.cursorPeriod > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + pose.cursorPeriod) {
            guard isAnimating else { return }
            cursorOn.toggle()
            scheduleCursor()
        }
    }
}
