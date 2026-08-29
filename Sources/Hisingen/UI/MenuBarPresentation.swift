import AppKit

// MARK: - What the icon is saying

/// What the menu-bar / tray icon is currently communicating, in priority order.
///
/// The icon is a permanent ambient status light, so several conditions are often
/// true at once (plugged in *and* climate running *and* a command in flight).
/// The higher `rawValue` wins, so a critical warning is never buried under the
/// charging pulse.
///
/// Priority (spec): `critical warning > active remote operation > charging >
/// climate active > connected > normal`.
enum MenuBarIconState: Int, Comparable, CaseIterable, Sendable {
    /// Parked, online, nothing to report — the resting glyph.
    case normal = 0
    /// Plugged in but not drawing power.
    case connected = 1
    /// Climate / preconditioning is running.
    case climate = 2
    /// Actively charging — a slow ambient breath.
    case charging = 3
    /// Just reached the target — a brief, quiet acknowledgement.
    case chargingComplete = 4
    /// A remote command is in flight — a quicker shimmer.
    case remoteOperation = 5
    /// Alarm, charging fault, or another condition that must not be missed.
    case warning = 6

    static func < (lhs: MenuBarIconState, rhs: MenuBarIconState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Whether this state animates at all. Everything else is a still glyph.
    var isAnimated: Bool {
        switch self {
        case .charging, .remoteOperation: return true
        default: return false
        }
    }

    /// How the glyph should breathe while this state is showing.
    var pulseProfile: MenuBarPulseProfile? {
        switch self {
        case .charging:
            // Long, deep, unhurried — it runs for hours.
            return MenuBarPulseProfile(
                cycle: Motion.menuBarBreathCycle,
                frames: Motion.menuBarBreathFrames,
                minAlpha: 0.55,
                maxAlpha: 1.0
            )
        case .remoteOperation:
            // Shorter and shallower, so "working" reads differently from "charging".
            return MenuBarPulseProfile(cycle: 1.2, frames: 12, minAlpha: 0.7, maxAlpha: 1.0)
        default:
            return nil
        }
    }
}

/// One breathing cadence for the menu-bar glyph. Kept as data so the animator
/// stays a dumb frame-player and the tuning lives next to the state it belongs
/// to.
struct MenuBarPulseProfile: Equatable, Sendable {
    /// Seconds for one full inhale-and-exhale.
    var cycle: TimeInterval
    /// How many pre-rendered frames one cycle is sampled into.
    var frames: Int
    var minAlpha: CGFloat
    var maxAlpha: CGFloat

    /// Redraw interval. A 3.6 s / 18-frame charging breath ticks at 5 fps.
    var tickInterval: TimeInterval { cycle / Double(max(frames, 1)) }
}

// MARK: - Deriving the state

/// The raw signals the icon state is derived from — plain values, so the
/// priority logic is trivially testable without constructing a `VehicleState`.
struct MenuBarIconInputs: Equatable, Sendable {
    var isCharging = false
    var chargingRecentlyCompleted = false
    var chargingFault = false
    var pluggedIn = false
    var climateActive = false
    var remoteCommandInProgress = false
    var alarmTriggered = false

    /// True when anything here warrants the top-priority `warning` glyph.
    var isCritical: Bool { alarmTriggered || chargingFault }
}

extension MenuBarIconState {
    /// The winning state for a set of signals. Pure — this is the piece under test.
    static func resolve(_ inputs: MenuBarIconInputs) -> MenuBarIconState {
        var candidates: [MenuBarIconState] = [.normal]
        if inputs.pluggedIn { candidates.append(.connected) }
        if inputs.climateActive { candidates.append(.climate) }
        if inputs.isCharging { candidates.append(.charging) }
        // A completion only shows once the car has actually stopped charging.
        if inputs.chargingRecentlyCompleted && !inputs.isCharging { candidates.append(.chargingComplete) }
        if inputs.remoteCommandInProgress { candidates.append(.remoteOperation) }
        if inputs.isCritical { candidates.append(.warning) }
        return candidates.max() ?? .normal
    }

    /// Builds the signal set from a snapshot. `chargingRecentlyCompleted` is
    /// tracked by the caller (it is a transition, not a field on the state).
    static func inputs(
        for state: VehicleState?,
        remoteCommandInProgress: Bool,
        chargingRecentlyCompleted: Bool
    ) -> MenuBarIconInputs {
        guard let state else {
            return MenuBarIconInputs(remoteCommandInProgress: remoteCommandInProgress)
        }
        let activity = state.climateStatus?.activity
        let climateActive = activity == .active || activity == .heating
            || activity == .cooling || activity == .ventilating || activity == .starting
        let fault = state.chargingState == .fault || state.chargerConnection == .fault
        return MenuBarIconInputs(
            isCharging: state.isCharging,
            chargingRecentlyCompleted: chargingRecentlyCompleted,
            chargingFault: fault,
            pluggedIn: state.isPluggedIn == true,
            climateActive: climateActive,
            remoteCommandInProgress: remoteCommandInProgress,
            alarmTriggered: state.exteriorStatus?.alarmTriggered == true
        )
    }
}

// MARK: - The animator

/// Drives the `NSStatusItem` button image for the animated icon states.
///
/// Efficiency is the whole design brief here — this can run for a multi-hour
/// charge:
///
/// - **Frame cache.** One cycle is pre-rendered into `MenuBarPulseProfile.frames`
///   `NSImage`s once; each tick is then a pointer assignment, not a redraw.
/// - **Coarse cadence.** ~5 fps for the charging breath (18 frames / 3.6 s).
/// - **Paused when unseen.** The timer stops on display sleep and restarts on
///   wake; a still state carries no timer at all.
/// - **Reduce Motion.** Falls straight through to the static base image — the
///   charging *glyph* still says "charging", it just doesn't move.
@MainActor
final class MenuBarIconAnimator {
    private weak var button: NSStatusBarButton?

    private var timer: Timer?
    private var frames: [NSImage] = []
    private var frameIndex = 0

    /// The state the cached frames were built for, plus a cheap fingerprint of
    /// the source image so a changed base glyph (dark-mode flip, tint change,
    /// battery-symbol step) rebuilds them.
    private var builtState: MenuBarIconState?
    private var builtSignature: String?

    private var currentState: MenuBarIconState = .normal
    private var baseImage: NSImage?
    private var reduceMotion = false
    private var displayAsleep = false

    init(button: NSStatusBarButton?) {
        self.button = button
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(displaysDidSleep),
                           name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(displaysDidWake),
                           name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    deinit {
        // The timer's block is `[weak self]`, so it no-ops once we are gone; it
        // is not touched here because a `@MainActor` deinit is nonisolated.
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Point the icon at `state`, drawn from `image`. Safe to call on every
    /// telemetry render — it only does work when something actually changed.
    func apply(state: MenuBarIconState, image: NSImage, reduceMotion: Bool) {
        self.baseImage = image
        self.reduceMotion = reduceMotion

        let signature = Self.signature(of: image)
        let shouldAnimate = state.isAnimated && !reduceMotion && !displayAsleep

        guard shouldAnimate, let profile = state.pulseProfile else {
            stopTimer()
            frames = []
            builtState = nil
            builtSignature = nil
            currentState = state
            button?.image = image
            return
        }

        if builtState != state || builtSignature != signature {
            frames = Self.renderPulseFrames(from: image, profile: profile)
            frameIndex = 0
            builtState = state
            builtSignature = signature
            // Land on a defined frame immediately rather than waiting a tick.
            if let first = frames.first { button?.image = first }
        }

        let intervalChanged = (timer?.timeInterval ?? -1) != profile.tickInterval
        currentState = state
        if timer == nil || intervalChanged {
            restartTimer(interval: profile.tickInterval)
        }
    }

    // MARK: Timer

    private func restartTimer(interval: TimeInterval) {
        stopTimer()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common` so the breath keeps going while a menu is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !frames.isEmpty else { return }
        frameIndex = (frameIndex + 1) % frames.count
        button?.image = frames[frameIndex]
    }

    // MARK: Display sleep

    @objc private func displaysDidSleep() {
        displayAsleep = true
        stopTimer()
    }

    @objc private func displaysDidWake() {
        displayAsleep = false
        if let profile = currentState.pulseProfile, !reduceMotion, !frames.isEmpty {
            restartTimer(interval: profile.tickInterval)
        }
    }

    // MARK: Frame rendering

    /// Renders one breathing cycle as `profile.frames` images. The glyph's alpha
    /// follows a raised cosine between `minAlpha` and `maxAlpha`, so the motion
    /// eases at both extremes and there is no visible seam where the loop wraps.
    private static func renderPulseFrames(from image: NSImage, profile: MenuBarPulseProfile) -> [NSImage] {
        let size = image.size
        guard size.width > 0, size.height > 0, profile.frames > 1 else { return [image] }
        let wasTemplate = image.isTemplate

        return (0..<profile.frames).map { index in
            let phase = Double(index) / Double(profile.frames)         // 0 ..< 1
            let eased = 0.5 - 0.5 * cos(phase * 2 * .pi)                // 0 → 1 → 0, smooth
            let alpha = profile.minAlpha + (profile.maxAlpha - profile.minAlpha) * CGFloat(eased)

            let frame = NSImage(size: size)
            frame.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: size),
                       from: .zero, operation: .sourceOver, fraction: alpha)
            frame.unlockFocus()
            frame.isTemplate = wasTemplate
            return frame
        }
    }

    private static func signature(of image: NSImage) -> String {
        "\(Int(image.size.width))x\(Int(image.size.height))|\(image.isTemplate ? "t" : "c")"
    }
}
