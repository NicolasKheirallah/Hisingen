import AppKit

// MARK: - What the stage is showing

/// Identifies *what* the vehicle stage is showing: one picture of one car.
///
/// Telemetry refreshes re-render the hero card several times a minute, and they
/// all carry the same identity. That is how the stage tells "new picture"
/// (animate) apart from "same picture, fresher numbers" (do nothing).
struct VehiclePresentationIdentity: Equatable, Hashable {
    /// Angle used for the cabin photo, which has no exterior orientation.
    static let cabinAngle = -1

    let vin: String
    /// Raw value of a `CarRenderAngle`, or ``cabinAngle`` for the interior photo.
    let angle: Int

    var isCabin: Bool { angle == Self.cabinAngle }

    /// Which way this render's nose points on screen.
    ///
    /// The studio turntable holds the car nose-right in the side profile, so it
    /// stays right-ish through the front three-quarter and the overhead frame and
    /// swings away to the left in the rear three-quarter. The dead-on front and
    /// rear frames have no horizontal component at all.
    var facing: VehicleRenderFacing {
        guard let angle = CarRenderAngle(rawValue: angle) else { return .square }
        switch angle {
        case .sideProfile, .frontThreeQuarter, .overhead: return .right
        case .rearThreeQuarter: return .left
        case .frontDirect, .rearProfile: return .square
        }
    }

    /// Which side of the stage the car has to enter from to be driving forwards:
    /// the opposite side from the one it is pointing at. `+1` is the right.
    ///
    /// This is why the entrance is not simply "from the right" everywhere. A
    /// nose-right render entering from the right is reversing into place, and it
    /// fights the scale-up, which reads as the car approaching.
    var entrySide: CGFloat {
        switch facing {
        case .right: return -1
        case .left: return 1
        // No forward axis on screen either way, so keep the conventional
        // trailing-edge entry.
        case .square: return 1
        }
    }

    /// Where this angle sits in the on-screen angle strip, which is ordered the
    /// way you walk around the car (3/4 front, front, side, 3/4 rear, rear,
    /// top). The index doubles as the axis transitions travel along, so the
    /// picture always moves the same way the selection did.
    var stripIndex: Int? {
        guard let angle = CarRenderAngle(rawValue: angle) else { return nil }
        return CarRenderAngle.allCases.firstIndex(of: angle)
    }
}

/// A request to show one picture of one car.
///
/// Equality is what decides whether anything animates, so it deliberately
/// ignores the bytes and compares their count instead: `CarImageCache` hands back
/// the same buffer every time, and comparing several megabytes on every SwiftUI
/// body evaluation would cost more than the check saves. A genuinely new render
/// for the same angle arrives with a different length.
struct VehiclePresentationRequest: Equatable {
    let identity: VehiclePresentationIdentity
    let byteCount: Int
    let data: Data

    init(identity: VehiclePresentationIdentity, data: Data) {
        self.identity = identity
        self.byteCount = data.count
        self.data = data
    }

    static func == (lhs: VehiclePresentationRequest, rhs: VehiclePresentationRequest) -> Bool {
        lhs.identity == rhs.identity && lhs.byteCount == rhs.byteCount
    }
}

/// Which way a render's nose points on screen.
enum VehicleRenderFacing: Equatable {
    case left
    case right
    /// Dead-on front or rear: pointing at or away from the camera.
    case square
}

/// Which way the car appears to swing when the selected angle changes.
enum VehicleTransitionDirection: Equatable {
    /// Selection moved toward the rear of the car; the old picture exits left.
    case towardRear
    /// Selection moved toward the front; the old picture exits right.
    case towardFront
    /// No spatial relationship: cabin photo, unknown angle, or a different car.
    case none

    /// Horizontal direction the *outgoing* picture travels. The incoming
    /// picture enters from the opposite side.
    var outgoingSign: CGFloat {
        switch self {
        case .towardRear: return -1
        case .towardFront: return 1
        case .none: return 0
        }
    }

    static func between(
        _ from: VehiclePresentationIdentity,
        _ to: VehiclePresentationIdentity
    ) -> VehicleTransitionDirection {
        guard from.vin == to.vin,
              let start = from.stripIndex,
              let end = to.stripIndex,
              start != end else { return .none }
        return end > start ? .towardRear : .towardFront
    }
}

// MARK: - Accessibility

private final class ReduceMotionOverride: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    func get() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Bool?) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
}

/// The one place the reduce-motion setting is read. Everything that animates the
/// vehicle asks here instead of touching `NSWorkspace` itself, which also lets
/// tests exercise both paths.
enum VehicleMotionPreference {
    /// Test hook. `nil` means "ask the system".
    private static let overrideStore = ReduceMotionOverride()

    static var reduceMotionOverride: Bool? {
        get { overrideStore.get() }
        set { overrideStore.set(newValue) }
    }

    static var prefersReducedMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

// MARK: - Entrance bookkeeping

/// How much of an entrance a presentation has earned.
enum VehicleEntranceStyle: Equatable {
    /// Full roll-in. First time this car is shown, or a fresh visit.
    case full
    /// Shorter, smaller travel. The popover was open recently.
    case abbreviated
    /// No animation at all; the car is simply there.
    case instant
}

/// Remembers when each car last rolled in.
///
/// Hisingen lives in the menu bar, so the popover — and with it the whole
/// SwiftUI tree and every layer under it — is built from scratch every time it
/// opens. Per-view state cannot answer "have we already done this", so the
/// decision is kept here, outside the view hierarchy, keyed by VIN.
@MainActor
final class VehicleEntranceLedger {
    static let shared = VehicleEntranceLedger()

    /// Reopening this soon after an entrance is one continuous glance at the
    /// car — a mis-click, or checking the other tab. Animating again would just
    /// be noise.
    static let resumeWindow: TimeInterval = 2.5
    /// Past this the popover reads as a fresh visit and earns the full roll-in.
    static let sessionWindow: TimeInterval = 10 * 60

    private var lastEntrance: [String: Date] = [:]

    func style(for identity: VehiclePresentationIdentity, now: Date = Date()) -> VehicleEntranceStyle {
        guard let previous = lastEntrance[identity.vin] else { return .full }
        let elapsed = now.timeIntervalSince(previous)
        if elapsed < Self.resumeWindow { return .instant }
        if elapsed > Self.sessionWindow { return .full }
        return .abbreviated
    }

    /// Records that the car was presented. Called when an entrance starts, not
    /// when telemetry arrives.
    func markPresented(_ identity: VehiclePresentationIdentity, at date: Date = Date()) {
        lastEntrance[identity.vin] = date
    }

    func reset() {
        lastEntrance.removeAll()
    }
}

// MARK: - Motion curves

/// The maths behind the roll-in, kept free of Core Animation so the shapes can
/// be reasoned about and tested on their own.
enum VehicleRollCurve {
    /// Share of the travel time spent at full speed before the brakes bite.
    static let speedHoldFraction = 0.34
    /// Decay of the suspension oscillation. Higher settles sooner.
    static let settleDamping = 3.0

    /// Fraction of the distance covered at time `t` (0...1) by something that
    /// enters the frame already rolling, holds speed, then brakes smoothly to a
    /// standstill.
    ///
    /// Velocity is constant up to ``speedHoldFraction``, then follows a raised
    /// cosine to exactly zero. That makes the stop free of any jerk, which is
    /// what separates "car parking" from "element sliding in".
    static func distance(at t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        let hold = speedHoldFraction
        let total = hold + (1 - hold) / 2
        if t <= hold { return t / total }
        let braking = (t - hold) / (1 - hold)
        let covered = (1 - hold) * 0.5 * (braking + sin(.pi * braking) / .pi)
        return (hold + covered) / total
    }

    /// Suspension travel at time `s` (0...1) of the settle, normalised so that
    /// `-1` is peak compression. Starts and ends at exactly zero: one dip, one
    /// small rebound, done.
    static func settle(at s: Double) -> Double {
        guard s > 0, s < 1 else { return 0 }
        return -sin(2 * .pi * s) * exp(-settleDamping * s) / settlePeak
    }

    /// Peak of the undamped settle shape, found by sampling so the normalisation
    /// stays correct if the damping is retuned.
    private static let settlePeak = calculateSettlePeak()

    /// Keep this deliberately scalar. CodeQL's Swift instrumentation makes the
    /// equivalent `stride.map.max` expression too expensive for Xcode 16.4 to
    /// type-check while emitting the module.
    private static func calculateSettlePeak() -> Double {
        var peak = 0.0
        for sample in stride(from: 0.0, through: 1.0, by: 0.001) {
            let phase = 2.0 * Double.pi * sample
            let oscillation = sin(phase)
            let decayExponent = -settleDamping * sample
            let decay = exp(decayExponent)
            let magnitude = abs(-oscillation * decay)
            peak = max(peak, magnitude)
        }
        return peak > 0 ? peak : 1.0
    }

    /// Ride-height sway while rolling: one gentle hump that is back to zero by
    /// the time the car stops.
    static func sway(at t: Double) -> Double {
        guard t > 0, t < 1 else { return 0 }
        return sin(.pi * t)
    }

    /// Wheel rotation, in radians, for a wheel of `radius` points that has
    /// rolled `travelled` points to the left without slipping.
    ///
    /// Nothing calls this yet — the studio renders are flattened, so there are
    /// no wheel layers to turn. It exists because it is the whole of the
    /// physics: feed it the same travel the body uses and rotation necessarily
    /// starts, holds and stops with the car. See
    /// `docs/architecture/vehicle-motion.md`.
    static func wheelRotation(travelled: CGFloat, radius: CGFloat) -> CGFloat {
        guard radius > 0 else { return 0 }
        return travelled / radius
    }
}

// MARK: - Entrance motion

/// One frame of the entrance, in the vehicle layer's own coordinates.
struct VehicleEntranceSample: Equatable {
    var translation: CGPoint
    var scale: CGFloat
    var opacity: CGFloat
    /// Distance rolled so far, for wheel rotation.
    var travelled: CGFloat
}

/// A tuned entrance. Values are points and fractions of the total duration.
struct VehicleEntranceMotion: Equatable {
    var duration: CFTimeInterval
    /// Where the car starts, relative to its resting place. Signed: positive is
    /// to the right, so the sign is the side it drives in from.
    var travel: CGFloat
    var startScale: CGFloat
    /// Ride-height sway while travelling.
    var sway: CGFloat
    /// Suspension compression as it stops.
    var settle: CGFloat
    /// Share of the duration spent travelling; the rest is the settle tail.
    var travelFraction: Double
    /// When the suspension starts to compress, as a share of the duration.
    var settleStart: Double
    /// How long the car takes to fade up, as a share of the duration.
    var fadeFraction: Double

    /// The full roll-in. 660 ms reads as deliberate without making the user
    /// wait: the car has covered half its travel by 150 ms and the last 80 ms
    /// is barely-visible settling.
    static let full = VehicleEntranceMotion(
        duration: 0.66,
        travel: 124,
        startScale: 0.976,
        sway: 1.1,
        settle: 1.45,
        travelFraction: 0.86,
        settleStart: 0.74,
        fadeFraction: 0.28
    )

    /// Reopening the popover in the same sitting. Same curve, less of it, so it
    /// registers as "the car is back" rather than a replayed animation.
    static let abbreviated = VehicleEntranceMotion(
        duration: 0.40,
        travel: 44,
        startScale: 0.991,
        sway: 0.5,
        settle: 0.7,
        travelFraction: 0.84,
        settleStart: 0.72,
        fadeFraction: 0.30
    )

    /// The cabin photo has no exterior orientation, so it does not roll — it
    /// just resolves into place.
    static let cabin = VehicleEntranceMotion(
        duration: 0.30,
        travel: 0,
        startScale: 0.985,
        sway: 0,
        settle: 0,
        travelFraction: 1,
        settleStart: 1,
        fadeFraction: 0.7
    )

    /// Reduce Motion: no travel, no scale, no suspension. A short fade is all
    /// that is left, and it is short enough to read as an appearance rather
    /// than an animation.
    static let reduced = VehicleEntranceMotion(
        duration: 0.16,
        travel: 0,
        startScale: 1,
        sway: 0,
        settle: 0,
        travelFraction: 1,
        settleStart: 1,
        fadeFraction: 1
    )

    /// Resolves the entrance for a presentation. Returns `nil` when the car
    /// should simply appear.
    static func resolve(
        style: VehicleEntranceStyle,
        identity: VehiclePresentationIdentity,
        reduceMotion: Bool
    ) -> VehicleEntranceMotion? {
        switch style {
        case .instant:
            return nil
        case .full, .abbreviated:
            if reduceMotion { return .reduced }
            if identity.isCabin { return .cabin }
            var motion = style == .full ? Self.full : Self.abbreviated
            // Drive in nose-first, from whichever side that requires.
            motion.travel *= identity.entrySide
            return motion
        }
    }

    func sample(atProgress t: Double) -> VehicleEntranceSample {
        let clamped = min(max(t, 0), 1)
        let travelProgress = travelFraction > 0 ? min(clamped / travelFraction, 1) : 1
        let covered = VehicleRollCurve.distance(at: travelProgress)
        let travelled = travel * CGFloat(covered)

        let settleProgress = settleStart < 1
            ? min(max((clamped - settleStart) / (1 - settleStart), 0), 1)
            : 0

        let lift = sway * CGFloat(VehicleRollCurve.sway(at: travelProgress))
        let compression = settle * CGFloat(VehicleRollCurve.settle(at: settleProgress))

        let fade = fadeFraction > 0 ? min(clamped / fadeFraction, 1) : 1

        return VehicleEntranceSample(
            translation: CGPoint(x: travel - travelled, y: lift + compression),
            scale: startScale + (1 - startScale) * CGFloat(covered),
            opacity: CGFloat(1 - pow(1 - fade, 2)),
            travelled: travelled
        )
    }

    /// Samples the whole entrance on a fixed grid. 120 Hz means every frame of a
    /// ProMotion display gets its own sample, so linear interpolation between
    /// them is invisible while each property still follows its own curve.
    func samples() -> [VehicleEntranceSample] {
        let count = max(2, Int((duration * 120).rounded()))
        return (0...count).map { sample(atProgress: Double($0) / Double(count)) }
    }
}

// MARK: - Angle transition motion

/// A tuned angle-to-angle transition. The two pictures cross over rather than
/// swapping, which is what makes it feel like moving around the car.
struct VehicleTransitionMotion: Equatable {
    var duration: CFTimeInterval
    /// How far each picture travels. The outgoing one leaves in the direction of
    /// travel; the incoming one arrives from the opposite side.
    var offset: CGFloat
    var outgoingScale: CGFloat
    var incomingScale: CGFloat
    /// Share of the duration the outgoing picture takes to fade out.
    var fadeOutFraction: Double
    /// How long the incoming picture waits before fading up, so the two are not
    /// both at half opacity over the same pixels.
    var fadeInDelayFraction: Double
    var fadeInFraction: Double

    static func resolve(
        direction: VehicleTransitionDirection,
        reduceMotion: Bool
    ) -> VehicleTransitionMotion {
        if reduceMotion {
            return VehicleTransitionMotion(
                duration: 0.14,
                offset: 0,
                outgoingScale: 1,
                incomingScale: 1,
                fadeOutFraction: 1,
                fadeInDelayFraction: 0,
                fadeInFraction: 1
            )
        }
        return VehicleTransitionMotion(
            duration: 0.34,
            offset: direction == .none ? 0 : 26,
            outgoingScale: direction == .none ? 0.995 : 0.986,
            incomingScale: direction == .none ? 0.995 : 0.986,
            fadeOutFraction: 0.62,
            fadeInDelayFraction: 0.10,
            fadeInFraction: 0.62
        )
    }
}
