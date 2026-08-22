import SwiftUI

@MainActor
struct VehicleTabView: View {
    let state: VehicleState
    let cars: [CarSummary]
    let activeVin: String?
    let onSelectCar: (String) -> Void
    let error: String?
    let database: VehicleDatabase
    let reverseGeocoder: ReverseGeocoder
    let imageCache: CarImageCache

    private var features: FeatureSelection { preferences.features }

    @Environment(\.preferencesStore) private var preferences

    @State private var moreExpanded = true
    @State private var chargingJustStarted = false
    @State private var dismissedSoftwareEventIdentifier: String?
    /// Persistent charging history, prefetched off the main thread. Reading it inside
    /// `chargingCard` ran a SQLite query on every `body` evaluation.
    @State private var persistentChargingSessions: [ChargingSession] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion


    private var cardChangeAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.82)
    }
    private var cardTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .top)),
            removal: .opacity
        )
    }


    private var warningsSignature: String {
        "\(error ?? "")|\(state.dataWarnings.joined())|\(displayedStateSummary.message)"
    }

    private var displayedStateSummary: VehicleStateSummary {
        if let software = state.softwareInfo,
           software.hasActionableFailure(),
           dismissedSoftwareEventIdentifier == software.eventIdentifier,
           state.stateSummary.message == L10n.text("Software update failed") {
            return VehicleStateSummary(message: L10n.text("Software event dismissed locally"), severity: .neutral)
        }
        return state.stateSummary
    }


    private var pillSignature: String {
        let locked = state.exteriorStatus?.isLocked
        let climate = state.climateStatus?.activity
        let engine = state.isEngineRunning
        let fuel = state.fuelLevelPercent
        return "\(String(describing: locked))|\(state.chargingState.displayName)|\(String(describing: climate))|\(String(describing: engine))|\(String(describing: fuel))"
    }


    var body: some View {
        VStack(spacing: HisingenTheme.sectionSpacing) {
            multiCarChips
            heroCard
            if state.isAwaitingVehicleConfirmation {
                pendingCommandChip.transition(cardTransition)
            }
            if let card = attentionCard { card.transition(cardTransition) }
            if let card = exceptionsCard { card.transition(cardTransition) }
            if let card = chargingCard { card.transition(cardTransition) }
            if let card = fuelAndEngineCard { card.transition(cardTransition) }
            if let card = openingsCard { card.transition(cardTransition) }
            if let card = tireSchematicCard { card.transition(cardTransition) }
            if let card = locationCard { card.transition(cardTransition) }
            moreDetailsSection
        }
        .animation(cardChangeAnimation, value: warningsSignature)
        .animation(cardChangeAnimation, value: pillSignature)
        .task(id: state.vin) {
            // Prefetch persistent charging history off-main; the charging card renders from
            // this instead of querying SQLite synchronously per render pass.
            let db = database
            let vin = state.vin
            let sessions = await Task.detached(priority: .userInitiated) {
                db.recentChargingSessions(for: vin).map { $0.toDomainSession(database: db) }
            }.value
            guard !Task.isCancelled else { return }
            persistentChargingSessions = sessions
        }
        .onAppear {
            dismissedSoftwareEventIdentifier = preferences.dismissedSoftwareEventIdentifier(for: state.vin)
        }
    }

    /// Labels optimistic post-command values as unconfirmed instead of presenting them as
    /// vehicle-reported truth. Disappears when the follow-up refresh lands.
    private var pendingCommandChip: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(HisingenTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("Command sent — waiting for the vehicle"))
                    .font(.system(size: 11, weight: .semibold))
                Text(L10n.text("Values below may update once the car reports in."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(9)
        .background(HisingenTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(HisingenTheme.accent.opacity(0.25), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }

    private var multiCarChips: some View {
        guard cars.count > 1 else { return AnyView(EmptyView()) }
        let currentVin = activeVin ?? cars.first?.vin ?? ""
        return AnyView(
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(cars, id: \.vin) { car in
                        let isSelected = car.vin == currentVin
                        Button {
                            onSelectCar(car.vin)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: preferences.activeBrand == .polestar ? "bolt.car.fill" : "car.fill")
                                    .font(.system(size: 10))
                                Text(car.title)
                                    .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                isSelected ? HisingenTheme.accent.opacity(0.12) : Color.primary.opacity(0.04),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule()
                                    .stroke(isSelected ? HisingenTheme.accent : Color.primary.opacity(0.15), lineWidth: isSelected ? 1.2 : 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        )
    }


    private var moreDetailsSection: some View {
        let cards: [AnyView] = [
            vehicleIdentityCard, lightingAndFluidCard,
            climateCard, softwareCard, diagnosticsCard, errorsCard
        ].compactMap { $0 }
        guard !cards.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            DisclosureGroup(isExpanded: $moreExpanded) {
                VStack(spacing: HisingenTheme.sectionSpacing) {
                    ForEach(cards.indices, id: \.self) { cards[$0] }
                }
                .padding(.top, HisingenTheme.sectionSpacing)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(HisingenTheme.inkMuted)
                        .font(.system(size: 13, weight: HisingenTheme.headingWeight))
                        .accessibilityHidden(true)
                    Text(L10n.format("More (%d)", cards.count))
                        .font(.system(size: 13, weight: HisingenTheme.headingWeight))
                        .foregroundStyle(HisingenTheme.ink)
                    Spacer()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.format("More, %d sections", cards.count))
                .accessibilityHint(L10n.text("Vehicle identity, tyres, climate, location, software, and diagnostics"))
            }
            .disclosureGroupStyle(WholeRowDisclosureStyle())
            .padding(HisingenTheme.cardPadding)
            .background(HisingenTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HisingenTheme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HisingenTheme.cornerRadius, style: .continuous)
                    .stroke(HisingenTheme.hairline, lineWidth: HisingenTheme.cardBorderWidth)
            )
        )
    }


    private var heroImageData: Data? {
        state.imageData
            ?? imageCache.image(for: state.vin, angle: preferences.carRenderAngle.rawValue)
            ?? imageCache.image(for: state.vin)
    }

    @ViewBuilder
    private func licensePlateBadge(_ plate: String, style: RegistrationNumberBadgePosition) -> some View {
        switch style {
        case .platePill:
            HStack(spacing: 4) {
                if state.accountMarket?.uppercased() == "SE" || state.vin.uppercased().hasPrefix("YS") || state.vin.uppercased().hasPrefix("YV") {
                    Text("🇸🇪")
                        .font(.system(size: 9))
                }
                Text(plate.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(HisingenTheme.ink)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.primary.opacity(0.18), lineWidth: 0.8)
            )
        case .belowGreeting, .inlineHeader:
            Text(plate.uppercased())
                .font(.system(size: 13, weight: HisingenTheme.valueWeight))
                .monospaced()
                .foregroundStyle(HisingenTheme.ink)
        case .topRightOverlay, .topLeftOverlay:
            HStack(spacing: 4) {
                if state.accountMarket?.uppercased() == "SE" || state.vin.uppercased().hasPrefix("YS") || state.vin.uppercased().hasPrefix("YV") {
                    Text("🇸🇪")
                        .font(.system(size: 9))
                }
                Text(plate.uppercased())
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(HisingenTheme.ink)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().stroke(Color.primary.opacity(0.14), lineWidth: 0.6)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 4, x: 0, y: 1.5)
        case .hidden:
            EmptyView()
        }
    }

    private var heroCard: some View {
        Card {
            VStack(spacing: 10) {

                let badgePosition = preferences.vehicleModelBadgePosition
                let regPosition = preferences.registrationBadgePosition
                let modelIdentity = features.contains(.vehicleIdentity)
                    ? [state.modelName, state.modelYear].compactMap { $0 }.joined(separator: " · ") : ""
                let plate = features.contains(.vehicleIdentity) ? state.registrationNo : nil

                let showModelTopLeft = !modelIdentity.isEmpty && badgePosition == .topLeftOverlay
                let showModelTopRight = !modelIdentity.isEmpty && badgePosition == .topRightOverlay
                let showPlateTopLeft = (plate != nil && !plate!.isEmpty) && regPosition == .topLeftOverlay
                let showPlateTopRight = (plate != nil && !plate!.isEmpty) && regPosition == .topRightOverlay

                if features.contains(.vehicleImage), let imageData = heroImageData {
                    ZStack {

                        RadialGradient(
                            colors: [
                                (state.isCharging ? Color.green.opacity(0.18) : Color.primary.opacity(0.06)),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 40,
                            endRadius: 170
                        )

                        VehiclePresentationView(
                            identity: VehiclePresentationIdentity(
                                vin: state.vin,
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
                                            Text(modelIdentity)
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(HisingenTheme.ink)
                                                .padding(.horizontal, 9)
                                                .padding(.vertical, 4.5)
                                                .background(.ultraThinMaterial, in: Capsule())
                                                .overlay(
                                                    Capsule().stroke(Color.primary.opacity(0.14), lineWidth: 0.6)
                                                )
                                                .shadow(color: Color.black.opacity(0.08), radius: 4, x: 0, y: 1.5)
                                        }
                                        if let plate, showPlateTopLeft {
                                            licensePlateBadge(plate, style: .topLeftOverlay)
                                        }
                                    }

                                    Spacer()

                                    HStack(spacing: 6) {
                                        if let plate, showPlateTopRight {
                                            licensePlateBadge(plate, style: .topRightOverlay)
                                        }
                                        if showModelTopRight {
                                            Text(modelIdentity)
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(HisingenTheme.ink)
                                                .padding(.horizontal, 9)
                                                .padding(.vertical, 4.5)
                                                .background(.ultraThinMaterial, in: Capsule())
                                                .overlay(
                                                    Capsule().stroke(Color.primary.opacity(0.14), lineWidth: 0.6)
                                                )
                                                .shadow(color: Color.black.opacity(0.08), radius: 4, x: 0, y: 1.5)
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


                let nickname = preferences.vehicleNickname(for: state.vin)
                let greeting = features.contains(.ownerGreeting)
                    ? state.ownerFirstName.map { Format.greeting($0) } : nil
                let primaryTitle = greeting
                    ?? (!nickname.isEmpty ? nickname : nil)
                    ?? (modelIdentity.isEmpty ? "Hisingen" : modelIdentity)

                let showModelInline = (badgePosition == .inlineHeader) && !modelIdentity.isEmpty && modelIdentity != primaryTitle
                let showPlateInline = (regPosition == .inlineHeader) && (plate != nil && !plate!.isEmpty)
                let showPlateBelow = (plate != nil && !plate!.isEmpty) && (regPosition == .belowGreeting || regPosition == .platePill)
                let showModelSubheadline = (badgePosition == .subheadline) && !modelIdentity.isEmpty && modelIdentity != primaryTitle

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
                                licensePlateBadge(plate, style: regPosition)
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


                HStack(spacing: 6) {
                    if let ext = state.exteriorStatus, let locked = ext.isLocked {
                        Pill(
                            text: locked ? L10n.text("Locked") : L10n.text("Unlocked"),
                            color: locked ? .secondary : HisingenTheme.semanticWarning,
                            symbol: locked ? "lock.fill" : "lock.open.fill"
                        )
                        .transition(.scale.combined(with: .opacity))
                    }
                    if state.powertrain.hasElectricRange {
                        let statusColor = HisingenTheme.statusColor(state: state.chargingState)
                        Pill(
                            text: state.chargingState.displayName,
                            color: statusColor,
                            symbol: state.isCharging ? "bolt.fill" : nil
                        )
                        .scaleEffect(chargingJustStarted ? 1.14 : 1.0)
                        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.45), value: chargingJustStarted)
                    } else if state.powertrain.isCombustionOnly {
                        Pill(
                            text: state.fuelType ?? L10n.text("Combustion"),
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
                    if state.isEngineRunning == true {
                        Pill(
                            text: L10n.text("Engine Running"),
                            color: .orange,
                            symbol: "engine.combustion.fill"
                        )
                        .transition(.scale.combined(with: .opacity))
                    }
                    if let climate = state.climateStatus, climate.activity != .idle && climate.activity != .unknown {
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        chargingJustStarted = false
                    }
                }


                let summary = displayedStateSummary
                StateSummaryChip(message: summary.message, severity: summary.severity)
                    .id(summary.message)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                    .animation(cardChangeAnimation, value: summary.severity)


                if state.powertrain.isCombustionOnly {
                    HStack(alignment: .lastTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(state.fuelLevelPercent.map { String(format: "%.0f%%", $0) } ?? (state.fuelAmountLiters.map { String(format: "%.0f L", $0) } ?? "—"))
                                .font(.system(size: 40, weight: HisingenTheme.displayWeight))
                                .tracking(HisingenTheme.displayTracking)
                                .monospacedDigit()
                                .foregroundStyle(HisingenTheme.ink)
                                .contentTransition(reduceMotion ? .identity : .numericText())
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: state.fuelLevelPercent)
                            if let liters = state.fuelAmountLiters {
                                Text("\(Format.fuelVolume(liters: liters, unit: preferences.fuelVolumeUnit)) \(L10n.text("remaining"))")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(HisingenTheme.inkMuted)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            HStack(spacing: 4) {
                                Image(systemName: "fuelpump.fill")
                                    .font(.system(size: 11))
                                Text(state.fuelRangeKm.map { Format.distance(km: $0, unit: preferences.distanceUnit) } ?? "—")
                                    .font(.system(size: 16, weight: HisingenTheme.valueWeight))
                                    .monospacedDigit()
                                    .contentTransition(reduceMotion ? .identity : .numericText())
                                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: state.fuelRangeKm)
                            }
                            .foregroundStyle(HisingenTheme.inkMuted)
                            Text(L10n.text("Fuel Range"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    if let fuelLevel = state.fuelLevelPercent {
                        FuelGauge(
                            fraction: fuelLevel / 100.0,
                            color: HisingenTheme.fuelColor(percentage: fuelLevel)
                        )
                    } else {
                        UnavailableEnergyGauge()
                    }
                } else if state.powertrain.isHybrid {
                    HStack(alignment: .lastTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(state.batteryPercentage.map { String(format: "%.0f%%", $0) } ?? "—")
                                    .font(.system(size: 34, weight: HisingenTheme.displayWeight))
                                    .tracking(HisingenTheme.displayTracking)
                                    .monospacedDigit()
                                    .foregroundStyle(HisingenTheme.ink)
                                    .contentTransition(reduceMotion ? .identity : .numericText())
                                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: state.batteryPercentage)
                                if let fuel = state.fuelLevelPercent {
                                    Text(String(format: "· %.0f%% %@", fuel, L10n.text("fuel")))
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(HisingenTheme.inkMuted)
                                }
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            HStack(spacing: 4) {
                                Image(systemName: "gauge.with.needle")
                                    .font(.system(size: 11))
                                Text(state.primaryRangeKm.map { Format.distance(km: $0, unit: preferences.distanceUnit) } ?? "—")
                                    .font(.system(size: 16, weight: HisingenTheme.valueWeight))
                                    .monospacedDigit()
                                    .contentTransition(reduceMotion ? .identity : .numericText())
                                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: state.primaryRangeKm)
                            }
                            .foregroundStyle(HisingenTheme.inkMuted)
                            Text(L10n.text("Total Range"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    DualEnergyGauge(
                        batteryFraction: state.batteryPercentage.map { $0 / 100.0 },
                        fuelFraction: state.fuelLevelPercent.map { $0 / 100.0 },
                        batteryColor: state.batteryPercentage.map { HisingenTheme.batteryColor(percentage: $0, charging: state.isCharging) } ?? .secondary,
                        fuelColor: state.fuelLevelPercent.map { HisingenTheme.fuelColor(percentage: $0) } ?? .secondary,
                        isCharging: state.isCharging
                    )
                } else {
                    HStack(alignment: .lastTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(state.batteryPercentage.map { String(format: "%.0f%%", $0) } ?? "—")
                                .font(.system(size: 40, weight: HisingenTheme.displayWeight))
                                .tracking(HisingenTheme.displayTracking)
                                .monospacedDigit()
                                .foregroundStyle(HisingenTheme.ink)
                                .contentTransition(reduceMotion ? .identity : .numericText())
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: state.batteryPercentage)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            HStack(spacing: 4) {
                                Image(systemName: "gauge.with.needle")
                                    .font(.system(size: 11))
                                Text(state.rangeKm.map { Format.distance(km: $0, unit: preferences.distanceUnit) } ?? "—")
                                    .font(.system(size: 16, weight: HisingenTheme.valueWeight))
                                    .monospacedDigit()
                                    .contentTransition(reduceMotion ? .identity : .numericText())
                                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: state.rangeKm)
                            }
                            .foregroundStyle(HisingenTheme.inkMuted)
                            Text(L10n.text("Estimated Range"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    let target = state.chargeTargetPercentage.map { Double($0) / 100 }
                    if let batteryLevel = state.batteryPercentage {
                        BatteryGauge(
                            fraction: batteryLevel / 100,
                            targetFraction: target,
                            color: HisingenTheme.batteryColor(percentage: batteryLevel, charging: state.isCharging),
                            isCharging: state.isCharging
                        )
                    } else {
                        UnavailableEnergyGauge()
                    }
                }


                HStack {
                    Image(systemName: state.isStale() ? "moon.stars.fill" : "clock.arrow.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(state.isStale() ? HisingenTheme.semanticWarning : Color.secondary.opacity(0.6))
                    Text(state.freshnessDescription)
                        .font(.system(size: 10, weight: state.isStale() ? .semibold : .regular))
                        .foregroundStyle(state.isStale() ? HisingenTheme.semanticWarning : Color.secondary.opacity(0.7))
                    Spacer()
                }
                .animation(cardChangeAnimation, value: state.isStale())
            }
        }
    }


    private var chargingHeadline: String? {
        guard features.contains(.chargingDetails) else { return nil }
        if state.isCharging {
            var parts: [String] = [state.chargingState.displayName]
            if let watts = state.chargingPowerWatts, watts > 0 { parts.append(Format.kilowatts(watts: watts)) }
            if state.chargingType != .unknown, state.chargingType != .none { parts.append(state.chargingType.displayName) }
            return parts.joined(separator: " · ")
        }
        switch state.chargerConnection {
        case .connected: return L10n.text("Connected · Not charging")
        case .fault: return L10n.text("Charger fault")
        case .disconnected: return L10n.text("Not connected")
        case .unknown: return nil
        }
    }

    private var chargingReadyLine: String? {
        guard state.isCharging,
              let formattedCompletion = state.formattedCompletionTime,
              let minutes = state.estimatedChargingTimeToFullMinutes, minutes > 0 else { return nil }
        return L10n.format("Ready at %@ · %@ remaining", formattedCompletion, Format.shortDuration(minutes: minutes))
    }

    private var chargingSecondaryLine: String? {
        guard state.isCharging else { return nil }
        var parts: [String] = []
        if let rate = state.formattedChargingRate(unit: preferences.distanceUnit) { parts.append(rate) }
        if let battery = state.batteryPercentage,
           let chargeTargetPercentage = state.chargeTargetPercentage,
           battery < Double(chargeTargetPercentage) {
            let targetPct = Double(chargeTargetPercentage)
            let missingPct = max(0, targetPct - battery)
            let referenceCapacity = preferences.vehicleSpecificationOverride(for: state.vin)?.usableBatteryCapacityKwh
                ?? state.factoryUsableBatteryCapacityKwh
            let missingKwh = (missingPct / 100.0) * referenceCapacity
            let estimatedCost = missingKwh * preferences.electricityPricePerKwh
            if estimatedCost > 0 {
                parts.append("≈" + String(format: "%.2f %@", estimatedCost, preferences.currencySymbol) + " " + L10n.text("to target"))
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// Stable identifiers for the Charging card's detail rows, reordered from Settings →
    /// Features. Identifiers absent from the saved order keep their natural position after
    /// the ordered ones, so a partial or stale preference can never drop a row.
    private let chargingStatIdentifiers: [String] = [
        "connection", "type", "draw", "limit", "voltage", "target",
        "powerModule", "timeToTarget", "timeToMinSoc", "avgConsumption", "avgSinceCharge", "energySinceCharge",
    ]

    private var chargingDetailRows: [KVRow] {
        let tagged = chargingDetailTagged()
        let order = preferences.chargingStatOrder
        return tagged.enumerated()
            .sorted { lhs, rhs in
                let li = order.firstIndex(of: lhs.element.id) ?? Int.max
                let ri = order.firstIndex(of: rhs.element.id) ?? Int.max
                if li != ri { return li < ri }
                return lhs.offset < rhs.offset
            }
            .map { $0.element.row }
    }

    private func chargingDetailTagged() -> [(id: String, row: KVRow)] {
        var rows: [(id: String, row: KVRow)] = []
        if features.contains(.chargingDetails) {
            if state.chargerConnection != .unknown {
                rows.append(("connection", KVRow(L10n.text("Charger Connection"), state.chargerConnection.displayName,
                                  symbol: "powerplug.fill", valueWarning: state.chargerConnection == .fault)))
            }
            if state.chargingType != .unknown, state.chargingType != .none {
                rows.append(("type", KVRow(L10n.text("Charging Type"), state.chargingType.displayName, symbol: "bolt.circle")))
            }
            if let drawAmps = state.chargingCurrentAmps, drawAmps > 0 {
                rows.append(("draw", KVRow(L10n.text("Current Draw"), "\(drawAmps) A", symbol: "waveform.path.ecg", info: L10n.text("Live Telematics. Active AC or DC current drawn from the EVSE charger."))))
            }
            if let limitAmps = state.chargingCurrentLimitAmps, limitAmps > 0 {
                rows.append(("limit", KVRow(L10n.text("Current Limit"), "\(limitAmps) A", symbol: "gauge.with.dots.needle.bottom.100percent", info: L10n.text("User Setting. Max AC charging current limit configured in vehicle charging settings."))))
            }
            if let volts = state.chargingVoltageVolts, volts > 0 {
                rows.append(("voltage", KVRow(L10n.text("Voltage"), "\(volts) V", symbol: "bolt.fill", info: L10n.text("Live Telematics. Active AC input voltage or DC bus voltage measured by onboard charger."))))
            }
            if let target = state.chargeTargetPercentage {
                rows.append(("target", KVRow(L10n.text("Target Limit"), "\(target)%", symbol: "target", info: L10n.text("User Setting. Selected high-voltage battery charge limit target."))))
            }
        }
        if features.contains(.batteryDiagnostics), let diag = state.batteryDiagnostics {
            if diag.chargerPowerState != .unknown {
                rows.append(("powerModule", KVRow(L10n.text("Power Module"), diag.chargerPowerState.displayName,
                                  symbol: "batteryblock", valueWarning: diag.chargerPowerState == .fault)))
            }
            if let m = diag.timeToTargetMinutes {
                rows.append(("timeToTarget", KVRow(L10n.text("Time to Target"), Format.shortDuration(minutes: m), symbol: "timer", info: L10n.text("Vehicle Dynamic Calculation. Estimated time remaining until the high-voltage battery reaches the configured charge target."))))
            }
            if let minM = diag.timeToMinimumSOCMinutes {
                rows.append(("timeToMinSoc", KVRow(L10n.text("Time to Min SOC"), Format.shortDuration(minutes: minM), symbol: "battery.50percent", info: L10n.text("Vehicle Dynamic Calculation. Estimated time to reach minimum operating state of charge."))))
            }
            if let v = diag.averageConsumption {
                rows.append(("avgConsumption", KVRow(L10n.text("Avg Consumption"), Format.energyConsumption(kwhPer100Km: v, unit: preferences.energyConsumptionUnit), symbol: "chart.line.uptrend.xyaxis", info: L10n.text("Vehicle Calculation. Lifetime or long-term average energy consumption from trip computer."))))
            }
            if let avgSince = diag.averageConsumptionSinceCharge {
                rows.append(("avgSinceCharge", KVRow(L10n.text("Avg Since Last Charge"), Format.energyConsumption(kwhPer100Km: avgSince, unit: preferences.energyConsumptionUnit), symbol: "chart.line.uptrend.xyaxis", info: L10n.text("Vehicle Calculation. Average electric consumption recorded since the vehicle was last unplugged."))))
            }
            if let wh = diag.energyUsedSinceChargeWh {
                rows.append(("energySinceCharge", KVRow(L10n.text("Energy Since Charge"), String(format: "%.1f kWh", wh / 1_000), symbol: "leaf.fill", info: L10n.text("Vehicle Calculation. Total high-voltage energy consumed by powertrain and HVAC since the last charge."))))
            }
        }
        return rows
    }

    private var chargingReadyDate: Date? {
        guard let minutes = state.estimatedChargingTimeToFullMinutes, minutes > 0 else { return nil }
        // Anchor at the fetch time, not render time: recomputing from `Date()` made the
        // projected endpoint drift forward on every re-render between refreshes.
        return state.fetchedAt.addingTimeInterval(TimeInterval(minutes * 60))
    }

    private var chargingCard: AnyView? {
        guard state.powertrain.hasElectricRange || state.isCharging || state.chargerConnection != .disconnected else { return nil }
        guard features.contains(.chargingDetails) || features.contains(.batteryDiagnostics) else { return nil }
        let headline = chargingHeadline
        let ready = chargingReadyLine
        let secondary = chargingSecondaryLine
        let details = chargingDetailRows
        let activeSamples: [ChargingSample] = {
            if !state.chargingSamples.isEmpty { return state.chargingSamples }
            if state.isCharging, let pct = state.batteryPercentage {
                return [ChargingSample(timestamp: state.fetchedAt, batteryPercentage: pct, powerWatts: state.chargingPowerWatts)]
            }
            return []
        }()
        let allChargingSessions = !state.chargingSessions.isEmpty ? state.chargingSessions : persistentChargingSessions

        guard state.powertrain.hasElectricRange, (headline != nil || !details.isEmpty || !activeSamples.isEmpty
            || !allChargingSessions.isEmpty) else { return nil }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(
                    symbol: "bolt.fill",
                    title: L10n.text("Charging"),
                    color: .green,
                    isSemantic: true,
                    isPulsing: state.isCharging
                )

                if let headline {
                    Text(headline)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(state.isCharging ? HisingenTheme.semanticGood : .primary)
                        .id(headline)
                        .transition(.opacity)
                }
                if let ready {
                    Text(ready)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .id(ready)
                        .transition(.opacity)
                }
                if let secondary {
                    Text(secondary)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .id(secondary)
                        .transition(.opacity)
                }
                if !activeSamples.isEmpty {
                    ChargingCurveView(
                        samples: activeSamples,
                        targetPercentage: state.chargeTargetPercentage,
                        readyDate: chargingReadyDate,
                        isLive: state.isCharging,
                        currentPowerWatts: state.chargingPowerWatts
                    )
                    .transition(.opacity)
                }

                if !details.isEmpty {
                    DisclosureGroup(L10n.text("Charging Details")) {
                        VStack(spacing: 6) { ForEach(details.indices, id: \.self) { details[$0] } }
                            .padding(.top, 6)
                    }
                    .disclosureGroupStyle(WholeRowDisclosureStyle())
                    .font(.system(size: 12, weight: .medium))
                }

                if !allChargingSessions.isEmpty {
                    DisclosureGroup {
                        VStack(spacing: 8) {
                            ForEach(allChargingSessions.reversed(), id: \.id) { session in
                                ChargingSessionRow(session: session)
                            }
                            Divider().opacity(0.4)
                            HStack {
                                Spacer()
                                Menu {
                                    Button(L10n.text("Export as CSV...")) {
                                        exportChargingHistoryCSV(sessions: allChargingSessions)
                                    }
                                    Button(L10n.text("Export as JSON...")) {
                                        exportChargingHistoryJSON(sessions: allChargingSessions)
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "square.and.arrow.up")
                                        Text(L10n.text("Export"))
                                    }
                                    .font(.system(size: 10, weight: .medium))
                                }
                                .menuStyle(.borderlessButton)
                                .controlSize(.mini)
                                .withoutFocusRing()
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        HStack {
                            Text(L10n.text("Charging History"))
                            Spacer()
                            Text(L10n.format("%d sessions", allChargingSessions.count))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disclosureGroupStyle(WholeRowDisclosureStyle())
                    .font(.system(size: 12, weight: .medium))
                }
            }
            .animation(cardChangeAnimation, value: "\(headline ?? "")|\(ready ?? "")|\(secondary ?? "")|\(activeSamples.count)")
        })
    }

    private var fuelAndEngineCard: AnyView? {
        guard state.powertrain.hasFuelRange || state.fuelRangeKm != nil || state.fuelLevelPercent != nil || state.fuelAmountLiters != nil || state.isEngineRunning != nil else { return nil }
        var rows: [KVRow] = []

        if let pct = state.fuelLevelPercent {
            let litersStr = state.fuelAmountLiters.map { " (\(Format.fuelVolume(liters: $0, unit: preferences.fuelVolumeUnit)))" } ?? ""
            rows.append(KVRow(L10n.text("Fuel Level"), String(format: "%.0f%%%@", pct, litersStr), symbol: "fuelpump.fill", valueWarning: pct <= 12))
        } else if let liters = state.fuelAmountLiters {
            rows.append(KVRow(L10n.text("Fuel Remaining"), Format.fuelVolume(liters: liters, unit: preferences.fuelVolumeUnit), symbol: "fuelpump.fill"))
        }

        if let range = state.fuelRangeKm {
            rows.append(KVRow(L10n.text("Distance to Empty"), Format.distance(km: range, unit: preferences.distanceUnit), symbol: "gauge.with.needle"))
        }

        if let consumption = state.averageFuelConsumptionLPer100Km {
            rows.append(KVRow(L10n.text("Avg Fuel Consumption"), Format.fuelEconomy(lPer100Km: consumption, unit: preferences.fuelEconomyUnit), symbol: "chart.line.uptrend.xyaxis"))
        }

        if let running = state.isEngineRunning {
            rows.append(KVRow(L10n.text("Engine State"), running ? L10n.text("Running") : L10n.text("Stopped"), symbol: "engine.combustion.fill", valueWarning: false))
        }

        if let hours = state.engineHoursToService {
            rows.append(KVRow(L10n.text("Engine Hours to Service"), L10n.format("%d hrs", hours), symbol: "timer"))
        }

        if let fuelType = state.fuelType {
            rows.append(KVRow(L10n.text("Fuel Grade"), fuelType, symbol: "drop.fill"))
        }

        guard !rows.isEmpty else { return nil }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(
                    symbol: "fuelpump.fill",
                    title: L10n.text("Fuel & Engine"),
                    color: .orange,
                    isSemantic: false
                )
                VStack(spacing: 6) {
                    ForEach(rows.indices, id: \.self) { rows[$0] }
                }
            }
        })
    }


    private var exceptionsCard: AnyView? {
        var rows: [KVRow] = []
        if features.contains(.vehicleAvailability), state.availability != .unknown, state.availability != .available {
            rows.append(KVRow(L10n.text("Cloud Connectivity"), state.availability.displayName,
                              symbol: "antenna.radiowaves.left.and.right", valueWarning: true))
        }
        if features.contains(.vehicleHealth) {
            if state.serviceWarning {
                rows.append(KVRow(L10n.text("Service Inspection Warning"), L10n.text("Action Required"), symbol: "exclamationmark.triangle", warning: true))
            }
            for w in state.fluidWarnings {
                rows.append(KVRow(w, L10n.text("Low Level"), symbol: "drop.triangle", warning: true))
            }
        }
        if features.contains(.exteriorStatus), let ext = state.exteriorStatus {
            for o in ext.itemsNeedingAttention {
                rows.append(KVRow(L10n.format("%@ Open", o.displayName), L10n.text("Warning"), symbol: "exclamationmark.circle.fill", warning: true))
            }
            if ext.alarmTriggered == true {
                rows.append(KVRow(L10n.text("Vehicle Alarm Triggered"), L10n.text("Active Alarm"), symbol: "speaker.wave.3.fill", warning: true))
            }
        }
        if features.contains(.tyreAndWarnings), let tyres = state.healthDetails?.tyres,
           tyres.contains(where: { $0.warning.needsAttention }) {
            let count = tyres.filter { $0.warning.needsAttention }.count
            rows.append(KVRow(L10n.text("Tyre Pressure"), L10n.format("%d tyre(s) need attention", count), symbol: "circle.grid.2x2", warning: true))
        }
        if features.contains(.tyreAndWarnings) || features.contains(.vehicleHealth), let health = state.healthDetails {
            for w in health.warnings {
                rows.append(KVRow(w.displayName, L10n.text("Warning"), symbol: "exclamationmark.triangle.fill", warning: true))
            }
        }
        if features.contains(.softwareUpdates),
           let software = state.softwareInfo,
           software.hasActionableFailure(),
           dismissedSoftwareEventIdentifier != software.eventIdentifier {
            rows.append(KVRow(L10n.text("Vehicle Software"), L10n.text("Update Failed"), symbol: "arrow.triangle.2.circlepath", warning: true))
        }
        guard !rows.isEmpty else { return nil }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "exclamationmark.triangle.fill", title: L10n.text("Needs Attention"), color: HisingenTheme.semanticWarning, isSemantic: true)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
            }
        })
    }


    private var vehicleIdentityCard: AnyView? {
        var rows: [KVRow] = []
        if features.contains(.vehicleIdentity) {
            if let plate = state.registrationNo, !plate.isEmpty {
                rows.append(KVRow(L10n.text("License Plate"), plate, symbol: "rectangle.inset.filled"))
            }
            rows.append(KVRow(L10n.text("VIN"), state.vin, symbol: "number"))
        }
        if features.contains(.vehicleAvailability), state.availability == .available {
            rows.append(KVRow(L10n.text("Cloud Connectivity"), state.availability.displayName,
                              symbol: "antenna.radiowaves.left.and.right"))
        }
        if features.contains(.vehicleHealth), let km = state.odometerKm {
            rows.append(KVRow(L10n.text("Odometer"), Format.distance(km: km, grouped: true, unit: preferences.distanceUnit), symbol: "speedometer"))
        }
        if features.contains(.vehicleHealth), let days = state.daysToService {
            var val = L10n.format("in %d days", days)
            if let km = state.distanceToServiceKm { val += " / \(Format.distance(km: km, unit: preferences.distanceUnit))" }
            if let trigger = state.formattedServiceTrigger { val += " (\(trigger))" }
            rows.append(KVRow(L10n.text("Service Due"), val, symbol: "wrench.and.screwdriver", valueWarning: days < 30))
        }
        if features.contains(.vehicleHealth), let hours = state.engineHoursToService, hours > 0 {
            rows.append(KVRow(L10n.text("Engine Hours"), "\(hours) h", symbol: "timer"))
        }
        if features.contains(.tripMeters) {
            if let km = state.tripMeterManualKm {
                rows.append(KVRow(L10n.text("Manual Trip Meter"), Format.distance(km: Int(km.rounded()), unit: preferences.distanceUnit), symbol: "m.circle"))
            }
            if let km = state.tripMeterAutomaticKm {
                rows.append(KVRow(L10n.text("Auto Trip Meter"), Format.distance(km: Int(km.rounded()), unit: preferences.distanceUnit), symbol: "a.circle"))
            }
            if let speed = state.averageSpeedKmH, speed > 0 {
                rows.append(KVRow(L10n.text("Average Speed"), Format.speed(kmH: Int(speed.rounded()), unit: preferences.distanceUnit), symbol: "gauge.with.needle"))
            }
        }
        guard !rows.isEmpty else { return nil }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "car.side", title: L10n.text("Vehicle Identity"), color: Color.accentColor)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
            }
        })
    }


    private var climateCard: AnyView? {
        var rows: [KVRow] = []
        var climateUnavailable = false
        let climateActive = state.climateStatus?.activity == .active
            || state.climateStatus?.activity == .heating
            || state.climateStatus?.activity == .cooling
            || state.climateStatus?.activity == .ventilating

        if features.contains(.climateStatus) {
            if let climate = state.climateStatus, climate.activity != .unknown {
                var val = climate.activity.displayName
                if let m = climate.timeRemainingMinutes { val += " · \(Format.shortDuration(minutes: m))" }
                if climate.timerTriggered { val += " (\(L10n.text("Timer")))" }
                rows.append(KVRow(L10n.text("Cabin Climate"), val, symbol: climateActive ? "fan.fill" : "fan"))
                if let temperature = climate.interiorTemperatureCelsius {
                    rows.append(KVRow(L10n.text("Cabin Temperature"),
                                      Format.temperature(celsius: temperature, unit: preferences.temperatureUnit), symbol: "thermometer.medium"))
                }
                if let target = climate.requestedTemperatureCelsius {
                    rows.append(KVRow(L10n.text("Climate Target"),
                                      Format.temperature(celsius: target, unit: preferences.temperatureUnit), symbol: "target"))
                }
                if let driverHeating = climate.driverSeatHeatingLevel, driverHeating > 0 {
                    rows.append(KVRow(L10n.text("Driver Seat Heating"), L10n.format("Level %d", driverHeating), symbol: "carseat.left.and.heat.waves"))
                }
                if let passHeating = climate.passengerSeatHeatingLevel, passHeating > 0 {
                    rows.append(KVRow(L10n.text("Passenger Seat Heating"), L10n.format("Level %d", passHeating), symbol: "carseat.right.and.heat.waves"))
                }
                if let wheelHeating = climate.steeringWheelHeatingLevel, wheelHeating > 0 {
                    rows.append(KVRow(L10n.text("Steering Wheel Heating"), L10n.text("Active"), symbol: "steeringwheel.and.heat.waves"))
                }
            } else if features.contains(.remoteClimate) {
                rows.append(KVRow(L10n.text("Cabin Climate"), L10n.text("Off"), symbol: "fan"))
            } else if state.climateStatus == nil {
                climateUnavailable = true
            }
            for timer in state.climateTimers.filter(\.isActive).prefix(3) {
                rows.append(KVRow(L10n.text("Ready at"), Format.scheduleText(timer), symbol: "clock.badge.checkmark"))
            }
        }
        if features.contains(.chargingSchedule) {
            for s in state.chargingSchedules.filter(\.isActive).prefix(4) {
                var key = s.kind == .departure ? L10n.text("Departure Schedule") : L10n.text("Charging Schedule")
                if let loc = s.locationName, !loc.isEmpty {
                    key = "\(loc) \(key)"
                }
                rows.append(KVRow(key, Format.scheduleText(s), symbol: "calendar.badge.clock"))
            }
        }
        if features.contains(.airQuality), let air = state.airQuality {
            var airVal = air.cleaningState.displayName
            if air.cleaningState == .on, let runtime = air.runtimeRemainingMinutes, runtime > 0 {
                airVal += " · \(Format.shortDuration(minutes: runtime))"
            }
            rows.append(KVRow(L10n.text("Cabin Air Purifier"), airVal, symbol: "sparkles", valueWarning: air.hasError))
            if let aqi = air.airQualityIndex { rows.append(KVRow(L10n.text("Air Quality Index"), "\(aqi) AQI", symbol: "wind")) }
            if let pm = air.particulateMatter25 { rows.append(KVRow(L10n.text("PM2.5 Concentration"), "\(pm) µg/m³", symbol: "aqi.medium")) }
            if let extPm = air.externalParticulateMatter25 {
                let comparison = air.particulateMatter25.map { " (\(L10n.text("Cabin")): \($0) µg/m³)" } ?? ""
                rows.append(KVRow(L10n.text("Outside PM2.5"), "\(extPm) µg/m³\(comparison)", symbol: "leaf.fill"))
            }
            if let filterLife = air.filterRemainingPercent {
                rows.append(KVRow(L10n.text("Air Filter Life"), "\(filterLife)%", symbol: "allergens", valueWarning: filterLife < 15))
            }
        }
        if features.contains(.vehicleWeather), let weather = state.weather {
            if let t = weather.temperatureCelsius {
                var val = Format.temperature(celsius: t, unit: preferences.temperatureUnit, decimals: 0)
                if let cond = weather.condition { val += " · \(L10n.text(cond))" }
                if let hum = weather.relativeHumidity { val += " · \(hum)% " + L10n.text("humidity") }
                if let feels = weather.apparentTemperatureCelsius {
                    val += " (" + L10n.format("feels like %@", Format.temperature(celsius: feels, unit: preferences.temperatureUnit, decimals: 0)) + ")"
                }
                rows.append(KVRow(L10n.text("Ambient Weather"), val, symbol: "cloud.sun.fill"))
            }
        }
        guard !rows.isEmpty || climateUnavailable else { return nil }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    HStack(spacing: 7) {
                        SpinningFanView(isSpinning: climateActive, size: 14, color: climateActive ? .orange : HisingenTheme.inkMuted)
                        Text(L10n.text("Climate & Timers"))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(HisingenTheme.ink)
                    }
                    Spacer()
                    if climateActive {
                        Pill(
                            text: state.climateStatus?.activity.displayName ?? L10n.text("Active"),
                            color: .orange,
                            symbol: "fan.fill"
                        )
                    }
                }
                if climateUnavailable {
                    CapabilityBadge(title: L10n.text("Climate status"), state: .unavailable)
                }
                if !rows.isEmpty {
                    VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
                }
            }
        })
    }

    /// Placeholder for a card whose data is missing *because the fetch did not happen* — either
    /// the endpoint reported unavailable, or we are rendering the on-disk snapshot, which
    /// `cacheableCopy` strips down to a handful of fields.
    ///
    /// Returning `nil` in that case makes a failed refresh look identical to a vehicle that
    /// simply does not report the data: the card silently vanishes and the dashboard appears to
    /// have lost features. Only vanish when the vehicle genuinely has nothing to say.
    private func unavailableCard(_ feature: AppFeature?, symbol: String,
                                 title: String, color: Color, badge: String) -> AnyView? {
        let reportedUnavailable = feature.map { state.unavailableFeatures.contains($0) } ?? false
        guard state.isCachedSnapshot || reportedUnavailable else { return nil }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: symbol, title: title, color: color)
                CapabilityBadge(title: badge, state: .unavailable)
            }
        })
    }

    private var openingsCard: AnyView? {
        guard features.contains(.exteriorStatus) else { return nil }
        guard let ext = state.exteriorStatus, !ext.openings.isEmpty else {
            if state.isVolvo {
                return AnyView(Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CardHeader(symbol: "car.side.lock", title: L10n.text("Doors & Openings"), color: .indigo)
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(HisingenTheme.semanticWarning)
                            Text(L10n.text("Requires 'Connected Vehicle API' subscription on developer.volvocars.com and 'Volvo Connected Services' enabled in vehicle privacy settings."))
                                .font(.system(size: 11))
                                .foregroundStyle(HisingenTheme.inkMuted)
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                    }
                })
            }
            return unavailableCard(.exteriorStatus, symbol: "car.side.lock",
                                   title: L10n.text("Doors & Openings"), color: .indigo,
                                   badge: AppFeature.exteriorStatus.title)
        }
        return AnyView(DoorsAndOpeningsCardView(ext: ext, isLocked: ext.isLocked))
    }

    private var lightingAndFluidCard: AnyView? {
        guard features.contains(.vehicleHealth) || features.contains(.tyreAndWarnings) else { return nil }
        var rows: [KVRow] = []
        if let fluidWarnings = Optional(state.fluidWarnings), !fluidWarnings.isEmpty {
            for f in fluidWarnings {
                rows.append(KVRow(f, L10n.text("Low Level"), symbol: "drop.triangle", warning: true))
            }
        } else {
            let hasReportedFluidStatus = state.healthDetails?.reportedWarnings.contains(where: {
                $0 == .brakeFluid || $0 == .engineCoolant || $0 == .oil || $0 == .washerFluid
            }) == true
            rows.append(KVRow(
                L10n.text("Fluid Warning Status"),
                hasReportedFluidStatus ? L10n.text("No warning reported") : L10n.text("Unavailable"),
                symbol: "drop.fill",
                info: L10n.text("The providers report warning flags, not measured fluid levels.")
            ))
        }

        if let health = state.healthDetails {
            let battery12vWarning = health.warnings.contains(.lowVoltageBattery)
            let battery12vReported = health.reportedWarnings.contains(.lowVoltageBattery)
            rows.append(KVRow(
                L10n.text("12V Battery"),
                battery12vWarning ? L10n.text("Low Voltage") : (battery12vReported ? L10n.text("No warning reported") : L10n.text("Unavailable")),
                symbol: "minus.plus.batteryblock.fill",
                warning: battery12vWarning
            ))
        }

        if let lightFailures = state.healthDetails?.lightFailures, !lightFailures.isEmpty {
            for failure in lightFailures {
                rows.append(KVRow(failure, L10n.text("Fault"), symbol: "lightbulb.slash.fill", warning: true))
            }
        } else {
            let lightsReported = state.healthDetails?.reportedWarnings.contains(.exteriorLight) == true
            rows.append(KVRow(
                L10n.text("Lighting Warning Status"),
                lightsReported ? L10n.text("No warning reported") : L10n.text("Unavailable"),
                symbol: "lightbulb.fill",
                info: L10n.text("Warning status only; this is not a live electrical test of every exterior lamp.")
            ))
        }

        guard !rows.isEmpty else { return nil }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "shield.lefthalf.filled", title: L10n.text("Vehicle Health & Lighting"), color: .yellow)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
            }
        })
    }

    private var tireSchematicCard: AnyView? {
        guard features.contains(.tyreAndWarnings) else { return nil }
        guard let tyres = state.healthDetails?.tyres, !tyres.isEmpty else {
            if state.isVolvo {
                return AnyView(Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CardHeader(symbol: "circle.grid.2x2", title: L10n.text("Tire Status (iTPMS)"), color: .blue)
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(HisingenTheme.semanticWarning)
                            Text(L10n.text("Requires 'Connected Vehicle API' subscription on developer.volvocars.com and vehicle driven to calibrate iTPMS sensors."))
                                .font(.system(size: 11))
                                .foregroundStyle(HisingenTheme.inkMuted)
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                    }
                })
            }
            return unavailableCard(.tyreAndWarnings, symbol: "circle.grid.2x2",
                                   title: L10n.text("Tire Status (iTPMS)"), color: .blue,
                                   badge: AppFeature.tyreAndWarnings.title)
        }
        let hasWarning = tyres.contains(where: { $0.warning.needsAttention })
        return AnyView(TireStatusCardView(tyres: tyres, hasWarning: hasWarning))
    }

    private var locationCard: AnyView? {
        guard features.contains(.vehicleLocation) else { return nil }
        guard let loc = state.location, let lat = loc.latitude, let lon = loc.longitude else {
            let explanation = state.isVolvo
                ? L10n.text("Location requires subscribing to the Location API in developer.volvocars.com and enabling 'Share Location' in vehicle settings.")
                : L10n.text("Parking position unavailable.")
            return AnyView(Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardHeader(symbol: "location.fill", title: L10n.text("Vehicle Location"), color: .red)
                    HStack(spacing: 8) {
                        Image(systemName: "location.slash.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(HisingenTheme.semanticWarning)
                        Text(explanation)
                            .font(.system(size: 11))
                            .foregroundStyle(HisingenTheme.inkMuted)
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                }
            })
        }
        return AnyView(LocationCardView(
            lat: lat, lon: lon, speed: loc.speed, heading: loc.heading,
            timestamp: loc.timestamp,
            altitude: loc.altitudeMeters,
            accuracy: loc.accuracyMeters,
            parkingBrake: loc.parkingBrakeEngaged,
            gear: loc.gear,
            weather: state.weather,
            isLive: !state.isStale(), freshnessText: state.freshnessDescription,
            reverseGeocoder: reverseGeocoder
        ))
    }

    private var softwareCard: AnyView? {
        guard features.contains(.softwareUpdates) else { return nil }
        guard let software = state.softwareInfo else {
            if state.isVolvo {
                // Volvo does not publish OTA software update state on its public Developer Portal API.
                return nil
            }
            return AnyView(Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(symbol: "gearshape.2.fill", title: L10n.text("Vehicle Software"), color: .blue)
                    CapabilityBadge(title: L10n.text("Software status"), state: .unavailable)
                }
            })
        }
        var rows: [KVRow] = []
        // installedVersion and latestAvailableVersion are mutually exclusive: Polestar's backend
        // only ever reports one version string at a time, either what's currently on the car or
        // the pending update target, never both — so don't fall back to `version` for whichever
        // one is nil, that would just re-duplicate the other row's value.
        if let installed = software.installedVersion {
            rows.append(KVRow(
                L10n.text("Backend-Reported Version"),
                installed,
                symbol: "checkmark.seal.fill",
                info: L10n.text("Reported by an undocumented Polestar backend field. Treat as unverified until it matches the version shown in the vehicle.")
            ))
        }
        if let latest = software.latestAvailableVersion {
            rows.append(KVRow(
                software.rawState == .updateAvailable ? L10n.text("Announced Version") : L10n.text("Update Version"),
                latest,
                symbol: "shippingbox.fill"
            ))
        }
        if let title = software.title {
            rows.append(KVRow(L10n.text("Release"), title, symbol: "doc.text"))
        }
        let statusText = software.state == .failed && !software.hasActionableFailure()
            ? L10n.text("Past event — no current action required")
            : (software.rawState?.displayName ?? software.state.displayName)
        rows.append(KVRow(L10n.text("Update Status"),
                          statusText,
                          symbol: "arrow.triangle.2.circlepath",
                          valueWarning: software.hasActionableFailure()
                              && dismissedSoftwareEventIdentifier != software.eventIdentifier))
        if let scheduledAt = software.scheduledAt {
            rows.append(KVRow(L10n.text("Installation Scheduled"),
                              Format.dateTimeFormatter.string(from: scheduledAt), symbol: "calendar.badge.clock"))
            if let setBy = software.scheduleSetBy, setBy != .unknown {
                rows.append(KVRow(L10n.text("Scheduled By"), setBy.displayName, symbol: "person.crop.circle"))
            }
        }
        if let updatedAt = software.updatedAt {
            rows.append(KVRow(L10n.text("Last Updated"),
                              Format.dateTimeFormatter.string(from: updatedAt), symbol: "clock.arrow.circlepath"))
        }
        if let duration = software.estimatedInstallDurationSeconds, duration > 0 {
            let minutes = duration / 60
            if minutes > 0 {
                rows.append(KVRow(L10n.text("Install Duration"),
                                  L10n.format("%d min", minutes), symbol: "timer"))
            }
        }
        let updateInstallable = software.rawState?.isInstallable
            ?? (software.state == .downloaded || software.state == .deferred || software.state == .scheduled)
        let eventDismissed = dismissedSoftwareEventIdentifier == software.eventIdentifier
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "gearshape.2.fill", title: L10n.text("Vehicle Software"), color: .blue)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
                if updateInstallable {
                    Divider().opacity(0.4)
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(Color.accentColor)
                        Text(L10n.format("Version %@ is ready to install in Controls.",
                                        software.latestAvailableVersion ?? software.version ?? "—"))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(HisingenTheme.ink)
                    }
                }
                if software.state == .failed {
                    Divider().opacity(0.4)
                    Button {
                        if eventDismissed {
                            preferences.setDismissedSoftwareEventIdentifier(nil, for: state.vin)
                            dismissedSoftwareEventIdentifier = nil
                        } else {
                            preferences.setDismissedSoftwareEventIdentifier(software.eventIdentifier, for: state.vin)
                            dismissedSoftwareEventIdentifier = software.eventIdentifier
                        }
                    } label: {
                        Label(
                            eventDismissed ? L10n.text("Restore software event") : L10n.text("Dismiss software event"),
                            systemImage: eventDismissed ? "arrow.uturn.backward.circle" : "xmark.circle"
                        )
                        .font(.system(size: 10.5, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    Text(eventDismissed
                         ? L10n.text("This event is hidden from Needs Attention on this Mac.")
                         : L10n.text("Dismissal is local and does not alter vehicle or Polestar backend data."))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
                if software.rawState == .updateAvailable {
                    Divider().opacity(0.4)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.badge.exclamationmark")
                                .foregroundStyle(.orange)
                                .font(.system(size: 10.5))
                            Text(L10n.text("Waiting for backend authorization"))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.orange)
                        }
                        Text(L10n.text("The update has been announced but not yet authorized for download. Polestar releases major updates in batches — your VIN may not be in the current cohort. The car downloads it automatically once the backend authorizes it."))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        if let updatedAt = software.updatedAt {
                            Text(L10n.format("Announced: %@", Format.dateTimeFormatter.string(from: updatedAt)))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        if let caps = state.otaCapabilities, !caps.supportsCloudBasedOtaDownloadConsent {
                            Text(L10n.text("This vehicle does not support cloud-based download consent — the update can only be downloaded when the car checks in with the backend autonomously. A Polestar service appointment can apply it directly."))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(L10n.text("If the update has been waiting for a long time, contact Polestar Support or book a service appointment — workshops can apply it directly."))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        })
    }

    private var diagnosticsCard: AnyView? {
        var rows: [KVRow] = []
        if state.powertrain.hasElectricRange && (features.contains(.batteryDiagnostics) || features.contains(.chargingDetails)) {
            let specification = preferences.vehicleSpecificationOverride(for: state.vin)
            if let comparison = state.currentRangeVsModelWltpPercent(specification: specification) {
                let isUserReference = specification?.wltpRangeKm != nil
                rows.append(KVRow(
                    L10n.text("Current Range vs Model WLTP"),
                    String(format: "%.1f%%", comparison),
                    symbol: "gauge.with.dots.needle.67percent",
                    info: isUserReference
                        ? L10n.text("Calculated from the vehicle-reported range and battery percentage against the VIN-specific WLTP reference entered in Settings. It is not battery health and does not directly measure speed, weather or climate use.")
                        : L10n.text("Calculated from the vehicle-reported range and battery percentage against a static model-family WLTP benchmark. It is not battery health and does not directly measure speed, weather or climate use.")
                ))
            }
        }
        if features.contains(.connectivityDiagnostics), let conn = state.connectivity {
            rows.append(KVRow(L10n.text("Vehicle Network"), conn.state.displayName, symbol: "antenna.radiowaves.left.and.right", valueWarning: conn.state == .disconnected))
            if let n = conn.networkType { rows.append(KVRow(L10n.text("Network Type"), L10n.text(n), symbol: "network")) }
            if let s = conn.signalStrength {
                let barsStr = conn.signalBars.map { " (\($0)/4)" } ?? ""
                rows.append(KVRow(L10n.text("Signal Strength"), "\(L10n.text(s))\(barsStr)", symbol: "cellularbars"))
            }
            if let wake = conn.wakeReason {
                rows.append(KVRow(L10n.text("Modem Wake Reason"), wake, symbol: "bolt.badge.clock"))
            }
            if let updated = conn.updatedAt {
                rows.append(KVRow(L10n.text("Modem Synced"), Format.dateTimeFormatter.string(from: updated), symbol: "clock.arrow.circlepath"))
            }
        }
        if let speed = state.averageSpeedKmH {
            rows.append(KVRow(L10n.text("Average Speed"), Format.speed(kmH: Int(speed.rounded()), unit: preferences.distanceUnit), symbol: "speedometer"))
        }
        if let consumption = state.averageFuelConsumptionLPer100Km {
            rows.append(KVRow(L10n.text("Avg Fuel Consumption"), Format.fuelEconomy(lPer100Km: consumption, unit: preferences.fuelEconomyUnit), symbol: "chart.line.uptrend.xyaxis"))
        }
        if let tripRange = state.tripComputerElectricRangeKm {
            rows.append(KVRow(L10n.text("Trip Computer EV Range"), Format.distance(km: tripRange, unit: preferences.distanceUnit), symbol: "gauge.with.needle", info: L10n.text("Vehicle Dynamic Estimate. Real-time driving range estimated by the onboard computer based on recent driving speed, elevation profile, and climate consumption.")))
        }
        if let hours = state.engineHoursToService {
            rows.append(KVRow(L10n.text("Engine Hours to Service"), "\(hours) hrs", symbol: "timer"))
        }
        guard !rows.isEmpty else {
            if state.isVolvo {
                return nil
            }
            return unavailableCard(nil, symbol: "stethoscope",
                                   title: L10n.text("Diagnostics & Sensors"), color: .orange,
                                   badge: L10n.text("Sensor readings"))
        }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "stethoscope", title: L10n.text("Diagnostics & Sensors"), color: .orange)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
            }
        })
    }

    private var errorsCard: AnyView? {
        guard features.contains(.vehicleErrors) else { return nil }
        let errors = state.vehicleErrors
        guard !errors.isEmpty else {
            if state.isVolvo { return nil }
            if state.unavailableFeatures.contains(.vehicleErrors) {
                return unavailableCard(.vehicleErrors, symbol: "exclamationmark.triangle",
                                       title: L10n.text("Vehicle Errors"), color: .red,
                                       badge: L10n.text("Error reporting"))
            }
            return AnyView(Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(symbol: "exclamationmark.triangle", title: L10n.text("Vehicle Errors"), color: .red)
                    KVRow(L10n.text("Backend error records"), L10n.text("None returned"), symbol: "checkmark.circle", info: L10n.text("The backend returned no error records. This is not a full diagnostic scan of the vehicle."))
                }
            })
        }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "exclamationmark.triangle.fill", title: L10n.text("Vehicle Errors"), color: .red)
                VStack(spacing: 6) {
                    ForEach(errors.indices, id: \.self) { i in
                        let e = errors[i]
                        KVRow(L10n.text(e.service.displayName), e.errorCode.displayName,
                              symbol: "exclamationmark.circle",
                              valueWarning: e.errorCode != .unspecified)
                    }
                }
            }
        })
    }

    private var attentionCard: AnyView? {
        var items: [String] = []
        if let err = error { items.append(err) }
        items.append(contentsOf: state.dataWarnings)
        guard !items.isEmpty else { return nil }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 6) {
                CardHeader(symbol: "exclamationmark.triangle.fill", title: L10n.text("Attention"), color: HisingenTheme.semanticWarning, isSemantic: true)
                ForEach(items, id: \.self) { item in
                    Text("• \(item)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        })
    }

    private func exportChargingHistoryCSV(sessions: [ChargingSession]) {
        let csvData = ChargingHistoryExport.csv(
            sessions: sessions,
            tariffPricePerKwh: preferences.electricityPricePerKwh,
            currencySymbol: preferences.currencySymbol
        )

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "charging_history_\(state.vin.prefix(8)).csv"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? csvData.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private func exportChargingHistoryJSON(sessions: [ChargingSession]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let jsonData = try? encoder.encode(sessions) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "charging_history_\(state.vin.prefix(8)).json"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? jsonData.write(to: url)
            }
        }
    }
}
