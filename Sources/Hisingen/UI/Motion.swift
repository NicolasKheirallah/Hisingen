import AppKit
import SwiftUI

/// Central motion-token namespace – the animation counterpart of ``HisingenTheme``.
///
/// Every animated surface resolves its timing from here instead of spelling a
/// duration or spring inline, so "the same concept animates the same way" holds
/// across the whole app. Tokens are grouped by *why* the animation runs:
///
/// - **Interaction** – a direct response to the user (press, hover, navigation,
///   toggle). Short and immediate: the control acknowledges input first.
/// - **State** – the vehicle changed (charging started, doors unlocked, climate
///   on). Slightly more expressive; a critically-damped spring, never a bounce.
/// - **Ambient** – an ongoing condition (charging, climate running). Very quiet,
///   very slow, and cheap enough to run for hours.
///
/// Reduce Motion is honoured in one place: ``resolve(_:)`` returns `nil` – or a
/// short cross-fade – when the system setting (or the test override on
/// ``VehicleMotionPreference``) asks for less movement.
enum Motion {

    // MARK: - Durations (seconds)

    /// Barely-there press / status-dot acknowledgement.
    static let micro: TimeInterval = 0.11
    /// Interaction default: navigation, toggles, hover.
    static let fast: TimeInterval = 0.2
    /// The workhorse: card content changes, cross-fades, most transitions.
    static let standard: TimeInterval = 0.32
    /// Larger moves: panel height, page-level swaps.
    static let large: TimeInterval = 0.5
    /// Deliberate, meant-to-be-noticed: the manual refresh sweep.
    static let deliberate: TimeInterval = 0.66

    // MARK: - One-shot pulses

    /// Completion acknowledgement on the battery gauge: a brief brightness
    /// lift (``pulseIn``), a short dwell (``pulseDwell``), then a slower
    /// settle (``pulseOut``). Asymmetric on purpose – arrive quick, leave calm.
    static var pulseIn: Animation { .easeInOut(duration: 0.22) }
    static let pulseDwell: TimeInterval = 0.26
    static var pulseOut: Animation { .easeOut(duration: 0.34) }

    // MARK: - Interaction animations

    /// A control reacting to the pointer or a click. Quick, no overshoot.
    static var interaction: Animation { .easeOut(duration: fast) }
    /// Selection indicators that slide rather than teleport (tab underline, chips).
    static var selection: Animation { .spring(response: 0.30, dampingFraction: 0.86) }
    /// Theme / appearance cross-fades: colors and materials soften, nothing moves.
    static var theme: Animation { .easeInOut(duration: fast) }
    /// The manual refresh sweep (the 360° icon rotation).
    static var refreshSweep: Animation { .easeInOut(duration: deliberate) }

    // MARK: - State-change animations

    /// The vehicle's state changed. Expressive but critically damped – it
    /// settles once and stops, it never rings.
    static var stateChange: Animation { .spring(response: 0.44, dampingFraction: 0.92) }
    /// Cards entering or leaving a stack.
    static var cardChange: Animation { .spring(response: 0.40, dampingFraction: 0.90) }
    /// Height / layout settling with no visible ringing.
    static var layout: Animation { .spring(response: 0.50, dampingFraction: 1.0) }

    // MARK: - Entrance / exit

    /// The entrance deceleration's control points: quick off the mark, long gentle
    /// tail. One definition, because three surfaces build this curve – the SwiftUI
    /// ``entrance`` token, the vehicle roll-in's own sampler, and the AppKit mini
    /// panel's `CAMediaTimingFunction` – and retuning one of them silently desynced
    /// the other two.
    static let entranceControlPoints: (x1: Double, y1: Double, x2: Double, y2: Double) =
        (0.16, 0.72, 0.20, 1.0)

    /// The same curve for Core Animation surfaces, which cannot take a SwiftUI
    /// `Animation`.
    static var entranceTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(
            controlPoints: Float(entranceControlPoints.x1),
            Float(entranceControlPoints.y1),
            Float(entranceControlPoints.x2),
            Float(entranceControlPoints.y2)
        )
    }

    /// Quick off the mark, long gentle tail – the same deceleration the vehicle
    /// roll-in ends on, sampled from `VehicleMotion`'s braking profile in
    /// ``VehiclePresentationView`` and in the AppKit mini panel, reused so every
    /// entrance in the app reads as one system. The doc pointer here used to name
    /// `VehicleTransitionMotion`, which holds only fractions and two `.easeOut`
    /// durations and never contained this curve.
    static var entrance: Animation {
        .timingCurve(
            entranceControlPoints.x1,
            entranceControlPoints.y1,
            entranceControlPoints.x2,
            entranceControlPoints.y2,
            duration: standard
        )
    }

    // MARK: - Telemetry values

    /// Cross-fade between two provider readings – 61 % settling to 62 %. Slow
    /// enough to read as a settle rather than a flicker, and never implying
    /// Hisingen samples the car faster than it does.
    static var telemetry: Animation { .easeInOut(duration: 0.55) }
    /// A progress fraction moving toward a new target (rings, bars, gauges).
    /// Kept as a duration too: Core Animation surfaces that must stay in
    /// lockstep with a SwiftUI progress animation (e.g. the charging bar's
    /// particle clip) restate it as transaction timing.
    static let progressDuration: TimeInterval = 0.70
    static var progress: Animation { .easeInOut(duration: progressDuration) }

    // MARK: - Ambient (long-running, subtle, resource-frugal)

    /// One slow breath. Autoreverses; drive a 0…1 value between two *close*
    /// visual states (opacity 0.6 ↔ 1.0, scale 1.0 ↔ 1.04) – never a large move.
    ///
    /// Deliberately not ~5 s. §14 names a one-cycle-per-five-seconds loop as the oscillation
    /// pattern to avoid — it sits in the band the eye reads as a pulse rather than as breathing —
    /// and the charging glow ran for the whole of a multi-hour charge at 5.2 s, which is 0.192 Hz
    /// and almost exactly that figure.
    static let breathCycle: TimeInterval = 3.4
    static var breath: Animation {
        .easeInOut(duration: breathCycle).repeatForever(autoreverses: true)
    }
    /// A "live" status dot easing between two opacities. Deliberately unhurried
    /// so it reads as a heartbeat, not a blink.
    static let livePulseCycle: TimeInterval = 1.6
    static var livePulse: Animation {
        .easeInOut(duration: livePulseCycle).repeatForever(autoreverses: true)
    }
    /// The charging bar's leading-edge glow breath. A little quicker than
    /// ``breathCycle`` – it should read as "energy arriving", not idle
    /// breathing – while staying barely noticeable.
    static let chargeGlowCycle: TimeInterval = 1.9
    static var chargeGlow: Animation {
        .easeInOut(duration: chargeGlowCycle).repeatForever(autoreverses: true)
    }
    /// Continuous rotation (fan blades, sync spinner): one turn per this long.
    static let spinCycle: TimeInterval = 1.4
    static var spin: Animation {
        .linear(duration: spinCycle).repeatForever(autoreverses: false)
    }

    // MARK: - Menu-bar / tray ambient

    /// One breath of the menu-bar charging glyph. Longer than the in-panel
    /// breath because the icon is in view for hours and must never nag.
    static let menuBarBreathCycle: TimeInterval = 3.6
    /// Frames the menu-bar breath is sampled into. 18 frames over 3.6 s is a
    /// 5 fps redraw of a 16-pt glyph – visually smooth, effectively free.
    static let menuBarBreathFrames = 18
    /// The remote-operation shimmer: quicker than the charging breath because
    /// it answers a command the user just issued, and it only ever lives for
    /// the seconds until the receipt resolves.
    static let menuBarRemoteOpCycle: TimeInterval = 1.2
    static let menuBarRemoteOpFrames = 12
    /// How long the icon dwells on its "charge complete" acknowledgement before
    /// settling back to the resting plugged-in glyph.
    static let menuBarCompletionDwell: TimeInterval = 4.0

    // MARK: - Reduce Motion

    /// The single source of truth, shared with the AppKit vehicle-motion code
    /// and hookable from tests via ``VehicleMotionPreference/reduceMotionOverride``.
    static var prefersReducedMotion: Bool { VehicleMotionPreference.prefersReducedMotion }

    /// The animation to actually use: `animation` normally, `nil` when the user
    /// asked for less motion. For code that reads the flag itself (AppKit,
    /// `TimelineView` drivers, plain models).
    ///
    /// This reads `NSWorkspace` through ``prefersReducedMotion`` while the SwiftUI views read the
    /// environment, so an override set on the environment is honoured by the animation and ignored
    /// by this function, or the reverse. Views should use ``hisAnimation(_:value:)``, which resolves
    /// the same way they observe; this exists for the AppKit and driver paths that have no
    /// environment to read.
    static func resolve(_ animation: Animation?) -> Animation? {
        prefersReducedMotion ? nil : animation
    }

    /// Like ``resolve(_:)`` but keeps a short opacity cross-fade under Reduce
    /// Motion, so a state change is still *noticed* – just not moved.
    static func resolveCrossfade(_ animation: Animation?) -> Animation? {
        prefersReducedMotion ? .linear(duration: micro) : animation
    }
}

// MARK: - Ambient motion gate

/// Whether perpetual ambient motion is allowed right now.
///
/// The app offers a keep-open panel, so it can sit behind another window for hours with a charging
/// particle flow, a breathing glow and a spinning fan running at frame rate. `occlusionState`
/// appeared nowhere in the sources and nothing observed app deactivation, so ambient motion ran
/// whether or not anyone could see it. Each ambient view reads this and stops; the default is
/// `true` so a view used outside the panel behaves as before.
private struct AmbientMotionAllowedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var ambientMotionAllowed: Bool {
        get { self[AmbientMotionAllowedKey.self] }
        set { self[AmbientMotionAllowedKey.self] = newValue }
    }
}

// MARK: - View helpers

extension View {
    /// Standard treatment for a numeric telemetry label that should glide
    /// between provider readings instead of snapping. Pairs `.numericText()`
    /// with ``Motion/telemetry`` and collapses to an instant swap under Reduce
    /// Motion.
    ///
    /// `.monospacedDigit()` is part of the contract, not an extra: `.numericText()`
    /// rolls the glyphs, and a proportional face re-lays-out the string on every
    /// digit that changes width, so the value shudders as it updates. Tabular
    /// figures are what make the roll read as the number settling.
    ///
    /// Replaces the `.contentTransition(…) + .animation(…)` pair that was
    /// copy-pasted across the battery, range and charging labels.
    /// Relaxed leading for small text that wraps.
    ///
    /// The app had exactly one leading — SwiftUI's ≈1.19× default — for a 40pt hero number and a
    /// 9.5pt explanatory paragraph alike, because `.lineSpacing(` appeared nowhere in the sources.
    /// The damage is at the small end and in a localized app, where Swedish and German strings carry
    /// taller ascenders and descenders than English at the same point size. Applied wherever a view
    /// already declares that it wraps (`.fixedSize(horizontal: false, vertical: true)`), which is
    /// exactly the set of sites that can be affected.
    func hisCaptionLeading() -> some View {
        lineSpacing(HisingenTheme.captionLineSpacing)
    }

    /// Animates on a change of `value`, resolving Reduce Motion through ``Motion/resolveCrossfade``
    /// rather than ``Motion/resolve``.
    ///
    /// One intent retyped at every site drifts: the pair `animation(Motion.resolveCrossfade(x),
    /// value: y)` appeared more than fifty times and had already gone three ways, with some sites
    /// using `resolve` (a hard cut under Reduce Motion where a crossfade was meant) and others the
    /// raw token (no Reduce Motion at all). Naming the intent once is what makes the rule hold.
    func hisAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        self.animation(Motion.resolveCrossfade(animation), value: value)
    }

    /// The same, for a change that should become an instant swap rather than a crossfade under
    /// Reduce Motion — a value settling rather than a state changing.
    func hisSettlingAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        self.animation(Motion.resolve(animation), value: value)
    }

    func hisTelemetryValue<V: Equatable>(_ value: V, reduceMotion: Bool) -> some View {
        contentTransition(reduceMotion ? .identity : .numericText())
            .monospacedDigit()
            .animation(reduceMotion ? nil : Motion.telemetry, value: value)
    }

}

// MARK: - Pressable button style

/// Small, immediate compression plus a slight dim while a control is held – the
/// "every interactive control acknowledges input" primitive. Honours Reduce
/// Motion (drops the scale, keeps a faint opacity change).
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    var pressedOpacity: Double = 0.82

    func makeBody(configuration: Configuration) -> some View {
        PressableButtonBody(configuration: configuration, scale: scale, pressedOpacity: pressedOpacity)
    }
}

/// The rendered body for ``PressableButtonStyle``. A separate `View` so it can
/// read `\.accessibilityReduceMotion` and `\.isFocused` from the environment (a
/// `ButtonStyle` type cannot). Not `private` because it becomes the style's `Body`
/// associated type.
struct PressableButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let scale: CGFloat
    let pressedOpacity: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isFocused) private var isFocused

    /// The smallest comfortable target. The style used to leave the hit area entirely to the
    /// label, so the receipt dismiss button and both pager chevrons had ~9pt targets — below the
    /// 24pt the platform asks for and hard to hit with a trackpad. Baking it into the style fixes
    /// all 61 `.pressable` sites at once, which is the same reason the style exists.
    private static let minimumTarget: CGFloat = 24

    var body: some View {
        configuration.label
            .frame(minWidth: Self.minimumTarget, minHeight: Self.minimumTarget)
            .contentShape(Rectangle())
            .scaleEffect((reduceMotion || !configuration.isPressed) ? 1 : scale)
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            // Keep keyboard focus visible without wrapping the whole control in a prominent ring.
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(HisingenTheme.focusIndicator)
                    .frame(
                        width: HisingenTheme.focusIndicatorWidth,
                        height: HisingenTheme.focusIndicatorHeight
                    )
                    .opacity(isFocused ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(reduceMotion ? .linear(duration: Motion.micro) : Motion.interaction,
                       value: configuration.isPressed)
            .animation(reduceMotion ? .linear(duration: Motion.micro) : Motion.interaction,
                       value: isFocused)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// A press that compresses slightly and dims, then springs back.
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}
