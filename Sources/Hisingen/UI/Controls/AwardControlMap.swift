import SwiftUI

/// Spatial overview for the wide Controls destination. It summarizes the live command targets;
/// the proven, confirmation-aware controls immediately below remain the action surface.
@MainActor
struct AwardControlMap: View {
    let state: VehicleState
    let imageCache: CarImageCache

    @Environment(\.preferencesStore) private var preferences

    private var condensed: Bool { HisingenTheme.layoutWidth < 700 }

    private var climateValue: String {
        let celsius = state.climateStatus?.requestedTemperatureCelsius
            ?? preferences.remoteClimateTemperature
        return Format.temperature(celsius: celsius, unit: preferences.temperatureUnit)
    }

    private var targetValue: String {
        state.energy.targetPercentage.map { "\($0)%" } ?? "–"
    }

    private var isLocked: Bool? { state.exteriorStatus?.isLocked }
    private var isOnline: Bool { state.connectivity?.state == .connected }
    private var factoryImageData: Data? {
        state.identity.imageData
            ?? imageCache.image(for: state.identity.vin, angle: preferences.carRenderAngle.rawValue)
            ?? imageCache.image(for: state.identity.vin)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Vehicle Controls"))
                        .hisType(size: condensed ? 25 : 30, weight: .bold)
                    Text(L10n.text("Choose a control below to send a command."))
                        .hisType(.label)
                        .foregroundStyle(HisingenTheme.inkMuted)
                }
                Spacer()
                Label(
                    isOnline ? L10n.text("Vehicle Online") : L10n.text("Vehicle status received"),
                    systemImage: isOnline ? "antenna.radiowaves.left.and.right" : "clock.arrow.circlepath"
                )
                .hisType(.label, weight: .semibold)
                .foregroundStyle(isOnline ? HisingenTheme.semanticGood : HisingenTheme.inkMuted)
            }

            HStack(spacing: 18) {
                climateInstrument
                vehicleLockInstrument
                chargeInstrument
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var climateInstrument: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(L10n.text("Climate"), systemImage: "fan.fill")
                .hisType(.label, weight: .bold)
                .foregroundStyle(HisingenTheme.accent)
            Text(climateValue)
                .hisType(size: condensed ? 35 : 42, weight: .bold)
                .monospacedDigit()
            Text(state.climateStatus?.activity.displayName ?? L10n.text("Climate unavailable"))
                .hisType(.micro, weight: .medium)
                .foregroundStyle(HisingenTheme.inkMuted)
            // No fill bar here: climate is on/off, and any capsule width would be an
            // ornament the car never reported. The value and the activity line are the truth.
        }
        .frame(width: condensed ? 128 : 150, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var vehicleLockInstrument: some View {
        VStack(spacing: 4) {
            Group {
                if let factoryImageData {
                    VehiclePresentationView(
                        identity: VehiclePresentationIdentity(
                            vin: state.identity.vin,
                            angle: preferences.carRenderAngle.rawValue
                        ),
                        imageData: factoryImageData
                    )
                } else {
                    VehicleSideProfileDoorsView(
                        openings: state.exteriorStatus?.openings ?? [],
                        model: state.model,
                        brand: state.model.brand
                    )
                }
            }
            .frame(maxWidth: .infinity, minHeight: 135, maxHeight: 155)

            Label(
                isLocked == false ? L10n.text("Unlocked") : L10n.text("Locked"),
                systemImage: isLocked == false ? "lock.open.fill" : "lock.fill"
            )
            .hisType(.body, weight: .bold)
            .foregroundStyle(isLocked == false ? HisingenTheme.semanticWarning : HisingenTheme.semanticGood)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var chargeInstrument: some View {
        VStack(alignment: .trailing, spacing: 9) {
            Label(L10n.text("Charge Target"), systemImage: "bolt.fill")
                .hisType(.label, weight: .bold)
                .foregroundStyle(HisingenTheme.accent)
            Text(targetValue)
                .hisType(size: condensed ? 35 : 42, weight: .bold)
                .monospacedDigit()
            Text(state.energy.chargingState.displayName)
                .hisType(.micro, weight: .medium)
                .foregroundStyle(HisingenTheme.inkMuted)
            // Real progress toward the target, drawn only while the car is actually charging:
            // a target is a setting, not a level, so it never fills a bar of its own.
            if state.isCharging, let target = state.energy.targetPercentage {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.10))
                        Capsule().fill(HisingenTheme.accent)
                            .frame(width: proxy.size.width * CGFloat(
                                min(max(state.energy.batteryPercentage ?? 0, 0) / Double(max(target, 1)), 1)))
                    }
                }
                .frame(height: 5)
            }
        }
        .frame(width: condensed ? 128 : 150, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }
}
