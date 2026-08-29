import SwiftUI

/// Central motion-token namespace — the animation counterpart of ``HisingenTheme``.
///
/// Every animated surface resolves its timing from here instead of spelling a
/// duration or spring inline, so "the same concept animates the same way" holds
/// across the whole app. Tokens are grouped by *why* the animation runs:
///
/// - **Interaction** — a direct response to the user (press, hover, navigation,
///   toggle). Short and immediate: the control acknowledges input first.
/// - **State** — the vehicle changed (charging started, doors unlocked, climate
///   on). Slightly more expressive; a critically-damped spring, never a bounce.
/// - **Ambient** — an ongoing condition (charging, climate running). Very quiet,
///   very slow, and cheap enough to run for hours.
///
/// Reduce Motion is honoured in one place: ``resolve(_:)`` returns `nil` — or a
/// short cross-fade — when the system setting (or the test override on
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

    // MARK: - Interaction animations

    /// A control reacting to the pointer or a click. Quick, no overshoot.
    static var interaction: Animation { .easeOut(duration: fast) }
    /// The settling half of an interaction (releasing a press, closing a hover).
    static var interactionIn: Animation { .easeIn(duration: fast) }
    /// Selection indicators that slide rather than teleport (tab underline, chips).
    static var selection: Animation { .spring(response: 0.30, dampingFraction: 0.86) }
    /// Disclosure groups and expand/collapse.
    static var disclosure: Animation { .easeInOut(duration: standard) }

    // MARK: - State-change animations

    /// The vehicle's state changed. Expressive but critically damped — it
    /// settles once and stops, it never rings.
    static var stateChange: Animation { .spring(response: 0.44, dampingFraction: 0.92) }
    /// Cards entering or leaving a stack.
    static var cardChange: Animation { .spring(response: 0.40, dampingFraction: 0.90) }
    /// Height / layout settling with no visible ringing.
    static var layout: Animation { .spring(response: 0.50, dampingFraction: 1.0) }

    // MARK: - Entrance / exit

    /// Quick off the mark, long gentle tail — the same deceleration the vehicle
    /// roll-in ends on (see ``VehicleTransitionMotion``), reused so every
    /// entrance in the app reads as one system.
    static var entrance: Animation { .timingCurve(0.16, 0.72, 0.20, 1.0, duration: standard) }
    /// Things leave promptly; nobody waits for an exit.
    static var exit: Animation { .easeIn(duration: fast) }

    // MARK: - Telemetry values

    /// Cross-fade between two provider readings — 61 % settling to 62 %. Slow
    /// enough to read as a settle rather than a flicker, and never implying
    /// Hisingen samples the car faster than it does.
    static var telemetry: Animation { .easeInOut(duration: 0.55) }
    /// A progress fraction moving toward a new target (rings, bars, gauges).
    static var progress: Animation { .easeInOut(duration: 0.70) }

    // MARK: - Ambient (long-running, subtle, resource-frugal)

    /// One slow breath. Autoreverses; drive a 0…1 value between two *close*
    /// visual states (opacity 0.6 ↔ 1.0, scale 1.0 ↔ 1.04) — never a large move.
    static let breathCycle: TimeInterval = 2.6
    static var breath: Animation {
        .easeInOut(duration: breathCycle).repeatForever(autoreverses: true)
    }
    /// A "live" status dot easing between two opacities. Deliberately unhurried
    /// so it reads as a heartbeat, not a blink.
    static let livePulseCycle: TimeInterval = 1.6
    static var livePulse: Animation {
        .easeInOut(duration: livePulseCycle).repeatForever(autoreverses: true)
    }
    /// Energy travelling along a charging indicator, in points per second, for a
    /// `TimelineView`-driven sweep. Slow and continuous, not a race.
    static let chargeFlowPointsPerSecond: CGFloat = 42
    /// Seconds for one charge-flow highlight to traverse a 160-pt reference bar.
    static let chargeFlowCycle: TimeInterval = 2.6
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
    /// 5 fps redraw of a 16-pt glyph — visually smooth, effectively free.
    static let menuBarBreathFrames = 18
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
    static func resolve(_ animation: Animation?) -> Animation? {
        prefersReducedMotion ? nil : animation
    }

    /// Like ``resolve(_:)`` but keeps a short opacity cross-fade under Reduce
    /// Motion, so a state change is still *noticed* — just not moved.
    static func resolveCrossfade(_ animation: Animation?) -> Animation? {
        prefersReducedMotion ? .linear(duration: micro) : animation
    }
}

// MARK: - View helpers

extension View {
    /// Standard treatment for a numeric telemetry label that should glide
    /// between provider readings instead of snapping. Pairs `.numericText()`
    /// with ``Motion/telemetry`` and collapses to an instant swap under Reduce
    /// Motion.
    ///
    /// Replaces the `.contentTransition(…) + .animation(…)` pair that was
    /// copy-pasted across the battery, range and charging labels.
    func hisTelemetryValue<V: Equatable>(_ value: V, reduceMotion: Bool) -> some View {
        contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : Motion.telemetry, value: value)
    }

    /// Applies `animation` unless Reduce Motion is on, in which case the value
    /// change still lands — just without the tween.
    func hisAnimation<V: Equatable>(_ animation: Animation?, value: V, reduceMotion: Bool) -> some View {
        self.animation(reduceMotion ? nil : animation, value: value)
    }
}

// MARK: - Pressable button style

/// Small, immediate compression plus a slight dim while a control is held — the
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
/// read `\.accessibilityReduceMotion` from the environment (a `ButtonStyle` type
/// cannot). Not `private` because it becomes the style's `Body` associated type.
struct PressableButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let scale: CGFloat
    let pressedOpacity: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .scaleEffect((reduceMotion || !configuration.isPressed) ? 1 : scale)
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .animation(reduceMotion ? .linear(duration: Motion.micro) : Motion.interaction,
                       value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// A press that compresses slightly and dims, then springs back.
    static var pressable: PressableButtonStyle { PressableButtonStyle() }

    /// A gentler press for large touch targets (command buttons).
    static var pressableSoft: PressableButtonStyle {
        PressableButtonStyle(scale: 0.985, pressedOpacity: 0.9)
    }
}
