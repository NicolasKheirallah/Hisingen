import SwiftUI

@MainActor
struct VehicleHeroCard: View {
    let state: VehicleState
    let displayedStateSummary: VehicleStateSummary
    let imageCache: CarImageCache

    @Environment(\.preferencesStore) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chargingJustStarted = false

    private var features: FeatureSelection { preferences.features }
    private var cardChangeAnimation: Animation? { reduceMotion ? nil : Motion.cardChange }

    private var pillSignature: String {
        let locked = state.exteriorStatus?.isLocked
        let climate = state.climateStatus?.activity
        let engine = state.fuelSystem.isEngineRunning
        let fuel = state.fuelSystem.levelPercent
        return "\(String(describing: locked))|\(state.energy.chargingState.displayName)|\(String(describing: climate))|\(String(describing: engine))|\(String(describing: fuel))"
    }

    private var heroImageData: Data? {
        state.identity.imageData
            ?? imageCache.image(for: state.identity.vin, angle: preferences.carRenderAngle.rawValue)
            ?? imageCache.image(for: state.identity.vin)
    }

    private var showsSwedishPlateFlag: Bool {
        state.identity.accountMarket?.uppercased() == "SE"
            || state.identity.vin.uppercased().hasPrefix("YS")
            || state.identity.vin.uppercased().hasPrefix("YV")
    }

    var body: some View {
        Card {
            VStack(spacing: 10) {
                let badgePosition = preferences.vehicleModelBadgePosition
                let registrationPosition = preferences.registrationBadgePosition
                let modelIdentity = features.contains(.vehicleIdentity)
                    ? [state.identity.modelName, state.identity.modelYear]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                    : ""
                let plate = features.contains(.vehicleIdentity) ? state.identity.registrationNo : nil
                let hasPlate = plate?.isEmpty == false

                let showModelTopLeft = !modelIdentity.isEmpty && badgePosition == .topLeftOverlay
                let showModelTopRight = !modelIdentity.isEmpty && badgePosition == .topRightOverlay
                let showPlateTopLeft = hasPlate && registrationPosition == .topLeftOverlay
                let showPlateTopRight = hasPlate && registrationPosition == .topRightOverlay

                if features.contains(.vehicleImage), let imageData = heroImageData {
                    ZStack {
                        RadialGradient(
                            colors: [
                                state.isCharging ? Color.green.opacity(0.18) : Color.primary.opacity(0.06),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 40,
                            endRadius: 170
                        )

                        VehiclePresentationView(
                            identity: VehiclePresentationIdentity(
                                vin: state.identity.vin,
                                angle: preferences.carRenderAngle.rawValue
                            ),
                            imageData: imageData
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)

                        if showModelTopLeft || showModelTopRight || showPlateTopLeft || showPlateTopRight {
                            VStack {
                                HStack(alignment: .top, spacing: 6) {
                                    HStack(spacing: 6) {
                                        if showModelTopLeft {
                                            modelOverlayBadge(modelIdentity)
                                        }
                                        if let plate, showPlateTopLeft {
                                            LicensePlateBadge(
                                                plate: plate,
                                                style: .topLeftOverlay,
                                                showsSwedishFlag: showsSwedishPlateFlag
                                            )
                                        }
                                    }

                                    Spacer()

                                    HStack(spacing: 6) {
                                        if let plate, showPlateTopRight {
                                            LicensePlateBadge(
                                                plate: plate,
                                                style: .topRightOverlay,
                                                showsSwedishFlag: showsSwedishPlateFlag
                                            )
                                        }
                                        if showModelTopRight {
                                            modelOverlayBadge(modelIdentity)
                                        }
                                    }
                                }
                                .padding(.horizontal, HisingenTheme.cardPadding + 8)
                                .padding(.top, HisingenTheme.cardPadding + 8)
                                Spacer()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .padding(.horizontal, -HisingenTheme.cardPadding)
                    .padding(.top, -HisingenTheme.cardPadding)
                    .clipped()
                }

                let nickname = preferences.vehicleNickname(for: state.identity.vin)
                let greeting = features.contains(.ownerGreeting)
                    ? state.identity.ownerFirstName.map { Format.greeting($0) }
                    : nil
                let primaryTitle = greeting
                    ?? (!nickname.isEmpty ? nickname : nil)
                    ?? (modelIdentity.isEmpty ? "Hisingen" : modelIdentity)

                let showModelInline = badgePosition == .inlineHeader
                    && !modelIdentity.isEmpty
                    && modelIdentity != primaryTitle
                let showPlateInline = registrationPosition == .inlineHeader && hasPlate
                let showPlateBelow = hasPlate
                    && (registrationPosition == .belowGreeting || registrationPosition == .platePill)
                let showModelSubheadline = badgePosition == .subheadline
                    && !modelIdentity.isEmpty
                    && modelIdentity != primaryTitle

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if greeting == nil, !nickname.isEmpty {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12))
                                .foregroundStyle(HisingenTheme.accent)
                        }
                        Text(primaryTitle)
                            .font(.system(size: 17, weight: HisingenTheme.headingWeight))
                            .tracking(HisingenTheme.displayTracking * 0.3)
                            .foregroundStyle(HisingenTheme.ink)
                        Spacer()
                        if showPlateInline, let plate {
                            Text(plate.uppercased())
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .tracking(0.5)
                                .foregroundStyle(HisingenTheme.ink)
                        }
                        if showModelInline {
                            Text(modelIdentity)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(HisingenTheme.inkMuted)
                        }
                    }

                    let hasNickname = greeting != nil && !nickname.isEmpty
                    if showPlateBelow || hasNickname || showModelSubheadline {
                        HStack(alignment: .center, spacing: 8) {
                            if showPlateBelow, let plate {
                                LicensePlateBadge(
                                    plate: plate,
                                    style: registrationPosition,
                                    showsSwedishFlag: showsSwedishPlateFlag
                                )
                            }
                            if greeting != nil, !nickname.isEmpty {
                                Text(nickname)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(HisingenTheme.inkMuted)
                            }
                            Spacer()
                            if showModelSubheadline {
                                Text(modelIdentity)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(HisingenTheme.inkMuted)
                            }
                        }
                    }
                }

                statusPills

                StateSummaryChip(
                    message: displayedStateSummary.message,
                    severity: displayedStateSummary.severity
                )
                .id(displayedStateSummary.message)
                .transition(.opacity.combined(with: .move(edge: .leading)))
                .animation(cardChangeAnimation, value: displayedStateSummary.severity)

                energySummary

                HStack {
                    Image(systemName: state.isStale() ? "moon.stars.fill" : "clock.arrow.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(
                            state.isStale()
                                ? HisingenTheme.semanticWarning
                                : Color.secondary.opacity(0.6)
                        )
                    Text(state.freshnessDescription)
                        .font(.system(size: 10, weight: state.isStale() ? .semibold : .regular))
                        .foregroundStyle(
                            state.isStale()
                                ? HisingenTheme.semanticWarning
                                : Color.secondary.opacity(0.7)
                        )
                    Spacer()
                }
                .animation(cardChangeAnimation, value: state.isStale())
            }
        }
    }

    private func modelOverlayBadge(_ modelIdentity: String) -> some View {
        Text(modelIdentity)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(HisingenTheme.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.14), lineWidth: 0.6))
            .shadow(color: Color.black.opacity(0.08), radius: 4, x: 0, y: 1.5)
    }

    private var statusPills: some View {
        HStack(spacing: 6) {
            if let exterior = state.exteriorStatus, let locked = exterior.isLocked {
                Pill(
                    text: locked ? L10n.text("Locked") : L10n.text("Unlocked"),
                    color: locked ? .secondary : HisingenTheme.semanticWarning,
                    symbol: locked ? "lock.fill" : "lock.open.fill"
                )
                .transition(.scale.combined(with: .opacity))
            }
            if state.powertrain.hasElectricRange {
                Pill(
                    text: state.energy.chargingState.displayName,
                    color: HisingenTheme.statusColor(state: state.energy.chargingState),
                    symbol: state.isCharging ? "bolt.fill" : nil
                )
                .scaleEffect(chargingJustStarted ? 1.08 : 1)
                .animation(reduceMotion ? nil : Motion.stateChange, value: chargingJustStarted)
            } else if state.powertrain.isCombustionOnly {
                Pill(
                    text: state.fuelSystem.type ?? L10n.text("Combustion"),
                    color: .orange,
                    symbol: "fuelpump.fill"
                )
                .transition(.scale.combined(with: .opacity))
            }
            if state.powertrain.isHybrid {
                Pill(
                    text: state.powertrain.displayName,
                    color: .indigo,
                    symbol: "bolt.and.leaf.fill"
                )
                .transition(.scale.combined(with: .opacity))
            }
            if state.fuelSystem.isEngineRunning == true {
                Pill(
                    text: L10n.text("Engine Running"),
                    color: .orange,
                    symbol: "engine.combustion.fill"
                )
                .transition(.scale.combined(with: .opacity))
            }
            if let climate = state.climateStatus,
               climate.activity != .idle,
               climate.activity != .unknown {
                Pill(
                    text: climate.activity.displayName,
                    color: HisingenTheme.semanticActive,
                    symbol: "fan.fill"
                )
                .transition(.scale.combined(with: .opacity))
            }
            Spacer()
        }
        .animation(cardChangeAnimation, value: pillSignature)
        .onChange(of: state.isCharging) { _, charging in
            guard charging, !reduceMotion else { return }
            chargingJustStarted = true
            Task {
                try? await Task.sleep(for: .seconds(0.5))
                chargingJustStarted = false
            }
        }
    }

    @ViewBuilder
    private var energySummary: some View {
        if state.powertrain.isCombustionOnly {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.fuelSystem.levelPercent.map { String(format: "%.0f%%", $0) }
                         ?? state.fuelSystem.amountLiters.map { String(format: "%.0f L", $0) }
                         ?? "—")
                        .font(.system(size: 40, weight: HisingenTheme.displayWeight))
                        .tracking(HisingenTheme.displayTracking)
                        .monospacedDigit()
                        .foregroundStyle(HisingenTheme.ink)
                        .hisTelemetryValue(state.fuelSystem.levelPercent, reduceMotion: reduceMotion)
                    if let liters = state.fuelSystem.amountLiters {
                        Text("\(Format.fuelVolume(liters: liters, unit: preferences.fuelVolumeUnit)) \(L10n.text("remaining"))")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(HisingenTheme.inkMuted)
                    }
                }
                Spacer()
                rangeSummary(
                    value: state.fuelSystem.rangeKm,
                    title: L10n.text("Fuel Range"),
                    symbol: "fuelpump.fill"
                )
            }

            if let fuelLevel = state.fuelSystem.levelPercent {
                FuelGauge(
                    fraction: fuelLevel / 100,
                    color: HisingenTheme.fuelColor(percentage: fuelLevel)
                )
            } else {
                UnavailableEnergyGauge()
            }
        } else if state.powertrain.isHybrid {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(state.energy.batteryPercentage.map { String(format: "%.0f%%", $0) } ?? "—")
                            .font(.system(size: 34, weight: HisingenTheme.displayWeight))
                            .tracking(HisingenTheme.displayTracking)
                            .monospacedDigit()
                            .foregroundStyle(HisingenTheme.ink)
                            .hisTelemetryValue(state.energy.batteryPercentage, reduceMotion: reduceMotion)
                        if let fuel = state.fuelSystem.levelPercent {
                            Text(String(format: "· %.0f%% %@", fuel, L10n.text("fuel")))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(HisingenTheme.inkMuted)
                        }
                    }
                }
                Spacer()
                rangeSummary(
                    value: state.primaryRangeKm,
                    title: L10n.text("Total Range"),
                    symbol: "gauge.with.needle"
                )
            }

            DualEnergyGauge(
                batteryFraction: state.energy.batteryPercentage.map { $0 / 100 },
                fuelFraction: state.fuelSystem.levelPercent.map { $0 / 100 },
                batteryColor: state.energy.batteryPercentage.map {
                    HisingenTheme.batteryColor(percentage: $0, charging: state.isCharging)
                } ?? .secondary,
                fuelColor: state.fuelSystem.levelPercent.map {
                    HisingenTheme.fuelColor(percentage: $0)
                } ?? .secondary,
                isCharging: state.isCharging
            )
        } else {
            HStack(alignment: .lastTextBaseline) {
                Text(state.energy.batteryPercentage.map { String(format: "%.0f%%", $0) } ?? "—")
                    .font(.system(size: 40, weight: HisingenTheme.displayWeight))
                    .tracking(HisingenTheme.displayTracking)
                    .monospacedDigit()
                    .foregroundStyle(HisingenTheme.ink)
                    .hisTelemetryValue(state.energy.batteryPercentage, reduceMotion: reduceMotion)
                Spacer()
                rangeSummary(
                    value: state.energy.rangeKm,
                    title: L10n.text("Estimated Range"),
                    symbol: "gauge.with.needle"
                )
            }

            if let batteryLevel = state.energy.batteryPercentage {
                BatteryGauge(
                    fraction: batteryLevel / 100,
                    targetFraction: state.energy.targetPercentage.map { Double($0) / 100 },
                    color: HisingenTheme.batteryColor(
                        percentage: batteryLevel,
                        charging: state.isCharging
                    ),
                    isCharging: state.isCharging
                )
            } else {
                UnavailableEnergyGauge()
            }
        }
    }

    private func rangeSummary(value: Int?, title: String, symbol: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(value.map { Format.distance(km: $0, unit: preferences.distanceUnit) } ?? "—")
                    .font(.system(size: 16, weight: HisingenTheme.valueWeight))
                    .monospacedDigit()
                    .hisTelemetryValue(value, reduceMotion: reduceMotion)
            }
            .foregroundStyle(HisingenTheme.inkMuted)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }
}
