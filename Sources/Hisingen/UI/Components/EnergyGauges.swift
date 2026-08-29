import SwiftUI

private struct ChargingFlowHighlight: View {
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat

    private let coreWidth: CGFloat = 38
    private let haloWidth: CGFloat = 72
    private let speed: CGFloat = Motion.chargeFlowPointsPerSecond

    private func trail(peakOpacity: Double) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(0), location: 0.0),
                .init(color: .white.opacity(peakOpacity * 0.3), location: 0.55),
                .init(color: .white.opacity(peakOpacity), location: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let travel = width + haloWidth
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let cycle = Double(travel / speed)
            let x = cycle > 0
                ? CGFloat(elapsed.truncatingRemainder(dividingBy: cycle)) * speed - haloWidth
                : -haloWidth

            ZStack(alignment: .leading) {
                trail(peakOpacity: 0.4)
                    .frame(width: haloWidth, height: height)
                    .blur(radius: 3.5)
                    .offset(x: x)
                trail(peakOpacity: 0.95)
                    .frame(width: coreWidth, height: height)
                    .offset(x: x + (haloWidth - coreWidth) / 2)
            }
        }
        .frame(width: max(0, width), height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

@MainActor
struct BatteryGauge: View {
    let fraction: Double
    let targetFraction: Double?
    let color: Color
    var isCharging: Bool = false

    @State private var breathingGlow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accessibilityValue: String {
        let percent = Int((fraction * 100).rounded())
        if let targetFraction {
            let target = Int((targetFraction * 100).rounded())
            return L10n.format("Battery %d percent, target %d percent", percent, target)
        }
        return L10n.format("Battery %d percent", percent)
    }


    private var isPolestar: Bool { PreferencesStore().appTheme == .polestar }
    private var gaugeRadius: CGFloat { isPolestar ? 0 : 5 }

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
                    .shadow(color: isPolestar ? .clear : color.opacity(isCharging ? (breathingGlow ? 0.65 : 0.25) : 0.35),
                            radius: isPolestar ? 0 : (isCharging ? (breathingGlow ? 6 : 2) : 4),
                            x: 0, y: 1)
                    .animation(Motion.progress, value: fraction)
                    .animation(.easeInOut(duration: Motion.fast), value: color)


                if isCharging && !reduceMotion && !isPolestar {
                    ChargingFlowHighlight(width: currentWidth, height: 9, cornerRadius: gaugeRadius)


                    Circle()
                        .fill(color)
                        .frame(width: 9, height: 9)
                        .blur(radius: breathingGlow ? 5 : 2.5)
                        .opacity(breathingGlow ? 0.95 : 0.55)
                        .blendMode(.plusLighter)
                        .offset(x: currentWidth - 4.5)
                        .allowsHitTesting(false)
                }


                if let targetFraction {
                    let targetX = width * CGFloat(min(max(targetFraction, 0), 1)) - 1.5
                    RoundedRectangle(cornerRadius: isPolestar ? 0 : 1.5)
                        .fill(HisingenTheme.ink.opacity(0.75))
                        .frame(width: 3, height: 13)
                        .offset(x: targetX, y: -2)
                        .shadow(color: .black.opacity(isPolestar ? 0 : 0.2), radius: isPolestar ? 0 : 1, x: 0, y: 1)
                }
            }
        }
        .frame(height: 13)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityValue)
        .onAppear {
            if isCharging && !reduceMotion && !isPolestar {
                withAnimation(Motion.breath) {
                    breathingGlow = true
                }
            }
        }
        .onChange(of: isCharging) { _, charging in
            guard !reduceMotion else { return }
            if charging {
                withAnimation(Motion.breath) {
                    breathingGlow = true
                }
            } else {
                withAnimation(Motion.interaction) {
                    breathingGlow = false
                }
            }
        }
    }
}

@MainActor
struct FuelGauge: View {
    let fraction: Double
    let color: Color

    private var isPolestar: Bool { PreferencesStore().appTheme == .polestar }
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
                    .animation(Motion.progress, value: fraction)
                    .animation(.easeInOut(duration: Motion.fast), value: color)
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

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Image(systemName: isCharging ? "bolt.fill" : "battery.100percent")
                        .font(.system(size: 9))
                        .foregroundStyle(batteryColor)
                    Text(L10n.text("Battery"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(HisingenTheme.inkMuted)
                    Spacer()
                    Text(batteryFraction.map { String(format: "%.0f%%", min(max($0 * 100, 0), 100)) } ?? "—")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(HisingenTheme.ink)
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
                        .font(.system(size: 9))
                        .foregroundStyle(fuelColor)
                    Text(L10n.text("Fuel"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(HisingenTheme.inkMuted)
                    Spacer()
                    Text(fuelFraction.map { String(format: "%.0f%%", min(max($0 * 100, 0), 100)) } ?? "—")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(HisingenTheme.ink)
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
    var body: some View {
        RoundedRectangle(cornerRadius: PreferencesStore().appTheme == .polestar ? 0 : 5, style: .continuous)
            .fill(HisingenTheme.ink.opacity(0.08))
            .frame(height: 9)
            .accessibilityLabel(L10n.text("Energy level unavailable"))
    }
}
