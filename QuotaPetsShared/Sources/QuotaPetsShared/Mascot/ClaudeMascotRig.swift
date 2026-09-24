import Foundation
#if canImport(CoreGraphics)
// Apple's Foundation leaves CGPoint/CGRect's Swift API (init(x:y:width:height:), minX,
// .zero, Equatable) to CoreGraphics; Linux's Foundation has it built in.
import CoreGraphics
#endif

// The Claude mascot, ported from github.com/Akadirr1/mascot (claude-mascot.js @ a323dcc).
//
// A rect-only pixel rig. Poses, colours, frame holds and eases are the JS source's own
// numbers, and every clip reproduces what GSAP actually renders there, quirks included:
//  - a blink's reopen tween has no position, so GSAP appends it to the END of the
//    timeline and the eyes stay shut until then;
//  - the ground clip lives in the rig's own space, so a raised frame raises it too;
//  - walk and celebrate poses carry a hidden band, so the bandana is off while they play.
//
// Foundation-only so Linux CI checks it; the watch just fills the polygons it returns.

/// What the mascot is doing. A mood is a few clips played in turn, on a loop.
public enum ClaudeClip: String, CaseIterable, Sendable {
    case look, jump, idle, walk, tighten, gym, flagWave, celebrate, sweat

    /// Idle while nothing happens, busy while usage climbs, waving the flag when little
    /// quota is left and sweating once it is gone.
    public static func rotation(for state: MascotEnergyState, working: Bool) -> [ClaudeClip] {
        switch state {
        case .empty: [.sweat]
        case .exhausted: [.flagWave, .celebrate]
        default: working ? [.walk, .tighten, .gym] : [.look, .jump, .idle]
        }
    }
}

/// One filled polygon, in `ClaudeMascotRig.viewBox` coordinates.
public struct RigShape: Sendable, Equatable {
    public let points: [CGPoint]
    /// 0xRRGGBB.
    public let rgb: UInt32
    public let opacity: Double
}

public enum ClaudeMascotRig {
    /// The JS viewBox: the 129×86 character plus headroom for the jump, flag and confetti.
    public static let viewBox = CGRect(x: -40, y: -80, width: 210, height: 190)

    /// Everything to draw `time` seconds into `rotation`, which loops.
    public static func shapes(_ rotation: [ClaudeClip], at time: Double, bandana: Bool) -> [RigShape] {
        guard let last = rotation.last else { return [] }
        var t = max(0, time)
        // A lone clip keeps its own clock: sweat's beads outlive a single breath.
        if rotation.count > 1 {
            t = t.truncatingRemainder(dividingBy: rotation.reduce(0) { $0 + duration($1, bandana: bandana) })
        }
        for clip in rotation.dropLast() {
            let d = duration(clip, bandana: bandana)
            if t < d { return scene(clip, at: t, bandana: bandana).shapes(bandana: bandana) }
            t -= d
        }
        return scene(last, at: t, bandana: bandana).shapes(bandana: bandana)
    }

    /// One play-through, in seconds: where each clip's last tween or frame ends.
    static func duration(_ clip: ClaudeClip, bandana: Bool) -> Double {
        switch clip {
        case .look: 2.49
        case .jump: 1.14
        case .idle: 4.67
        case .sweat: 2 * sweatBreath
        default: frames(clip, bandana: bandana).reduce(0) { $0 + $1.hold }
        }
    }

    // MARK: - Clips

    /// Sweat plays at full stress (quota gone): JS `cycle = 1.1 - stress * 0.55`,
    /// `beads = round(stress * 4)`, and the brow angles past half.
    private static let sweatBreath = 0.55
    private static let beadsPerLoop = 4

    private static func scene(_ clip: ClaudeClip, at t: Double, bandana: Bool) -> Scene {
        var s = Scene()
        switch clip {
        case .idle:
            s.rigScale = (track(t, from: 1, breaths(0.99, 1.1, count: 2)), track(t, from: 1, breaths(1.03, 1.1, count: 2)))
            s.eyeScale = track(t, from: 1, blinks([0.9, 1.25, 3.1], end: 4.4))
        case .look:
            s.eyeShift = track(t, from: 0, [Tween(0, 0.22, 6, .power2Out), Tween(0.85, 0.34, -7, .power2InOut),
                                            Tween(1.9, 0.3, 0, .power2Out)])
            s.rigRotation = track(t, from: 0, [Tween(0.12, 0.4, 6, .power2Out), Tween(0.95, 0.5, -8, .power2InOut),
                                               Tween(2.0, 0.4, 0, .power2Out)])
            s.eyeScale = track(t, from: 1, blinks([1.55], end: 2.4))
        case .jump:
            // Crouch, rise, fall, land: the rig squashes and stretches while each leg
            // kicks about its own foot.
            s.rigScale = (
                track(t, from: 1, [Tween(0, 0.1, 1.08, .power3In), Tween(0.1, 0.2, 0.93, .power2Out),
                                   Tween(0.34, 0.22, 1, .sineInOut), Tween(0.72, 0.07, 1.07, .power3In),
                                   Tween(0.79, 0.35, 1, .power2Out)]),
                track(t, from: 1, [Tween(0, 0.1, 0.86, .power3In), Tween(0.1, 0.2, 1.12, .power2Out),
                                   Tween(0.34, 0.22, 1, .sineInOut), Tween(0.72, 0.07, 0.9, .power3In),
                                   Tween(0.79, 0.35, 1, .power2Out)]))
            let squash = [1.35, 1.25, 1.2, 1.15], tilt = [-9, -8, -7.5, -7.0]
            for i in 0..<4 {
                s.legScale[i] = track(t, from: 1, [Tween(0, 0.1, squash[i], .power3In),
                                                   Tween(0.1, 0.24, 0.9, .power2Out), Tween(0.54, 0.18, 1, .power2In)])
                s.legRotation[i] = track(t, from: 0, [Tween(0, 0.1, tilt[i], .power3In),
                                                      Tween(0.1, 0.24, 6 - Double(i), .power2Out),
                                                      Tween(0.54, 0.18, 0, .power2In)])
            }
            s.root = CGPoint(x: track(t, from: 0, [Tween(0.1, 0.36, 16, .power1InOut), Tween(0.46, 0.4, 0, .power1InOut)]),
                             y: track(t, from: 0, [Tween(0.1, 0.42, -46, .sineOut), Tween(0.52, 0.2, 0, .power3In)]))
            s.shadowScale = track(t, from: 1, [Tween(0.1, 0.42, 0.55, .sineOut), Tween(0.52, 0.2, 1, .power3In)])
            s.shadowOpacity = track(t, from: 1, [Tween(0.1, 0.42, 0.45, .sineOut), Tween(0.52, 0.2, 1, .power3In)])
        case .sweat:
            let breath = t.truncatingRemainder(dividingBy: 2 * sweatBreath)
            s.brows = true
            s.rigScale = (track(breath, from: 1, breaths(0.99, sweatBreath, count: 1)),
                          track(breath, from: 1, breaths(1.03, sweatBreath, count: 1)))
            s.overlay = sweatBeads(at: t)
        default:
            var start = 0.0
            for frame in frames(clip, bandana: bandana) {
                if start > t { break }
                s.pose = frame.pose
                s.flipped = frame.flipped
                if frame.burst { s.overlay += confetti(age: t - start) }
                start += frame.hold
            }
        }
        return s
    }

    private static func frames(_ clip: ClaudeClip, bandana: Bool) -> [Frame] {
        // Paws to the temples, band yanked taut - twice, the second one harder.
        let tighten = [Frame(.bandLoose, 0.3), Frame(.bandTight, 0.22), Frame(.bandLoose, 0.12), Frame(.bandTight, 0.3)]
        switch clip {
        case .walk:
            // Contact / down / passing, twice; then the same lap mirrored.
            let lap = [Frame(.walkA, 0.12), Frame(.walkB, 0.11), Frame(.walkC, 0.13),
                       Frame(.walkD, 0.12), Frame(.walkE, 0.11), Frame(.walkF, 0.13)]
            let mirrored = ([Frame(.walkA, 0.12)] + lap).map { Frame($0.pose, $0.hold, flipped: true) }
            return lap + mirrored + [Frame(.rest, 0.14)]
        case .tighten:
            return tighten + [Frame(.rest, 0.4)]
        case .gym:
            // 270ms per effort position, 400ms between reps; psych up first when there is
            // a band to tighten.
            var gym = [Frame(.rest, 0.3)]
            if bandana { gym += tighten }
            gym += [Frame(.pickup, 0.27), Frame(.grip, 0.27)]
            for _ in 0..<3 {
                gym += [Frame(.lift, 0.27), Frame(.strain, 0.27), Frame(.lift, 0.27), Frame(.grip, 0.4)]
            }
            gym += [Frame(.pickup, 0.27), Frame(.rest, 1.5)]
            return gym
        case .flagWave:
            var wave = [Frame(.rest, 0.2)]
            for _ in 0..<3 {
                wave += [Frame(.flagA, 0.16), Frame(.flagB, 0.16), Frame(.flagC, 0.16), Frame(.flagD, 0.16)]
            }
            wave.append(Frame(.rest, 0.45))
            return wave
        case .celebrate:
            // Two stomps and a skip; confetti fires on the impact frames.
            return [Frame(.celA, 0.22), Frame(.celB, 0.1), Frame(.celC, 0.14, burst: true), Frame(.celD, 0.12),
                    Frame(.celA, 0.16), Frame(.celB, 0.08), Frame(.celC, 0.16, burst: true), Frame(.celD, 0.12),
                    Frame(.celE, 0.14), Frame(.celF, 0.1), Frame(.rest, 0.4)]
        case .look, .jump, .idle, .sweat:
            return []
        }
    }

    /// The breath: ease out to `peak` and back, `count` times.
    private static func breaths(_ peak: Double, _ half: Double, count: Int) -> [Tween] {
        (0..<count * 2).map { Tween(Double($0) * half, half, $0.isMultiple(of: 2) ? peak : 1, .sineInOut) }
    }

    /// JS `blinkInto`. Its reopen tween has no position, so GSAP appends it to the end of
    /// the timeline: the eyes shut at each close and only reopen from `end`, in turn.
    private static func blinks(_ closes: [Double], end: Double) -> [Tween] {
        closes.map { Tween($0, 0.07, 0.12, .power2In) }
            + closes.indices.map { Tween(end + Double($0) * 0.09, 0.09, 1, .power2Out) }
    }

    /// JS `burst`: 14 flecks fanned out by index, flung up, then falling as they fade.
    private static func confetti(age: Double) -> [RigShape] {
        let tints: [UInt32] = [0x7CA4D0, 0xDD8361, 0xC87392, 0xCB708F]
        return (0..<14).compactMap { i in
            let throwFor = 0.45 + Double(i % 3) * 0.08
            let fallAt = 0.35 + Double(i % 3) * 0.06, fallFor = 0.6 + Double(i % 3) * 0.1
            guard age < fallAt + fallFor else { return nil }
            let angle = -Double.pi / 2 + Double(i % 7 - 3) * 0.32
            let reach = 42 + Double(i % 4) * 14
            let thrown = Ease.power2Out.at(min(1, age / throwFor))
            var y = sin(angle) * reach * thrown
            var opacity = 0.95
            if age >= fallAt {
                // The fall overlaps the throw; GSAP renders the newer tween last, so it owns
                // y from wherever the throw had reached.
                let p = min(1, (age - fallAt) / fallFor)
                let reached = sin(angle) * reach * Ease.power2Out.at(min(1, fallAt / throwFor))
                y = reached + (70 + Double(i % 4) * 12) * Ease.power2In.at(p)
                opacity = 0.95 * (1 - Ease.power2In.at(p))
            }
            let tall = i % 3 == 0
            let fleck = CGRect(x: 61.5, y: 10, width: tall ? 5 : 10, height: tall ? 10 : 5)
            let spin = (i % 2 == 1 ? 1 : -1) * (120 + Double(i) * 18) * thrown
            return RigShape(points: corners(fleck).map {
                gsap($0, origin: fleck.origin, rotation: spin, x: cos(angle) * reach * 1.4 * thrown, y: y)
            }, rgb: tints[i % 4], opacity: opacity)
        }
    }

    /// JS `sweatBead`: forms at the outer edge of a brow, runs down, evaporates. A bead
    /// outlives its loop, so the previous loop's are drawn too.
    private static func sweatBeads(at t: Double) -> [RigShape] {
        let loop = 2 * sweatBreath
        let current = (t / loop).rounded(.down)
        var beads: [RigShape] = []
        for k in [current - 1, current] where k >= 0 {
            for i in 0..<beadsPerLoop {
                let age = t - (k + Double(i) / Double(beadsPerLoop)) * loop
                guard age >= 0, age < 0.6 else { continue }
                let bead = CGRect(x: i % 2 == 1 ? 99 : 26, y: 8 + track(age, from: 0, [Tween(0, 0.55, 22, .power1In)]),
                                  width: 4, height: 6)
                beads.append(RigShape(points: corners(bead), rgb: 0x8FC7E8,
                                      opacity: track(age, from: 0.92, [Tween(0.38, 0.22, 0, .linear)])))
            }
        }
        return beads
    }

    /// A GSAP property over time: `from` until the first tween, then each tween eases from
    /// wherever the last one left off. No clip overlaps tweens on one property.
    private static func track(_ t: Double, from: Double, _ tweens: [Tween]) -> Double {
        var value = from
        for tween in tweens where t >= tween.at {
            value += (tween.to - value) * tween.ease.at(min(1, (t - tween.at) / tween.duration))
        }
        return value
    }
}

// MARK: - Rig

/// One instant of the rig: a pose plus the tweened transforms on top of it.
private struct Scene {
    var pose = Pose.rest
    var flipped = false
    var brows = false
    var root = CGPoint.zero
    var rigScale = (x: 1.0, y: 1.0)
    var rigRotation = 0.0
    var legScale = [1.0, 1.0, 1.0, 1.0]
    var legRotation = [0.0, 0.0, 0.0, 0.0]
    var eyeScale = 1.0
    var eyeShift = 0.0
    var shadowScale = 1.0
    var shadowOpacity = 1.0
    /// Confetti and sweat beads, drawn over the rig in view-box space.
    var overlay: [RigShape] = []

    func shapes(bandana: Bool) -> [RigShape] {
        var boxes = pose.boxes
        if !bandana {
            for part in [Part.bnd, .bndT1, .bndT2] { boxes[part] = nil }
        } else if boxes[.bnd] == nil, let eye = boxes[.le0], let body = boxes[.bdy] {
            // JS `bandBoxes`: a fixed distance above the eyes, spanning the body.
            let x = body.minX, y = eye.minY - 9, right = boxes[.bdy2]?.maxX ?? body.maxX
            boxes[.bnd] = CGRect(x: x, y: y, width: right - x, height: 7)
            boxes[.bndT1] = CGRect(x: x - 10, y: y + 3, width: 10, height: 5)
            boxes[.bndT2] = CGRect(x: x - 16, y: y + 7, width: 8, height: 5)
        }
        if brows { boxes.merge(Pose.browAngled) { $1 } }

        // Nesting from the JS SVG: root > flip > rig > part. The shadow sits in root.
        let toView = { (p: CGPoint) -> CGPoint in
            var q = gsap(p, origin: CGPoint(x: 64.5, y: 65), sx: rigScale.x, sy: rigScale.y, rotation: rigRotation)
            q.x += pose.offset.x
            q.y += pose.offset.y
            if flipped { q.x = 129 - q.x }
            return CGPoint(x: q.x + root.x, y: q.y + root.y)
        }
        let shadow = corners(CGRect(x: 20, y: 83, width: 89, height: 3)).map {
            gsap($0, origin: CGPoint(x: 64.5, y: 86), sx: shadowScale, x: root.x, y: root.y)
        }
        var out = [RigShape(points: shadow, rgb: 0x1A1A1A, opacity: 0.15 * shadowOpacity)]
        let legs: [Part] = [.leg1, .leg2, .leg3, .leg4]
        let legPivots: [Double] = [27.5, 48.5, 80.5, 101.5]
        for part in Part.allCases {
            guard let box = boxes[part], box.width > 0, box.height > 0 else { continue }
            var points = corners(box)
            if let i = legs.firstIndex(of: part) {
                points = points.map {
                    gsap($0, origin: CGPoint(x: legPivots[i], y: 86), sy: legScale[i], rotation: legRotation[i])
                }
            } else if part == .le0 || part == .re0 {
                points = points.map { gsap($0, origin: CGPoint(x: 64.5, y: 11), sy: eyeScale, x: eyeShift) }
            }
            if part.inLegLayer { points = clippedToGround(points) }
            out.append(RigShape(points: points.map(toView), rgb: part.rgb, opacity: 1))
        }
        return out + overlay
    }
}

/// GSAP's SVG transform: scale, then rotate (degrees, clockwise), both about `origin`,
/// then translate.
private func gsap(_ p: CGPoint, origin: CGPoint, sx: Double = 1, sy: Double = 1,
                  rotation: Double = 0, x: Double = 0, y: Double = 0) -> CGPoint {
    let r = rotation * .pi / 180
    let dx = Double(p.x - origin.x) * sx, dy = Double(p.y - origin.y) * sy
    return CGPoint(x: Double(origin.x) + dx * cos(r) - dy * sin(r) + x,
                   y: Double(origin.y) + dx * sin(r) + dy * cos(r) + y)
}

private func corners(_ r: CGRect) -> [CGPoint] {
    [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
     CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
}

/// The leg layer's clip: nothing below the ground line (y 86), in the rig's own space.
private func clippedToGround(_ polygon: [CGPoint]) -> [CGPoint] {
    let ground: CGFloat = 86
    var out: [CGPoint] = []
    for (i, p) in polygon.enumerated() {
        let q = polygon[(i + 1) % polygon.count]
        if p.y <= ground { out.append(p) }
        if (p.y <= ground) != (q.y <= ground) {
            let k = (ground - p.y) / (q.y - p.y)
            out.append(CGPoint(x: p.x + (q.x - p.x) * k, y: ground))
        }
    }
    return out
}

private struct Tween {
    let at: Double, duration: Double, to: Double, ease: Ease

    init(_ at: Double, _ duration: Double, _ to: Double, _ ease: Ease) {
        (self.at, self.duration, self.to, self.ease) = (at, duration, to, ease)
    }
}

/// GSAP's curves. powerN is a polynomial of degree N+1.
private enum Ease {
    case linear, sineOut, sineInOut, power1In, power1InOut, power2In, power2Out, power2InOut, power3In

    func at(_ p: Double) -> Double {
        switch self {
        case .linear: p
        case .sineOut: sin(p * .pi / 2)
        case .sineInOut: (1 - cos(p * .pi)) / 2
        case .power1In: p * p
        case .power1InOut: p < 0.5 ? 2 * p * p : 1 - 2 * (1 - p) * (1 - p)
        case .power2In: p * p * p
        case .power2Out: 1 - pow(1 - p, 3)
        case .power2InOut: p < 0.5 ? 4 * p * p * p : 1 - 4 * pow(1 - p, 3)
        case .power3In: pow(p, 4)
        }
    }
}

private struct Frame {
    let pose: Pose
    let hold: Double
    var flipped = false
    var burst = false

    init(_ pose: Pose, _ hold: Double, flipped: Bool = false, burst: Bool = false) {
        (self.pose, self.hold, self.flipped, self.burst) = (pose, hold, flipped, burst)
    }
}

/// JS `PARTS`, in draw order: legs and shins first, in the ground-clipped layer.
private enum Part: CaseIterable {
    case leg1, leg2, leg3, leg4, sh1, sh2, sh3, sh4
    case bdy, bdy2, neck, lh, rh, rf0, rf1, rf2, rf3
    case le0, le1, le2, re0, re1, re2
    case dbBar, dbL, dbR, fpole, fl0, fl1, fl2, fl3, fl4
    case bndT1, bndT2, bnd

    var inLegLayer: Bool { [.leg1, .leg2, .leg3, .leg4, .sh1, .sh2, .sh3, .sh4].contains(self) }

    var rgb: UInt32 {
        switch self {
        case .le0, .le1, .le2, .re0, .re1, .re2: 0x000000
        case .dbBar: 0x6E6A66
        case .dbL, .dbR: 0x3A3734
        case .fpole: 0x8A5A44
        case .fl0, .fl2, .fl4: 0xC1755B
        case .fl1, .fl3: 0xE8A87C
        case .bnd, .bndT1, .bndT2: 0xB4453A
        default: 0xDD775B
        }
    }
}

/// Part boxes [x, y, w, h] in the 129×86 character frame (legs meet the ground at y 86),
/// plus an offset for the whole rig. Hidden parts are omitted; a pose that carries a
/// zero-size band hides the bandana itself.
private struct Pose {
    let offset: CGPoint
    let boxes: [Part: CGRect]

    init(_ x: Double, _ y: Double, _ boxes: [Part: CGRect]) {
        offset = CGPoint(x: x, y: y)
        self.boxes = boxes
    }
}

private func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
}

// Generated from the JS `POSE` table: only the poses the clips above use.
extension Pose {
    /// JS `BROW_ANGLED`: the effort brow sweat draws over the rest pose.
    static let browAngled: [Part: CGRect] = [
        .le0: r(84, 9, 10, 6), .le1: r(94, 15, 6, 6), .le2: r(78, 15, 6, 6),
        .re0: r(33, 9, 10, 6), .re1: r(43, 15, 6, 6), .re2: r(27, 15, 6, 6),
    ]
    static let rest = Pose(0, 0, [
        .leg1: r(22, 65, 11, 21), .leg2: r(43, 65, 11, 21), .leg3: r(75, 65, 11, 21), .leg4: r(96, 65, 11, 21),
        .bdy: r(22, 0, 85, 65), .lh: r(0, 28, 22, 23), .rh: r(107, 28, 22, 23), .le0: r(86, 11, 11, 11),
        .re0: r(32, 11, 11, 11),
    ])
    static let strain = Pose(0, 0, [
        .leg1: r(22, 64, 11, 11), .leg2: r(43, 64, 11, 11), .leg3: r(75, 64, 11, 11), .leg4: r(96, 64, 11, 11),
        .sh1: r(22, 75, 11, 9), .sh2: r(43, 75, 11, 9), .sh3: r(75, 75, 11, 9), .sh4: r(96, 75, 11, 9),
        .bdy: r(22, 0, 85, 64), .lh: r(0, 32, 22, 23), .rh: r(92, -16, 22, 23), .le0: r(84, 9, 10, 6),
        .le1: r(94, 15, 6, 6), .le2: r(78, 15, 6, 6), .re0: r(33, 9, 10, 6), .re1: r(43, 15, 6, 6),
        .re2: r(27, 15, 6, 6), .dbBar: r(88, -8, 38, 7), .dbL: r(83, -18, 10, 27), .dbR: r(121, -18, 10, 27),
    ])
    static let pickup = Pose(0, 0, [
        .leg1: r(22, 65, 11, 12), .leg2: r(43, 65, 11, 12), .leg3: r(75, 65, 11, 12), .leg4: r(96, 65, 11, 12),
        .sh1: r(22, 77, 11, 9), .sh2: r(43, 77, 11, 9), .sh3: r(75, 77, 11, 9), .sh4: r(96, 77, 11, 9),
        .bdy: r(22, 12, 85, 53), .lh: r(0, 40, 22, 23), .rh: r(107, 44, 22, 23), .le0: r(86, 22, 11, 11),
        .re0: r(32, 22, 11, 11), .dbBar: r(103, 52, 38, 7), .dbL: r(98, 42, 10, 27), .dbR: r(136, 42, 10, 27),
    ])
    static let grip = Pose(0, 0, [
        .leg1: r(22, 65, 11, 13), .leg2: r(43, 65, 11, 13), .leg3: r(75, 65, 11, 13), .leg4: r(96, 65, 11, 13),
        .sh1: r(22, 78, 11, 8), .sh2: r(43, 78, 11, 8), .sh3: r(75, 78, 11, 8), .sh4: r(96, 78, 11, 8),
        .bdy: r(22, 8, 85, 57), .lh: r(0, 36, 22, 23), .rh: r(107, 38, 22, 23), .le0: r(84, 17, 10, 6),
        .le1: r(94, 23, 6, 6), .le2: r(78, 23, 6, 6), .re0: r(33, 17, 10, 6), .re1: r(43, 23, 6, 6),
        .re2: r(27, 23, 6, 6), .dbBar: r(103, 46, 38, 7), .dbL: r(98, 36, 10, 27), .dbR: r(136, 36, 10, 27),
    ])
    static let lift = Pose(0, 0, [
        .leg1: r(22, 65, 11, 16), .leg2: r(43, 65, 11, 16), .leg3: r(75, 65, 11, 16), .leg4: r(96, 65, 11, 16),
        .sh1: r(22, 81, 11, 5), .sh2: r(43, 81, 11, 5), .sh3: r(75, 81, 11, 5), .sh4: r(96, 81, 11, 5),
        .bdy: r(22, 2, 85, 63), .lh: r(0, 34, 22, 23), .rh: r(100, 10, 22, 23), .le0: r(85, 12, 10, 6),
        .le1: r(95, 18, 6, 6), .le2: r(79, 18, 6, 6), .re0: r(33, 12, 10, 6), .re1: r(43, 18, 6, 6),
        .re2: r(27, 18, 6, 6), .dbBar: r(96, 18, 38, 7), .dbL: r(91, 8, 10, 27), .dbR: r(129, 8, 10, 27),
    ])
    static let flagA = Pose(0, 0, [
        .leg1: r(22, 65, 11, 21), .leg2: r(43, 65, 11, 21), .leg3: r(75, 65, 11, 21), .leg4: r(96, 65, 11, 21),
        .bdy: r(22, 0, 85, 65), .lh: r(0, 28, 22, 23), .rh: r(92, -16, 22, 23), .le0: r(86, 11, 11, 11),
        .re0: r(32, 11, 11, 11), .fpole: r(96, -72, 5, 78), .fl0: r(101, -70, 8, 26), .fl1: r(109, -67, 8, 26),
        .fl2: r(117, -66, 8, 26), .fl3: r(125, -68, 8, 26), .fl4: r(133, -71, 8, 26),
    ])
    static let flagB = Pose(1, 1, [
        .leg1: r(22, 65, 11, 21), .leg2: r(43, 65, 11, 21), .leg3: r(75, 65, 11, 21), .leg4: r(96, 65, 11, 21),
        .bdy: r(22, 0, 85, 65), .lh: r(0, 28, 22, 23), .rh: r(95, -10, 22, 23), .le0: r(86, 11, 11, 11),
        .re0: r(32, 11, 11, 11), .fpole: r(99, -66, 5, 78), .fl0: r(104, -60, 8, 26), .fl1: r(112, -60, 8, 26),
        .fl2: r(120, -63, 8, 26), .fl3: r(128, -66, 8, 26), .fl4: r(136, -68, 8, 26),
    ])
    static let flagC = Pose(2, 0, [
        .leg1: r(22, 65, 11, 21), .leg2: r(43, 65, 11, 21), .leg3: r(75, 65, 11, 21), .leg4: r(96, 65, 11, 21),
        .bdy: r(22, 0, 85, 65), .lh: r(0, 28, 22, 23), .rh: r(99, -4, 22, 23), .le0: r(86, 11, 11, 11),
        .re0: r(32, 11, 11, 11), .fpole: r(103, -60, 5, 78), .fl0: r(108, -55, 8, 26), .fl1: r(116, -58, 8, 26),
        .fl2: r(124, -61, 8, 26), .fl3: r(132, -62, 8, 26), .fl4: r(140, -61, 8, 26),
    ])
    static let flagD = Pose(1, 1, [
        .leg1: r(22, 65, 11, 21), .leg2: r(43, 65, 11, 21), .leg3: r(75, 65, 11, 21), .leg4: r(96, 65, 11, 21),
        .bdy: r(22, 0, 85, 65), .lh: r(0, 28, 22, 23), .rh: r(95, -10, 22, 23), .le0: r(86, 11, 11, 11),
        .re0: r(32, 11, 11, 11), .fpole: r(99, -66, 5, 78), .fl0: r(104, -65, 8, 26), .fl1: r(112, -67, 8, 26),
        .fl2: r(120, -68, 8, 26), .fl3: r(128, -66, 8, 26), .fl4: r(136, -62, 8, 26),
    ])
    static let bandLoose = Pose(0, 1, [
        .leg1: r(22, 65, 11, 21), .leg2: r(43, 65, 11, 21), .leg3: r(75, 65, 11, 21), .leg4: r(96, 65, 11, 21),
        .bdy: r(22, 0, 85, 65), .lh: r(12, 2, 22, 23), .rh: r(95, 2, 22, 23), .le0: r(86, 13, 11, 11),
        .re0: r(32, 13, 11, 11), .bndT1: r(6, 12, 14, 5), .bndT2: r(-4, 18, 11, 5), .bnd: r(20, 6, 89, 8),
    ])
    static let bandTight = Pose(0, -1, [
        .leg1: r(22, 65, 11, 21), .leg2: r(43, 65, 11, 21), .leg3: r(75, 65, 11, 21), .leg4: r(96, 65, 11, 21),
        .bdy: r(22, 0, 85, 65), .lh: r(-5, 0, 22, 23), .rh: r(112, 0, 22, 23), .le0: r(84, 9, 10, 6),
        .le1: r(94, 15, 6, 6), .le2: r(78, 15, 6, 6), .re0: r(33, 9, 10, 6), .re1: r(43, 15, 6, 6),
        .re2: r(27, 15, 6, 6), .bndT1: r(4, 1, 18, 5), .bndT2: r(-8, 2, 13, 5), .bnd: r(22, 1, 85, 6),
    ])
    static let walkA = Pose(0, 0, [
        .leg1: r(19, 65, 11, 21), .leg2: r(46, 65, 11, 9), .leg3: r(78, 65, 11, 9), .leg4: r(93, 65, 11, 21),
        .sh2: r(42, 74, 11, 5), .sh3: r(81, 74, 11, 5), .bdy: r(22, 1, 85, 64), .lh: r(4, 28, 22, 23),
        .rh: r(103, 28, 22, 23), .le0: r(86, 12, 11, 11), .re0: r(32, 12, 11, 11), .bndT1: r(0, 0, 0, 0),
        .bndT2: r(0, 0, 0, 0), .bnd: r(0, 0, 0, 0),
    ])
    static let walkB = Pose(0, 3, [
        .leg1: r(22, 65, 11, 10), .leg2: r(43, 65, 11, 10), .leg3: r(75, 65, 11, 10), .leg4: r(96, 65, 11, 10),
        .sh1: r(19, 75, 11, 8), .sh2: r(39, 75, 11, 4), .sh3: r(78, 75, 11, 4), .sh4: r(99, 75, 11, 8),
        .bdy: r(22, 4, 85, 61), .lh: r(1, 31, 22, 23), .rh: r(106, 31, 22, 23), .le0: r(86, 15, 11, 11),
        .re0: r(32, 15, 11, 11), .bndT1: r(0, 0, 0, 0), .bndT2: r(0, 0, 0, 0), .bnd: r(0, 0, 0, 0),
    ])
    static let walkC = Pose(0, -3, [
        .leg1: r(25, 65, 11, 24), .leg2: r(40, 65, 11, 21), .leg3: r(72, 65, 11, 21), .leg4: r(99, 65, 11, 24),
        .bdy: r(22, 2, 85, 63), .lh: r(-2, 29, 22, 23), .rh: r(109, 29, 22, 23), .le0: r(86, 11, 11, 11),
        .re0: r(32, 11, 11, 11), .bndT1: r(0, 0, 0, 0), .bndT2: r(0, 0, 0, 0), .bnd: r(0, 0, 0, 0),
    ])
    static let walkD = Pose(0, 0, [
        .leg1: r(25, 65, 11, 9), .leg2: r(40, 65, 11, 21), .leg3: r(72, 65, 11, 21), .leg4: r(99, 65, 11, 9),
        .sh1: r(21, 74, 11, 5), .sh4: r(102, 74, 11, 5), .bdy: r(22, 1, 85, 64), .lh: r(-3, 28, 22, 23),
        .rh: r(110, 28, 22, 23), .le0: r(86, 12, 11, 11), .re0: r(32, 12, 11, 11), .bndT1: r(0, 0, 0, 0),
        .bndT2: r(0, 0, 0, 0), .bnd: r(0, 0, 0, 0),
    ])
    static let walkE = Pose(0, 3, [
        .leg1: r(22, 65, 11, 10), .leg2: r(43, 65, 11, 10), .leg3: r(75, 65, 11, 10), .leg4: r(96, 65, 11, 10),
        .sh1: r(18, 75, 11, 4), .sh2: r(40, 75, 11, 8), .sh3: r(78, 75, 11, 8), .sh4: r(99, 75, 11, 4),
        .bdy: r(22, 4, 85, 61), .lh: r(0, 31, 22, 23), .rh: r(107, 31, 22, 23), .le0: r(86, 15, 11, 11),
        .re0: r(32, 15, 11, 11), .bndT1: r(0, 0, 0, 0), .bndT2: r(0, 0, 0, 0), .bnd: r(0, 0, 0, 0),
    ])
    static let walkF = Pose(0, -3, [
        .leg1: r(19, 65, 11, 21), .leg2: r(46, 65, 11, 24), .leg3: r(78, 65, 11, 24), .leg4: r(93, 65, 11, 21),
        .bdy: r(22, 2, 85, 63), .lh: r(3, 29, 22, 23), .rh: r(104, 29, 22, 23), .le0: r(86, 11, 11, 11),
        .re0: r(32, 11, 11, 11), .bndT1: r(0, 0, 0, 0), .bndT2: r(0, 0, 0, 0), .bnd: r(0, 0, 0, 0),
    ])
    static let celA = Pose(0, 0, [
        .leg1: r(22, 71, 11, 8), .leg2: r(43, 71, 11, 8), .leg3: r(75, 65, 11, 21), .leg4: r(96, 65, 11, 21),
        .sh1: r(24, 79, 11, 7), .sh2: r(45, 79, 11, 7), .bdy: r(20, 22, 46, 49), .bdy2: r(64, 2, 45, 63),
        .neck: r(44, 8, 30, 24), .lh: r(2, 16, 22, 23), .rf0: r(100, 8, 8, 18), .rf1: r(107, 2, 8, 22),
        .rf2: r(114, 0, 8, 23), .rf3: r(121, 4, 8, 20), .le0: r(85, 14, 10, 6), .le1: r(85, 21, 6, 6),
        .le2: r(92, 21, 6, 6), .re0: r(31, 32, 10, 6), .re1: r(31, 39, 6, 6), .re2: r(38, 39, 6, 6),
        .bndT1: r(0, 0, 0, 0), .bndT2: r(0, 0, 0, 0), .bnd: r(0, 0, 0, 0),
    ])
    static let celB = Pose(0, 2, [
        .leg1: r(22, 68, 11, 16), .leg2: r(43, 68, 11, 16), .leg3: r(75, 68, 11, 16), .leg4: r(96, 68, 11, 16),
        .bdy: r(23, -2, 83, 70), .lh: r(0, 40, 22, 23), .rh: r(107, 40, 22, 23), .le0: r(86, 10, 11, 11),
        .re0: r(32, 10, 11, 11), .bndT1: r(0, 0, 0, 0), .bndT2: r(0, 0, 0, 0), .bnd: r(0, 0, 0, 0),
    ])
    static let celC = Pose(0, 0, [
        .leg1: r(22, 74, 11, 12), .leg2: r(43, 74, 11, 12), .leg3: r(75, 74, 11, 12), .leg4: r(96, 74, 11, 12),
        .bdy: r(18, 22, 93, 52), .lh: r(0, 52, 23, 20), .rh: r(106, 52, 23, 20), .le0: r(86, 34, 10, 6),
        .le1: r(86, 41, 6, 6), .le2: r(92, 41, 6, 6), .re0: r(32, 34, 10, 6), .re1: r(32, 41, 6, 6),
        .re2: r(38, 41, 6, 6), .bndT1: r(0, 0, 0, 0), .bndT2: r(0, 0, 0, 0), .bnd: r(0, 0, 0, 0),
    ])
    static let celD = Pose(0, -5, [
        .leg1: r(22, 68, 11, 17), .leg2: r(43, 68, 11, 17), .leg3: r(75, 68, 11, 17), .leg4: r(96, 68, 11, 17),
        .bdy: r(24, 0, 81, 68), .lh: r(0, 22, 22, 23), .rh: r(107, 16, 22, 23), .le0: r(86, 12, 11, 11),
        .re0: r(32, 12, 11, 11), .bndT1: r(0, 0, 0, 0), .bndT2: r(0, 0, 0, 0), .bnd: r(0, 0, 0, 0),
    ])
    static let celE = Pose(0, -3, [
        .leg1: r(22, 65, 11, 21), .leg2: r(43, 65, 11, 21), .leg3: r(75, 65, 11, 21), .leg4: r(96, 65, 11, 21),
        .bdy: r(23, 2, 83, 63), .lh: r(0, 22, 22, 23), .rh: r(107, 18, 22, 23), .le0: r(86, 13, 11, 11),
        .re0: r(32, 13, 11, 11), .bndT1: r(0, 0, 0, 0), .bndT2: r(0, 0, 0, 0), .bnd: r(0, 0, 0, 0),
    ])
    static let celF = Pose(0, 2, [
        .leg1: r(22, 66, 11, 18), .leg2: r(43, 66, 11, 18), .leg3: r(75, 66, 11, 18), .leg4: r(96, 66, 11, 18),
        .bdy: r(18, 10, 93, 56), .lh: r(0, 32, 22, 23), .rh: r(107, 32, 22, 23), .le0: r(86, 20, 11, 11),
        .re0: r(32, 20, 11, 11), .bndT1: r(0, 0, 0, 0), .bndT2: r(0, 0, 0, 0), .bnd: r(0, 0, 0, 0),
    ])
}
