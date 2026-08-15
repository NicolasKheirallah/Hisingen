import SwiftUI

@MainActor
struct HisingenContentView: View {
    let state: VehicleState?
    let error: String?
    let authenticated: Bool
    let cars: [CarSummary]
    let activeVin: String?
    let cachedSnapshots: [String: VehicleState]
    let remoteCommandInProgress: Bool
    let updateVersion: String?
    let checkingForUpdates: Bool
    let notificationPermission: NotificationPermission
    let onRefresh: () -> Void
    let onSettings: () -> Void
    let onCheckForUpdates: () -> Void
    let onOpenUpdate: () -> Void
    let onRemoteCommand: (RemoteCommand) -> Void
    let onSelectCar: (String) -> Void
    let onSettingsChanged: (SettingsChange) -> Void
    let onSignOut: () -> Void
    let settingsMode: Bool

    @State private var selectedTab: Tab = .vehicle
    @State private var refreshRotation: Double = 0
    @Namespace private var tabIndicatorNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion


    @AppStorage("app_theme") private var appTheme: AppTheme = .hisingen

    enum Tab: String, CaseIterable {
        case vehicle = "Vehicle"
        case controls = "Controls"
        case settings = "Settings"

        var symbol: String {
            switch self {
            case .vehicle: return "bolt.car"
            case .controls: return "slider.horizontal.3"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if settingsMode || (!authenticated && selectedTab == .settings) {
                SettingsView(notificationPermission: notificationPermission,
                             onSettingsChanged: onSettingsChanged, onSignOut: onSignOut)
                    .id(activeVin ?? Preferences.vin)
            } else if !authenticated {
                WelcomeSignInView(error: error, onSettingsChanged: onSettingsChanged)
            } else if let state {
                tabBar
                Divider().opacity(0.4)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: HisingenTheme.sectionSpacing) {
                        switch selectedTab {
                        case .vehicle:
                            VehicleTabView(state: state, cars: cars, activeVin: activeVin,
                                           onSelectCar: onSelectCar, error: error)
                        case .controls:
                            ControlsTabView(state: state, remoteCommandInProgress: remoteCommandInProgress,
                                            onRemoteCommand: onRemoteCommand)
                        case .settings:
                            SettingsView(notificationPermission: notificationPermission,
                                         onSettingsChanged: onSettingsChanged, onSignOut: onSignOut)
                                .id(activeVin ?? Preferences.vin)
                        }
                    }
                    .padding(HisingenTheme.sectionSpacing)
                }
            } else {
                placeholderView
            }
            Divider().opacity(0.4)
            footerBar
        }
        .frame(width: HisingenTheme.popoverWidth)
        .frame(minHeight: 500, idealHeight: 580)
        .background(HisingenTheme.popoverBackground)
        .tint(HisingenTheme.accent)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: appTheme)


        .id(Preferences.interfaceLanguage.rawValue)
    }


    private var tabIndicatorAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.8)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(tabIndicatorAnimation) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
                        Text(L10n.text(tab.rawValue))
                            .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .medium))
                    }
                    .foregroundStyle(selectedTab == tab ? HisingenTheme.ink : HisingenTheme.inkMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(alignment: .bottom) {
                        if selectedTab == tab {


                            Group {
                                if HisingenTheme.cornerRadius == 0 {


                                    Rectangle()
                                        .fill(HisingenTheme.ink)
                                        .frame(height: 1.5)
                                } else {
                                    Capsule()
                                        .fill(.primary.opacity(0.08))
                                        .overlay(Capsule().stroke(.separator.opacity(0.3), lineWidth: 0.5))
                                }
                            }
                            .matchedGeometryEffect(id: "tabIndicator", in: tabIndicatorNamespace)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }


    private var placeholderView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text(error ?? L10n.format("Connecting to %@…", Preferences.activeBrand.displayName))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }


    private var otherBrand: VehicleBrand { Preferences.activeBrand == .polestar ? .volvo : .polestar }
    private var otherBrandResumable: Bool { Preferences.hasResumableSession(for: otherBrand) }

    private func vehicleMenuLabel(_ car: CarSummary) -> String {
        let snapshot = car.vin == activeVin ? state : cachedSnapshots[car.vin]
        guard let battery = snapshot?.batteryPercentage else { return car.title }
        let charging = snapshot?.isCharging == true ? " ⚡" : ""
        return "\(car.title) · \(Int(battery))%\(charging)"
    }

    private var vehicleSwitcher: some View {
        let currentVin = activeVin ?? cars.first?.vin ?? ""
        let currentCar = cars.first { $0.vin == currentVin }
        let brandIcon = Preferences.activeBrand == .polestar ? "bolt.car.fill" : "car.fill"

        return Menu {
            if cars.count > 1 {
                ForEach(cars, id: \.vin) { car in
                    Button {
                        onSelectCar(car.vin)
                    } label: {
                        Label(vehicleMenuLabel(car), systemImage: car.vin == currentVin ? "checkmark.circle.fill" : "circle")
                    }
                }
            }
            if otherBrandResumable {
                if cars.count > 1 { Divider() }
                Button {
                    onSettingsChanged(.switchToBrand(otherBrand))
                } label: {
                    Label(
                        L10n.format("Switch to %@ (%@)…", otherBrand.displayName, Preferences.lastVehicleLabel(for: otherBrand)),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: brandIcon)
                    .font(.system(size: 10))
                Text(currentCar?.title ?? Preferences.activeBrand.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 155, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .help(L10n.text("Switch Vehicle (⌥[ / ⌥])"))
        .accessibilityLabel(L10n.format("Current vehicle: %@. Switch vehicle.", currentCar?.title ?? Preferences.activeBrand.displayName))
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            if cars.count > 1 || otherBrandResumable {
                vehicleSwitcher
            }
            Spacer()
            if let updateVersion, Preferences.features.contains(.updateChecks) {
                Button {
                    onOpenUpdate()
                } label: {
                    Label("v\(updateVersion)", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tint)
                }
                .controlSize(.small)
            } else if Preferences.features.contains(.updateChecks) {
                Button {
                    onCheckForUpdates()
                } label: {
                    if checkingForUpdates {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .controlSize(.small)
                .help(L10n.text("Check for Updates…"))
            }
            Button {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.65)) {
                    refreshRotation += 360
                }
                onRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(refreshRotation))
            }
            .controlSize(.small)
            .help(L10n.text("Refresh Telemetry (⌘R)"))
            .disabled(!authenticated)

            Button {
                selectedTab = .settings
            } label: {
                Image(systemName: "gearshape")
            }
            .controlSize(.small)
            .help(L10n.text("Settings…"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}


@MainActor
struct VehicleTabView: View {
    let state: VehicleState
    let cars: [CarSummary]
    let activeVin: String?
    let onSelectCar: (String) -> Void
    let error: String?

    private var features: FeatureSelection { Preferences.features }

    @State private var moreExpanded = true
    @State private var chargingJustStarted = false
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
        "\(error ?? "")|\(state.dataWarnings.joined())|\(state.stateSummary.message)"
    }


    private var pillSignature: String {
        let locked = state.exteriorStatus?.isLocked
        let climate = state.climateStatus?.activity
        return "\(String(describing: locked))|\(state.chargingState.displayName)|\(String(describing: climate))"
    }


    var body: some View {
        VStack(spacing: HisingenTheme.sectionSpacing) {
            heroCard
            if let card = attentionCard { card.transition(cardTransition) }
            if let card = exceptionsCard { card.transition(cardTransition) }
            if let card = chargingCard { card }
            moreDetailsSection
        }
        .animation(cardChangeAnimation, value: warningsSignature)
    }


    private var moreDetailsSection: some View {
        let cards: [AnyView] = [
            vehicleIdentityCard, tireSchematicCard, climateCard,
            locationCard, softwareCard, diagnosticsCard
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


    private var heroCard: some View {
        Card {
            VStack(spacing: 10) {

                if features.contains(.vehicleImage), let imageData = state.imageData,
                   let nsImage = NSImage(data: imageData) {
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

                        Image(nsImage: nsImage)
                            .interpolation(.high)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(1.33, anchor: .center)
                            .frame(maxWidth: .infinity)
                            .frame(height: 205)
                            .padding(.horizontal, 8)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .padding(.horizontal, -HisingenTheme.cardPadding)
                    .padding(.top, -HisingenTheme.cardPadding)
                    .clipped()
                }


                let nickname = Preferences.vehicleNickname(for: state.vin)
                let modelIdentity = features.contains(.vehicleIdentity)
                    ? [state.modelName, state.modelYear].compactMap { $0 }.joined(separator: " · ") : ""
                let greeting = features.contains(.ownerGreeting)
                    ? state.ownerFirstName.map { Format.greeting($0) } : nil
                let plate = features.contains(.vehicleIdentity) ? state.registrationNo : nil
                let primaryTitle = greeting
                    ?? (!nickname.isEmpty ? nickname : nil)
                    ?? (modelIdentity.isEmpty ? "Hisingen" : modelIdentity)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
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
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let plate, !plate.isEmpty {
                            Text(plate)
                                .font(.system(size: 13, weight: HisingenTheme.valueWeight))
                                .monospaced()
                                .foregroundStyle(HisingenTheme.ink)
                        }
                        if greeting != nil, !nickname.isEmpty {
                            Text(nickname)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(HisingenTheme.inkMuted)
                        }
                        Spacer()
                        if !modelIdentity.isEmpty, modelIdentity != primaryTitle {
                            Text(modelIdentity)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(HisingenTheme.inkMuted)
                        }
                    }
                }


                HStack(spacing: 6) {
                    if let ext = state.exteriorStatus, let locked = ext.isLocked {
                        Pill(
                            text: locked ? "Locked" : "Unlocked",
                            color: locked ? .secondary : HisingenTheme.semanticWarning,
                            symbol: locked ? "lock.fill" : "lock.open.fill"
                        )
                        .transition(.scale.combined(with: .opacity))
                    }
                    let statusColor = HisingenTheme.statusColor(state: state.chargingState)
                    Pill(
                        text: state.chargingState.displayName,
                        color: statusColor,
                        symbol: state.isCharging ? "bolt.fill" : nil
                    )


                    .scaleEffect(chargingJustStarted ? 1.14 : 1.0)
                    .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.45), value: chargingJustStarted)
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
                .onChange(of: state.isCharging) { charging in
                    guard charging, !reduceMotion else { return }
                    chargingJustStarted = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        chargingJustStarted = false
                    }
                }


                let summary = state.stateSummary
                StateSummaryChip(message: summary.message, severity: summary.severity)
                    .id(summary.message)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                    .animation(cardChangeAnimation, value: summary.severity)


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
                            Text(state.rangeKm.map { Format.distance(km: $0, unit: Preferences.distanceUnit) } ?? "—")
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

                let fraction = (state.batteryPercentage ?? 0) / 100
                let target = state.chargeTargetPercentage.map { Double($0) / 100 }
                BatteryGauge(
                    fraction: fraction,
                    targetFraction: target,
                    color: HisingenTheme.batteryColor(percentage: state.batteryPercentage ?? 0, charging: state.isCharging),
                    isCharging: state.isCharging
                )


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
        if let rate = state.formattedChargingRate(unit: Preferences.distanceUnit) { parts.append(rate) }
        if let battery = state.batteryPercentage, battery < 100 {
            let targetPct = Double(state.chargeTargetPercentage ?? 100)
            let missingPct = max(0, targetPct - battery)
            let missingKwh = (missingPct / 100.0) * state.model.nominalUsableCapacityKwh
            let estimatedCost = missingKwh * Preferences.electricityPricePerKwh
            if estimatedCost > 0 {
                parts.append("≈" + String(format: "%.2f %@", estimatedCost, Preferences.currencySymbol) + " " + L10n.text("to target"))
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    private var chargingDetailRows: [KVRow] {
        var rows: [KVRow] = []
        if features.contains(.chargingDetails) {
            if state.chargerConnection != .unknown {
                rows.append(KVRow(L10n.text("Charger Connection"), state.chargerConnection.displayName,
                                  symbol: "powerplug.fill", valueWarning: state.chargerConnection == .fault))
            }
            if state.chargingType != .unknown, state.chargingType != .none {
                rows.append(KVRow(L10n.text("Charging Type"), state.chargingType.displayName, symbol: "bolt.circle"))
            }
            if let amps = state.chargingCurrentAmps, amps > 0 {
                rows.append(KVRow(L10n.text("Current Limit"), "\(amps) A", symbol: "waveform.path.ecg"))
            }
            if let volts = state.chargingVoltageVolts, volts > 0 {
                rows.append(KVRow(L10n.text("Voltage"), "\(volts) V", symbol: "bolt.fill"))
            }
            if let target = state.chargeTargetPercentage {
                rows.append(KVRow(L10n.text("Target Limit"), "\(target)%", symbol: "target"))
            }
        }
        if features.contains(.batteryDiagnostics), let diag = state.batteryDiagnostics {
            if diag.chargerPowerState != .unknown {
                rows.append(KVRow(L10n.text("Power Module"), diag.chargerPowerState.displayName,
                                  symbol: "batteryblock", valueWarning: diag.chargerPowerState == .fault))
            }
            if let m = diag.timeToTargetMinutes {
                rows.append(KVRow(L10n.text("Time to Target"), Format.shortDuration(minutes: m), symbol: "timer"))
            }
            if let v = diag.averageConsumption {
                rows.append(KVRow(L10n.text("Avg Consumption"), String(format: "%.1f kWh/100km", v), symbol: "chart.line.uptrend.xyaxis"))
            }
            if let wh = diag.energyUsedSinceChargeWh {
                rows.append(KVRow(L10n.text("Energy Since Charge"), String(format: "%.1f kWh", wh / 1_000), symbol: "leaf.fill"))
            }
        }
        if let session = state.chargingSessions.last {
            rows.append(KVRow(L10n.text("Last Charge"),
                              String(format: "+%.0f%% · %.1f kWh", session.percentageAdded, session.kwhDelivered),
                              symbol: "clock.arrow.circlepath"))
            if let cost = session.cost {
                rows.append(KVRow(L10n.text("Last Charge Cost"),
                                  String(format: "%.2f %@", cost, Preferences.currencySymbol),
                                  symbol: "creditcard"))
            }
        }
        return rows
    }

    private var chargingCard: AnyView? {
        guard features.contains(.chargingDetails) || features.contains(.batteryDiagnostics) else { return nil }
        let headline = chargingHeadline
        let ready = chargingReadyLine
        let secondary = chargingSecondaryLine
        let details = chargingDetailRows
        guard headline != nil || !details.isEmpty || state.chargingSamples.count >= 2 else { return nil }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "bolt.fill", title: L10n.text("Charging"), color: .green)

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
                if state.chargingSamples.count >= 2 {
                    ChargingSparklineView(samples: state.chargingSamples)
                        .transition(.opacity)
                }

                if !details.isEmpty {
                    DisclosureGroup(L10n.text("Details")) {
                        VStack(spacing: 6) { ForEach(details.indices, id: \.self) { details[$0] } }
                            .padding(.top, 6)
                    }
                    .disclosureGroupStyle(WholeRowDisclosureStyle())
                    .font(.system(size: 12, weight: .medium))
                }
            }
            .animation(cardChangeAnimation, value: "\(headline ?? "")|\(ready ?? "")|\(secondary ?? "")|\(state.chargingSamples.count >= 2)")
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
        if features.contains(.softwareUpdates), state.softwareInfo?.state == .failed {
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
            rows.append(KVRow(L10n.text("Odometer"), Format.distance(km: km, grouped: true, unit: Preferences.distanceUnit), symbol: "speedometer"))
        }
        if features.contains(.vehicleHealth), let days = state.daysToService {
            var val = L10n.format("in %d days", days)
            if let km = state.distanceToServiceKm { val += " / \(Format.distance(km: km, unit: Preferences.distanceUnit))" }
            rows.append(KVRow(L10n.text("Service Due"), val, symbol: "wrench.and.screwdriver", valueWarning: days < 30))
        }
        if features.contains(.tripMeters) {
            if let km = state.tripMeterManualKm {
                rows.append(KVRow(L10n.text("Manual Trip Meter"), Format.distance(km: Int(km.rounded()), unit: Preferences.distanceUnit), symbol: "m.circle"))
            }
            if let km = state.tripMeterAutomaticKm {
                rows.append(KVRow(L10n.text("Auto Trip Meter"), Format.distance(km: Int(km.rounded()), unit: Preferences.distanceUnit), symbol: "a.circle"))
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
        if features.contains(.climateStatus) {
            if let climate = state.climateStatus, climate.activity != .unknown {
                var val = climate.activity.displayName
                if let m = climate.timeRemainingMinutes { val += " · \(Format.shortDuration(minutes: m))" }
                rows.append(KVRow(L10n.text("Cabin Climate"), val, symbol: "fan.fill"))
                if let temperature = climate.interiorTemperatureCelsius {
                    rows.append(KVRow(L10n.text("Cabin Temperature"),
                                      String(format: "%.1f °C", temperature), symbol: "thermometer.medium"))
                }
                if let target = climate.requestedTemperatureCelsius {
                    rows.append(KVRow(L10n.text("Climate Target"),
                                      String(format: "%.1f °C", target), symbol: "target"))
                }
            } else if state.climateStatus == nil {
                climateUnavailable = true
            }
            for timer in state.climateTimers.filter(\.isActive).prefix(3) {
                rows.append(KVRow(L10n.text("Ready at"), Format.scheduleText(timer), symbol: "clock.badge.checkmark"))
            }
        }
        if features.contains(.chargingSchedule) {
            for s in state.chargingSchedules.filter(\.isActive).prefix(4) {
                let key = s.kind == .departure ? "Departure Schedule" : "Charging Schedule"
                rows.append(KVRow(key, Format.scheduleText(s), symbol: "calendar.badge.clock"))
            }
        }
        if features.contains(.airQuality), let air = state.airQuality {
            rows.append(KVRow(L10n.text("Cabin Air Purifier"), air.cleaningState.displayName, symbol: "sparkles", valueWarning: air.hasError))
            if let aqi = air.airQualityIndex { rows.append(KVRow(L10n.text("Air Quality Index"), "\(aqi) AQI", symbol: "wind")) }
            if let pm = air.particulateMatter25 { rows.append(KVRow(L10n.text("PM2.5 Concentration"), "\(pm) µg/m³", symbol: "aqi.medium")) }
        }
        if features.contains(.vehicleWeather), let weather = state.weather {
            if let t = weather.temperatureCelsius {
                var val = String(format: "%.0f °C", t)
                if let cond = weather.condition { val += " · \(cond)" }
                if let feels = weather.apparentTemperatureCelsius { val += " (feels like \(String(format: "%.0f °C", feels)))" }
                rows.append(KVRow(L10n.text("Ambient Weather"), val, symbol: "cloud.sun.fill"))
            }
        }
        guard !rows.isEmpty || climateUnavailable else { return nil }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "fan.fill", title: L10n.text("Climate & Timers"), color: .orange)
                if climateUnavailable {
                    CapabilityBadge(title: L10n.text("Climate status"), state: .unavailable)
                }
                if !rows.isEmpty {
                    VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
                }
            }
        })
    }


    private var tireSchematicCard: AnyView? {
        guard features.contains(.tyreAndWarnings), let tyres = state.healthDetails?.tyres, !tyres.isEmpty else { return nil }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "circle.grid.2x2", title: L10n.text("Tire Status (iTPMS)"), color: .blue)

                HStack(spacing: 12) {

                    VStack(spacing: 8) {
                        tirePill(title: "Front Left", tyre: tyres.first(where: { $0.position == .frontLeft }))
                        tirePill(title: "Rear Left", tyre: tyres.first(where: { $0.position == .rearLeft }))
                    }


                    VStack(spacing: 3) {
                        Image(systemName: "car.side")
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary.opacity(0.6))
                        Text("iTPMS")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: 44)


                    VStack(spacing: 8) {
                        tirePill(title: "Front Right", tyre: tyres.first(where: { $0.position == .frontRight }))
                        tirePill(title: "Rear Right", tyre: tyres.first(where: { $0.position == .rearRight }))
                    }
                }
            }
        })
    }

    private func tirePill(title: String, tyre: TyrePressure?) -> some View {
        TirePillView(title: title, tyre: tyre)
    }


    private var locationCard: AnyView? {
        guard features.contains(.vehicleLocation) else { return nil }
        guard let loc = state.location, let lat = loc.latitude, let lon = loc.longitude else {
            return AnyView(Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(symbol: "location.fill", title: L10n.text("Vehicle Location"), color: .red)
                    CapabilityBadge(title: L10n.text("Parking position"), state: .unavailable)
                }
            })
        }
        return AnyView(LocationCardView(
            lat: lat, lon: lon, speed: loc.speed,
            isLive: !state.isStale(), freshnessText: state.freshnessDescription
        ))
    }


    private var softwareCard: AnyView? {
        guard features.contains(.softwareUpdates) else { return nil }
        guard let software = state.softwareInfo else {
            return AnyView(Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(symbol: "gearshape.2.fill", title: L10n.text("Vehicle Software"), color: .blue)
                    CapabilityBadge(title: L10n.text("Software status"), state: .unavailable)
                }
            })
        }
        var rows: [KVRow] = []
        if let version = software.version {


            rows.append(KVRow(L10n.text("Available Version"), version, symbol: "shippingbox.fill"))
        }
        if let title = software.title, title != software.version {
            rows.append(KVRow(L10n.text("Release"), title, symbol: "doc.text"))
        }
        rows.append(KVRow(L10n.text("Update Status"), software.state.displayName,
                          symbol: "arrow.triangle.2.circlepath",
                          valueWarning: software.state == .failed))
        if let scheduledAt = software.scheduledAt {
            rows.append(KVRow(L10n.text("Installation Scheduled"),
                              Format.dateTimeFormatter.string(from: scheduledAt), symbol: "calendar.badge.clock"))
        }
        if let updatedAt = software.updatedAt {
            rows.append(KVRow(L10n.text("Last Updated"),
                              Format.dateTimeFormatter.string(from: updatedAt), symbol: "clock.arrow.circlepath"))
        }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "gearshape.2.fill", title: L10n.text("Vehicle Software"), color: .blue)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
            }
        })
    }


    private var diagnosticsCard: AnyView? {


        var rows: [KVRow] = []
        if features.contains(.batteryDiagnostics) || features.contains(.chargingDetails) {
            if let health = state.estimatedRangeHealth {
                rows.append(KVRow(
                    L10n.text("Range Health Estimate"),
                    String(format: "%.1f%% · %@", health.percentage, health.rating),
                    symbol: "gauge.with.dots.needle.67percent",
                    info: L10n.text("Estimated from current range versus this model's rated WLTP range at this charge level — not a measured battery health reading.")
                ))
            }
        }
        if features.contains(.connectivityDiagnostics), let conn = state.connectivity {
            rows.append(KVRow(L10n.text("Vehicle Network"), conn.state.displayName, symbol: "antenna.radiowaves.left.and.right", valueWarning: conn.state == .disconnected))
            if let n = conn.networkType { rows.append(KVRow(L10n.text("Network Type"), L10n.text(n), symbol: "network")) }
            if let s = conn.signalStrength { rows.append(KVRow(L10n.text("Signal Strength"), L10n.text(s), symbol: "cellularbars")) }
        }
        guard !rows.isEmpty else { return nil }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "stethoscope", title: L10n.text("Diagnostics & Sensors"), color: .orange)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
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
}


struct TirePillView: View {
    let title: String
    let tyre: TyrePressure?

    @State private var isHovered = false

    var body: some View {
        let warning = tyre?.warning.needsAttention == true
        let statusText = tyre?.kilopascals.map { String(format: "%.0f kPa", $0) } ?? L10n.text(warning ? "Check" : "Normal")
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Circle()
                    .fill(warning ? HisingenTheme.semanticWarning : HisingenTheme.semanticGood)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(statusText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(warning ? HisingenTheme.semanticWarning : Color.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isHovered ? (warning ? HisingenTheme.semanticWarning.opacity(0.4) : Color.accentColor.opacity(0.35)) : Color.clear, lineWidth: 0.5)
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(statusText)")
    }
}

struct LocationCardView: View {
    let lat: Double
    let lon: Double
    let speed: Double?


    let isLive: Bool
    let freshnessText: String

    @State private var streetAddress: String? = nil

    private var statusLine: String {
        let moving = (speed ?? 0) > 3
        if moving { return L10n.text("Moving now") }
        if isLive { return L10n.text("Parked here") }
        return L10n.format("Last seen here · %@", freshnessText)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "location.fill", title: L10n.text("Vehicle Location"), color: .red)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusLine)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isLive ? .secondary : HisingenTheme.semanticWarning)
                        if let streetAddress, !streetAddress.isEmpty {
                            Text(streetAddress)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }

                        Text(String(format: "GPS: %.4f°, %.4f°", lat, lon))
                            .font(.system(size: streetAddress != nil ? 10 : 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(streetAddress != nil ? .secondary : .primary)

                        if let speed, speed > 0 {
                            Text(String(format: "Speed: %.0f km/h", speed))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                        if let label = Preferences.activeBrand.displayName
                            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                           let url = URL(string: "maps://?q=\(label)&ll=\(lat),\(lon)") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "map.fill")
                            Text(L10n.text("Open in Maps"))
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .task {
            streetAddress = await ReverseGeocoder.shared.geocode(latitude: lat, longitude: lon)
        }
    }
}


struct ChargingSparklineView: View {
    let samples: [ChargingSample]

    var body: some View {
        guard samples.count >= 2 else { return AnyView(EmptyView()) }
        let percentages = samples.map(\.batteryPercentage)
        let minPct = percentages.min() ?? 0
        let maxPct = percentages.max() ?? 100
        let range = max(1.0, maxPct - minPct)

        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(L10n.text("Session Curve"), systemImage: "waveform.path.ecg")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let first = samples.first, let last = samples.last {
                        Text(String(format: "%.0f%% → %.0f%%", first.batteryPercentage, last.batteryPercentage))
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.green)
                    }
                }

                GeometryReader { geo in
                    let width = geo.size.width
                    let height = geo.size.height
                    let step = width / CGFloat(max(1, samples.count - 1))

                    ZStack {

                        Path { path in
                            path.move(to: CGPoint(x: 0, y: height))
                            for (index, sample) in samples.enumerated() {
                                let normalized = CGFloat((sample.batteryPercentage - minPct) / range)
                                let x = CGFloat(index) * step
                                let y = height - (normalized * (height - 8) + 4)
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                            path.addLine(to: CGPoint(x: CGFloat(samples.count - 1) * step, y: height))
                            path.closeSubpath()
                        }
                        .fill(
                            LinearGradient(
                                colors: [Color.green.opacity(0.22), Color.green.opacity(0.01)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )


                        Path { path in
                            for (index, sample) in samples.enumerated() {
                                let normalized = CGFloat((sample.batteryPercentage - minPct) / range)
                                let x = CGFloat(index) * step
                                let y = height - (normalized * (height - 8) + 4)
                                if index == 0 {
                                    path.move(to: CGPoint(x: x, y: y))
                                } else {
                                    path.addLine(to: CGPoint(x: x, y: y))
                                }
                            }
                        }
                        .stroke(
                            LinearGradient(
                                colors: [Color.green.opacity(0.7), Color.green],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                        )


                        if let lastSample = samples.last {
                            let normalized = CGFloat((lastSample.batteryPercentage - minPct) / range)
                            let x = CGFloat(samples.count - 1) * step
                            let y = height - (normalized * (height - 8) + 4)
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                                .position(x: x, y: y)
                        }
                    }
                }
                .frame(height: 48)
                .padding(.vertical, 2)
                .accessibilityHidden(true)
            }
            .padding(8)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        )
    }
}

