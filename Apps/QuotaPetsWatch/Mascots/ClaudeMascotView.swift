import SwiftUI
import QuotaPetsShared

/// The Claude mascot (github.com/Akadirr1/mascot), drawn from `ClaudeMascotRig`.
///
/// Plays the clips for the current mood on a loop. With the scene inactive, the display
/// dimmed or Reduce Motion on, it holds the first frame instead of freezing mid-jump.
struct ClaudeMascotView: View {
    let state: MascotEnergyState
    let working: Bool
    let isAnimating: Bool

    @AppStorage("bandana") private var bandana = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When the current mood began, so a new one starts from its first clip.
    @State private var start = Date()

    private var rotation: [ClaudeClip] { ClaudeClip.rotation(for: state, working: working) }
    private var moving: Bool { isAnimating && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { timeline in
            // Worked out here, so the renderer below captures a plain value, not view state.
            let shapes = ClaudeMascotRig.shapes(rotation, at: moving ? timeline.date.timeIntervalSince(start) : 0,
                                                bandana: bandana)
            Canvas { context, size in
                let box = ClaudeMascotRig.viewBox
                let scale = min(size.width / box.width, size.height / box.height)
                context.translateBy(x: (size.width - box.width * scale) / 2 - box.minX * scale,
                                    y: (size.height - box.height * scale) / 2 - box.minY * scale)
                context.scaleBy(x: scale, y: scale)
                for shape in shapes {
                    var path = Path()
                    path.addLines(shape.points)
                    path.closeSubpath()
                    let color = Color(red: Double(shape.rgb >> 16 & 0xFF) / 255,
                                      green: Double(shape.rgb >> 8 & 0xFF) / 255,
                                      blue: Double(shape.rgb & 0xFF) / 255)
                    context.fill(path, with: .color(color.opacity(shape.opacity)))
                }
            }
        }
        .onChange(of: rotation) { _, _ in start = .now }
    }
}
