import SwiftUI

@MainActor
struct BatteryGauge: View {
    let fraction: Double
    let targetFraction: Double?
    let color: Color
    var isCharging: Bool = false

    @State private var breathingGlow = false
    @State private var completionPulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ambientMotionAllowed) private var ambientMotionAllowed
    @Environment(\.preferencesStore) private var preferences

    private var accessibilityValue: String {
        let percent = Int((fraction * 100).rounded())
        if let targetFraction {
            let target = Int((targetFraction * 100).rounded())
            return L10n.format("Battery %d percent, target %d percent", percent, target)
        }
        return L10n.format("Battery %d percent", percent)
    }

    private var isPolestar: Bool { preferences.appTheme == .polestar }
    private var gaugeRadius: CGFloat { isPolestar ? 0 : 5 }

    /// Energy is actively moving into the battery. Every charging effect –
    /// particles, edge glow, breathing – settles once the pack reaches 100 %
    /// so a full bar goes quiet instead of animating forever.
    private var isEnergyFlowing: Bool { isCharging && fraction < 0.999 }
    private var isComplete: Bool { isCharging && fraction >= 0.999 }

    private var fillStyle: AnyShapeStyle {
        if isPolestar { return AnyShapeStyle(color) }
        if isEnergyFlowing {
            // Faint dark → bright ramp so the fill reads as energy pooling
            // toward the charge edge.
            return AnyShapeStyle(LinearGradient(
                colors: [color.hisDarken(0.14), color, color.hisLighten(0.20)],
                startPoint: .leading,
                endPoint: .trailing
            ))
        }
        return AnyShapeStyle(LinearGradient(
            colors: [color.opacity(0.85), color],
            startPoint: .leading,
            endPoint: .trailing
        ))
    }

    private var edgeGlowOpacity: Double {
        guard isEnergyFlowing, !isPolestar else { return 0 }
        // Reduce Motion keeps a whisper of a static glow – presence without
        // movement.
        if reduceMotion { return 0.20 }
        return breathingGlow ? 0.30 : 0.16
    }

    private var shadowOpacity: Double {
        if !isCharging { return 0.35 }
        if !isEnergyFlowing { return 0.30 }
        // Reduce Motion keeps the glow present but still. Only `startBreathing` used to consult
        // the setting, so turning it on mid-charge left this breathing anyway.
        if reduceMotion { return 0.30 }
        return breathingGlow ? 0.42 : 0.25
    }

    /// Deliberately constant. This used to breathe 2 ↔ 4 alongside the opacity, and animating a
    /// Gaussian blur radius forces an offscreen rasterization pass every frame. The breath is
    /// carried by `shadowOpacity` and `edgeGlowOpacity`, both of which the compositor can do.
    private var shadowRadius: CGFloat {
        if !isCharging { return 3.5 }
        return 3
    }

    var body: some View {
        ZStack(alignment: .leading) {
            GeometryReader { geo in
                let width = geo.size.width
                let currentWidth = max(0, width * CGFloat(min(max(fraction, 0), 1)))


                RoundedRectangle(cornerRadius: gaugeRadius, style: .continuous)
                    .fill(HisingenTheme.ink.opacity(0.08))
                    .frame(height: 9)


                RoundedRectangle(cornerRadius: gaugeRadius, style: .continuous)
                    .fill(fillStyle)
                    .frame(width: currentWidth, height: 9)
                    .shadow(color: isPolestar ? .clear : color.opacity(shadowOpacity),
                            radius: isPolestar ? 0 : shadowRadius,
                            x: 0, y: 1)
                    .hisAnimation(Motion.progress, value: fraction)
                    .hisAnimation(Motion.stateChange, value: color)


                // One-shot acknowledgement as the pack reaches 100 %: a brief
                // brightness lift, then the bar settles to static green.
                RoundedRectangle(cornerRadius: gaugeRadius, style: .continuous)
                    .fill(Color.white.opacity(completionPulse ? 0.12 : 0))
                    .frame(width: currentWidth, height: 9)
                    .allowsHitTesting(false)
                    // The acknowledgement is a brightness lift on a bar, so it carries no
                    // information a reader can see only here: the gauge's own value already says
                    // 100%. It is hidden as a shape but announced when it fires, because "the
                    // charge finished" is exactly the moment a VoiceOver reader is not watching.
                    .accessibilityHidden(true)
                    .onChange(of: completionPulse) { _, pulsing in
                        guard pulsing else { return }
                        AccessibilityNotification.Announcement(L10n.text("Charging complete")).post()
                    }


                // GPU particle flow, mounted for the gauge's whole life so a
                // stopped charge drains it gracefully instead of tearing it
                // out mid-frame.
                ChargingParticleFlow(
                    tint: color,
                    isActive: isEnergyFlowing && !reduceMotion && ambientMotionAllowed
                        && !isPolestar && currentWidth > 6
                )
                .frame(width: currentWidth, height: 9)
                .hisAnimation(Motion.progress, value: fraction)
                .allowsHitTesting(false)
                .accessibilityHidden(true)


                // Diffuse glow at the charge edge – a soft halo, not a
                // visible indicator, breathing slowly while energy flows.
                Capsule()
                    .fill(LinearGradient(
                        colors: [color.opacity(0), color.opacity(0.85)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: 12, height: 5)
                    .blur(radius: 3.5)
                    .opacity(edgeGlowOpacity)
                    .blendMode(.plusLighter)
                    .offset(x: currentWidth - 6)
                    .hisAnimation(Motion.progress, value: fraction)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)


                if let targetFraction {
                    let targetX = width * CGFloat(min(max(targetFraction, 0), 1)) - 1.5
                    RoundedRectangle(cornerRadius: isPolestar ? 0 : 1.5)
                        .fill(HisingenTheme.ink.opacity(0.75))
                        .frame(width: 3, height: 13)
                        .offset(x: targetX, y: -2)
                        .shadow(color: .black.opacity(isPolestar ? 0 : 0.2), radius: isPolestar ? 0 : 1, x: 0, y: 1)
                        .hisAnimation(Motion.progress, value: targetFraction)
                }
            }
        }
        .frame(height: 13)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityValue)
        .onAppear {
            startBreathing()
        }
        .onChange(of: isEnergyFlowing) { _, flowing in
            if flowing {
                startBreathing()
            } else {
                // A bare `Motion.interaction` here was a latent no-op and would have been a real
                // violation the moment `breathingGlow` drove anything but opacity: it bypasses
                // every Reduce Motion rule the rest of this file follows.
                withAnimation(Motion.resolveCrossfade(Motion.interaction)) {
                    breathingGlow = false
                }
            }
        }
        // Enabling Reduce Motion while a charge is running has to stop the breath already in
        // flight, not just prevent the next one from starting.
        .onChange(of: reduceMotion) { _, reduced in
            guard reduced else {
                startBreathing()
                return
            }
            withAnimation(Motion.interaction) {
                breathingGlow = false
            }
        }
        .onChange(of: isComplete) { _, complete in
            guard complete else { return }
            // Reduce Motion used to delete this acknowledgement outright, though it is opacity
            // only and carries no vestibular risk: the reader lost the one signal that the charge
            // had finished. It is shortened and crossfaded instead of removed.
            withAnimation(reduceMotion ? Motion.resolveCrossfade(Motion.pulseIn) : Motion.pulseIn) {
                completionPulse = true
            }
            Task {
                try? await Task.sleep(for: .seconds(reduceMotion ? Motion.pulseDwell / 2 : Motion.pulseDwell))
                withAnimation(reduceMotion ? Motion.resolveCrossfade(Motion.pulseOut) : Motion.pulseOut) {
                    completionPulse = false
                }
            }
        }
    }

    private func startBreathing() {
        guard isEnergyFlowing, !reduceMotion, ambientMotionAllowed else { return }
        withAnimation(Motion.chargeGlow) {
            breathingGlow = true
        }
    }
}

@MainActor
struct FuelGauge: View {
    let fraction: Double
    let color: Color

    @Environment(\.preferencesStore) private var preferences

    private var isPolestar: Bool { preferences.appTheme == .polestar }
    private var gaugeRadius: CGFloat { isPolestar ? 0 : 5 }

    private var accessibilityValue: String {
        let percent = Int((fraction * 100).rounded())
        return L10n.format("Fuel tank %d percent", percent)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            GeometryReader { geo in
                let width = geo.size.width
                let currentWidth = max(0, width * CGFloat(min(max(fraction, 0), 1)))

                RoundedRectangle(cornerRadius: gaugeRadius, style: .continuous)
                    .fill(HisingenTheme.ink.opacity(0.08))
                    .frame(height: 9)

                RoundedRectangle(cornerRadius: gaugeRadius, style: .continuous)
                    .fill(
                        isPolestar
                            ? AnyShapeStyle(color)
                            : AnyShapeStyle(LinearGradient(
                                colors: [color.opacity(0.85), color],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                    )
                    .frame(width: currentWidth, height: 9)
                    .shadow(color: isPolestar ? .clear : color.opacity(0.35),
                            radius: isPolestar ? 0 : 3,
                            x: 0, y: 1)
                    .hisAnimation(Motion.progress, value: fraction)
                    .hisAnimation(Motion.stateChange, value: color)
            }
        }
        .frame(height: 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityValue)
    }
}

@MainActor
struct DualEnergyGauge: View {
    let batteryFraction: Double?
    let fuelFraction: Double?
    let batteryColor: Color
    let fuelColor: Color
    var isCharging: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Image(systemName: isCharging ? "bolt.fill" : "battery.100percent")
                        .hisType(.micro)
                        .foregroundStyle(batteryColor)
                    Text(L10n.text("Battery"))
                        .hisType(.micro, weight: .medium)
                        .foregroundStyle(HisingenTheme.inkMuted)
                    Spacer()
                    Text(batteryFraction.map { String(format: "%.0f%%", min(max($0 * 100, 0), 100)) } ?? "–")
                        .hisType(.caption, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(HisingenTheme.ink)
                        .hisTelemetryValue(batteryFraction, reduceMotion: reduceMotion)
                }
                if let batteryFraction {
                    BatteryGauge(
                        fraction: batteryFraction,
                        targetFraction: nil,
                        color: batteryColor,
                        isCharging: isCharging
                    )
                } else {
                    UnavailableEnergyGauge()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Image(systemName: "fuelpump.fill")
                        .hisType(.micro)
                        .foregroundStyle(fuelColor)
                    Text(L10n.text("Fuel"))
                        .hisType(.micro, weight: .medium)
                        .foregroundStyle(HisingenTheme.inkMuted)
                    Spacer()
                    Text(fuelFraction.map { String(format: "%.0f%%", min(max($0 * 100, 0), 100)) } ?? "–")
                        .hisType(.caption, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(HisingenTheme.ink)
                        .hisTelemetryValue(fuelFraction, reduceMotion: reduceMotion)
                }
                if let fuelFraction {
                    FuelGauge(
                        fraction: fuelFraction,
                        color: fuelColor
                    )
                } else {
                    UnavailableEnergyGauge()
                }
            }
        }
    }
}

@MainActor
struct UnavailableEnergyGauge: View {
    @Environment(\.preferencesStore) private var preferences

    var body: some View {
        let isPolestar = preferences.appTheme == .polestar
        // The gauge is 13pt tall in its container; this placeholder was 9pt, so the row shifted
        // whenever a reading arrived or went away. It also drew the same empty track as a genuine
        // 0%, so "no data" and "empty" were visually identical.
        return ZStack {
            RoundedRectangle(cornerRadius: isPolestar ? 0 : 5, style: .continuous)
                .fill(HisingenTheme.ink.opacity(0.08))
                .frame(height: 9)
            RoundedRectangle(cornerRadius: isPolestar ? 0 : 5, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .foregroundStyle(HisingenTheme.inkMuted)
                .frame(height: 9)
        }
        .frame(height: 13)
        // `.ignore` like every sibling gauge: without it, whether VoiceOver announced anything
        // depended on what the two shapes happened to contribute implicitly.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Energy level unavailable"))
    }
}
