import SwiftUI
import QuotaPetsShared

/// The mascots are DRAWN, not shipped as images.
///
/// Each pet is built from the *form* its provider is recognisable by, redrawn as an
/// original character rather than copying a brand asset:
///   - Claude  → a radiating spark, whose arms are the energy gauge
///   - Codex   → a terminal window, whose cursor is the pulse
///
/// No third-party artwork is copied or redistributed (§14). Supplying real images still
/// works — `MascotView` prefers an asset-catalog image when one exists.
///
/// The point of the form choice: in both cases the brand shape IS the expression
/// mechanism. Claude's arms shorten and droop as quota drains; Codex's cursor slows and
/// its screen dims. Nothing has to be bolted on to show mood.

/// Per-state pose. A value table, so tuning a mood means editing numbers.
struct PetPose: Equatable {
    var armLength: CGFloat       // Claude: ray extension, 0...1
    var armDroop: Double         // Claude: degrees each ray bends downward
    var glow: CGFloat            // Codex: screen brightness, 0...1
    var cursorPeriod: Double     // Codex: blink seconds (higher = sleepier)
    var sink: CGFloat
    var tilt: Double
    var eyeOpen: CGFloat
    var mouthCurve: CGFloat
    var breathDuration: Double
    var breathAmount: CGFloat
    var showsZzz: Bool

    static func pose(for state: MascotEnergyState) -> PetPose {
        switch state {
        case .hyper:
            PetPose(armLength: 1.00, armDroop: -6, glow: 1.00, cursorPeriod: 0.45,
                    sink: 0, tilt: 0, eyeOpen: 1.15, mouthCurve: 1.0,
                    breathDuration: 0.6, breathAmount: 0.09, showsZzz: false)
        case .happy:
            PetPose(armLength: 0.92, armDroop: 0, glow: 0.92, cursorPeriod: 0.7,
                    sink: 0, tilt: 0, eyeOpen: 1.0, mouthCurve: 0.8,
                    breathDuration: 1.5, breathAmount: 0.05, showsZzz: false)
        case .normal:
            PetPose(armLength: 0.80, armDroop: 8, glow: 0.80, cursorPeriod: 1.0,
                    sink: 1, tilt: 0, eyeOpen: 0.9, mouthCurve: 0.35,
                    breathDuration: 2.4, breathAmount: 0.035, showsZzz: false)
        case .tired:
            PetPose(armLength: 0.62, armDroop: 24, glow: 0.60, cursorPeriod: 1.8,
                    sink: 4, tilt: 4, eyeOpen: 0.45, mouthCurve: -0.15,
                    breathDuration: 3.8, breathAmount: 0.025, showsZzz: false)
        case .exhausted:
            PetPose(armLength: 0.44, armDroop: 44, glow: 0.38, cursorPeriod: 3.0,
                    sink: 8, tilt: 9, eyeOpen: 0.2, mouthCurve: -0.5,
                    breathDuration: 5.4, breathAmount: 0.02, showsZzz: false)
        case .empty:
            PetPose(armLength: 0.28, armDroop: 66, glow: 0.18, cursorPeriod: 0,
                    sink: 13, tilt: 12, eyeOpen: 0.0, mouthCurve: -0.2,
                    breathDuration: 6.5, breathAmount: 0.015, showsZzz: true)
        }
    }
}

/// One tapered spark arm: wide at the hub, pointed at the tip.
struct SparkArm: Shape {
    var extend: CGFloat

    var animatableData: CGFloat {
        get { extend }
        set { extend = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let full = rect.height
        let length = max(w * 0.5, full * extend)
        let halfW = w / 2

        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY - length))            // tip
        p.addQuadCurve(to: CGPoint(x: rect.midX + halfW, y: rect.maxY),
                       control: CGPoint(x: rect.midX + halfW * 0.75, y: rect.maxY - length * 0.32))
        p.addLine(to: CGPoint(x: rect.midX - halfW, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY - length),
                       control: CGPoint(x: rect.midX - halfW * 0.75, y: rect.maxY - length * 0.32))
        p.closeSubpath()
        return p
    }
}

/// Mouth bending continuously from smile to frown through one -1...1 parameter, so moods
/// blend rather than snapping between discrete faces.
struct MouthShape: Shape {
    var curve: CGFloat

    var animatableData: CGFloat {
        get { curve }
        set { curve = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let mid = rect.midY
        p.move(to: CGPoint(x: rect.minX, y: mid))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: mid),
                       control: CGPoint(x: rect.midX, y: mid + rect.height * curve * 0.5))
        return p
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

// MARK: - Claude

/// A radiating spark whose arms are the quota gauge: full and lifted when fresh, short
/// and wilted when spent.
struct ClaudeSparkPet: View {
    let pose: PetPose
    let isAnimating: Bool
    let blinkClosed: Bool
    let breathing: Bool

    private let armCount = 11
    private let tint = Color(red: 0.80, green: 0.47, blue: 0.36)
    private let deep = Color(red: 0.62, green: 0.31, blue: 0.21)

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let hub = side * 0.34

            ZStack {
                // Arms radiate from the hub. Droop is applied on top of each arm's own
                // angle, so the whole crown wilts downward rather than merely shrinking.
                ForEach(0..<armCount, id: \.self) { i in
                    let angle = Double(i) / Double(armCount) * 360
                    // 1 at the top of the crown, 0 at the bottom.
                    let upness = (1 + cos(angle * .pi / 180)) / 2
                    // Wilting reads better as the TOP arms collapsing than as every arm
                    // rotating: the crown flattens downward the way a spent flower does,
                    // while the arms already pointing down keep holding it up.
                    let penalty = (pose.armDroop / 90) * upness * 0.8
                    SparkArm(extend: max(0.12, pose.armLength * (1 - penalty)))
                        .fill(LinearGradient(colors: [tint, deep], startPoint: .top, endPoint: .bottom))
                        .frame(width: side * 0.085, height: side * 0.46)
                        .offset(y: -side * 0.23)
                        .rotationEffect(.degrees(angle))
                }
                .animation(.easeInOut(duration: 0.7), value: pose.armLength)
                .animation(.easeInOut(duration: 0.7), value: pose.armDroop)

                Circle()
                    .fill(LinearGradient(colors: [tint, deep], startPoint: .top, endPoint: .bottom))
                    .frame(width: hub, height: hub)
                    .overlay {
                        VStack(spacing: hub * 0.14) {
                            PetEyes(size: hub * 0.15, gap: hub * 0.26,
                                    open: pose.eyeOpen, blinkClosed: blinkClosed)
                            MouthShape(curve: pose.mouthCurve)
                                .stroke(Color.black.opacity(0.5),
                                        style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                                .frame(width: hub * 0.34, height: hub * 0.18)
                                .animation(.easeInOut(duration: 0.6), value: pose.mouthCurve)
                        }
                    }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .scaleEffect(breathing ? 1 + pose.breathAmount : 1)
            .rotationEffect(.degrees(pose.tilt))
            .offset(y: pose.sink)
        }
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

/// Drives shared timing (breathing, blinking, cursor) and picks the provider's form.
struct PetShapeView: View {
    let provider: AIProvider
    let state: MascotEnergyState
    let isAnimating: Bool

    @State private var breathing = false
    @State private var blinkClosed = false
    @State private var cursorOn = true

    private var pose: PetPose { PetPose.pose(for: state) }

    var body: some View {
        ZStack {
            if pose.showsZzz { zzz }
            switch provider {
            case .claude:
                ClaudeSparkPet(pose: pose, isAnimating: isAnimating,
                               blinkClosed: blinkClosed, breathing: breathing)
            case .codex:
                CodexTerminalPet(pose: pose, isAnimating: isAnimating,
                                 blinkClosed: blinkClosed, cursorOn: cursorOn)
            }
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
        guard isAnimating, provider == .codex, pose.cursorPeriod > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + pose.cursorPeriod) {
            guard isAnimating else { return }
            cursorOn.toggle()
            scheduleCursor()
        }
    }
}
