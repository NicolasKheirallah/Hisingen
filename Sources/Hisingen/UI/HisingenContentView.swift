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
                             onSettingsChanged: { change in
                                 if case .closeSettings = change {
                                     withAnimation { selectedTab = .vehicle }
                                 }
                                 onSettingsChanged(change)
                             }, onSignOut: onSignOut)
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
                                         onSettingsChanged: { change in
                                             if case .closeSettings = change {
                                                 withAnimation { selectedTab = .vehicle }
                                             }
                                             onSettingsChanged(change)
                                         }, onSignOut: onSignOut)
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
        let isActive = car.vin == activeVin
        guard let snapshot = isActive ? state : cachedSnapshots[car.vin] else { return car.title }
        var label = car.title
        if let battery = snapshot.batteryPercentage {
            label += " · \(Int(battery))%"
            if snapshot.isCharging { label += "⚡" }
        }
        let summary = snapshot.stateSummary
        if summary.severity != .good {
            label += " · \(summary.message)"
        }
        if !isActive {
            label += " · \(Format.relativeAge(since: snapshot.dataTimestamp))"
        }
        return label
    }

    private func vehicleMenuAccessibilityLabel(_ car: CarSummary, isSelected: Bool) -> String {
        let base = vehicleMenuLabel(car)
        return isSelected ? L10n.format("%@, selected", base) : base
    }

    private func otherBrandMenuLabel() -> String {
        let name = Preferences.lastVehicleLabel(for: otherBrand)
        let vin = Preferences.vin(for: otherBrand)
        if !vin.isEmpty, let battery = cachedSnapshots[vin]?.batteryPercentage {
            return L10n.format("Switch to %@ (%@ · %d%%)…", otherBrand.displayName, name, Int(battery))
        }
        return L10n.format("Switch to %@ (%@)…", otherBrand.displayName, name)
    }

    private var vehicleSwitcher: some View {
        let currentVin = activeVin ?? cars.first?.vin ?? ""
        let currentCar = cars.first { $0.vin == currentVin }
        let brandIcon = Preferences.activeBrand == .polestar ? "bolt.car.fill" : "car.fill"

        return Menu {
            if cars.count > 1 {


                ForEach(Array(cars.enumerated().prefix(9)), id: \.element.vin) { index, car in
                    let isSelected = car.vin == currentVin
                    Button {
                        onSelectCar(car.vin)
                    } label: {
                        Label(vehicleMenuLabel(car), systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                    }
                    .accessibilityLabel(vehicleMenuAccessibilityLabel(car, isSelected: isSelected))
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .option)
                }
                ForEach(Array(cars.enumerated().dropFirst(9)), id: \.element.vin) { _, car in
                    let isSelected = car.vin == currentVin
                    Button {
                        onSelectCar(car.vin)
                    } label: {
                        Label(vehicleMenuLabel(car), systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                    }
                    .accessibilityLabel(vehicleMenuAccessibilityLabel(car, isSelected: isSelected))
                }
            }
            if otherBrandResumable {
                if cars.count > 1 { Divider() }
                Button {
                    onSettingsChanged(.switchToBrand(otherBrand))
                } label: {
                    Label(otherBrandMenuLabel(), systemImage: "arrow.triangle.2.circlepath")
                }
            }
            Divider()
            Button {
                selectedTab = .settings
            } label: {
                Label(L10n.text("Add or Manage Vehicles…"), systemImage: "person.crop.circle.badge.plus")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: brandIcon)
                    .font(.system(size: 10))
                Text(currentCar?.title ?? Preferences.activeBrand.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 155, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .help(L10n.format("%@ — Switch Vehicle (⌥[ / ⌥])", currentCar?.title ?? Preferences.activeBrand.displayName))
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
                onSettings()
            } label: {
                Image(systemName: settingsMode ? "car.fill" : "gearshape")
            }
            .controlSize(.small)
            .help(settingsMode ? L10n.text("Back to Dashboard") : L10n.text("Settings…"))
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
            multiCarChips
            heroCard
            if let card = attentionCard { card.transition(cardTransition) }
            if let card = exceptionsCard { card.transition(cardTransition) }
            if let card = chargingCard { card }
            moreDetailsSection
        }
        .animation(cardChangeAnimation, value: warningsSignature)
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
                                Image(systemName: Preferences.activeBrand == .polestar ? "bolt.car.fill" : "car.fill")
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
            vehicleIdentityCard, openingsCard, tireSchematicCard, lightingAndFluidCard,
            climateCard, locationCard, softwareCard, diagnosticsCard
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
        return rows
    }

    private var chargingReadyDate: Date? {
        guard let minutes = state.estimatedChargingTimeToFullMinutes, minutes > 0 else { return nil }
        return Date().addingTimeInterval(TimeInterval(minutes * 60))
    }

    private var chargingCard: AnyView? {
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
        guard headline != nil || !details.isEmpty || !activeSamples.isEmpty
            || !state.chargingSessions.isEmpty else { return nil }
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
                    DisclosureGroup(L10n.text("Details")) {
                        VStack(spacing: 6) { ForEach(details.indices, id: \.self) { details[$0] } }
                            .padding(.top, 6)
                    }
                    .disclosureGroupStyle(WholeRowDisclosureStyle())
                    .font(.system(size: 12, weight: .medium))
                }

                if !state.chargingSessions.isEmpty {
                    DisclosureGroup(L10n.text("Charging History")) {
                        VStack(spacing: 8) {
                            ForEach(state.chargingSessions.reversed(), id: \.id) { session in
                                ChargingSessionRow(session: session)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .disclosureGroupStyle(WholeRowDisclosureStyle())
                    .font(.system(size: 12, weight: .medium))
                }
            }
            .animation(cardChangeAnimation, value: "\(headline ?? "")|\(ready ?? "")|\(secondary ?? "")|\(activeSamples.count)")
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
        if features.contains(.vehicleIdentity), let colour = state.externalColour, !colour.isEmpty {
            rows.append(KVRow(L10n.text("Exterior Color"), colour, symbol: "paintpalette.fill"))
        }
        if features.contains(.vehicleIdentity), let cap = state.reportedBatteryCapacityKwh, cap > 0 {
            rows.append(KVRow(L10n.text("Battery Capacity"), String(format: "%.1f kWh", cap), symbol: "battery.100.bolt"))
        }
        if features.contains(.vehicleIdentity), let gearbox = state.gearbox, !gearbox.isEmpty {
            rows.append(KVRow(L10n.text("Transmission"), gearbox.capitalized, symbol: "gearshape.2.fill"))
        }
        if features.contains(.vehicleHealth), let km = state.odometerKm {
            rows.append(KVRow(L10n.text("Odometer"), Format.distance(km: km, grouped: true, unit: Preferences.distanceUnit), symbol: "speedometer"))
        }
        if features.contains(.vehicleHealth), let days = state.daysToService {
            var val = L10n.format("in %d days", days)
            if let km = state.distanceToServiceKm { val += " / \(Format.distance(km: km, unit: Preferences.distanceUnit))" }
            rows.append(KVRow(L10n.text("Service Due"), val, symbol: "wrench.and.screwdriver", valueWarning: days < 30))
        }
        if features.contains(.vehicleHealth), let hours = state.engineHoursToService, hours > 0 {
            rows.append(KVRow(L10n.text("Engine Hours"), "\(hours) h", symbol: "timer"))
        }
        if features.contains(.tripMeters) {
            if let km = state.tripMeterManualKm {
                rows.append(KVRow(L10n.text("Manual Trip Meter"), Format.distance(km: Int(km.rounded()), unit: Preferences.distanceUnit), symbol: "m.circle"))
            }
            if let km = state.tripMeterAutomaticKm {
                rows.append(KVRow(L10n.text("Auto Trip Meter"), Format.distance(km: Int(km.rounded()), unit: Preferences.distanceUnit), symbol: "a.circle"))
            }
            if let speed = state.averageSpeedKmH, speed > 0 {
                rows.append(KVRow(L10n.text("Average Speed"), String(format: "%.0f km/h", speed), symbol: "gauge.with.needle"))
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

    private var openingsCard: AnyView? {
        guard features.contains(.exteriorStatus), let ext = state.exteriorStatus, !ext.openings.isEmpty else { return nil }
        let isLocked = ext.isLocked
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: "car.side.lock", title: L10n.text("Doors & Openings"), color: .indigo)
                    Spacer()
                    if let isLocked {
                        Pill(
                            text: isLocked ? "Locked" : "Unlocked",
                            color: isLocked ? .secondary : HisingenTheme.semanticWarning,
                            symbol: isLocked ? "lock.fill" : "lock.open.fill"
                        )
                    }
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(ext.openings, id: \.opening) { reading in
                        let isOpen = reading.state == .open || reading.state == .ajar
                        HStack(spacing: 6) {
                            Circle()
                                .fill(isOpen ? HisingenTheme.semanticWarning : HisingenTheme.semanticGood)
                                .frame(width: 6, height: 6)
                            Text(reading.opening.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(HisingenTheme.ink)
                            Spacer()
                            Text(isOpen ? L10n.text("Open") : L10n.text("Closed"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isOpen ? HisingenTheme.semanticWarning : HisingenTheme.inkMuted)
                        }
                        .padding(6)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        })
    }

    private var lightingAndFluidCard: AnyView? {
        guard features.contains(.vehicleHealth) || features.contains(.tyreAndWarnings) else { return nil }
        var rows: [KVRow] = []
        if let fluidWarnings = Optional(state.fluidWarnings), !fluidWarnings.isEmpty {
            for f in fluidWarnings {
                rows.append(KVRow(f, L10n.text("Low Level"), symbol: "drop.triangle", warning: true))
            }
        } else {
            rows.append(KVRow(L10n.text("Fluid Levels"), L10n.text("Normal"), symbol: "drop.fill"))
        }

        if let warnings = Optional(state.dataWarnings), !warnings.isEmpty {
            for w in warnings {
                rows.append(KVRow(L10n.text("Exterior Light"), w, symbol: "lightbulb.slash.fill", warning: true))
            }
        } else {
            rows.append(KVRow(L10n.text("Lighting Systems"), L10n.text("All 16 Systems OK"), symbol: "lightbulb.fill"))
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
            let explanation = (Preferences.activeBrand == .volvo)
                ? L10n.text("Location requires subscribing to the Location API in developer.volvocars.com and enabling 'Share Location' in vehicle settings.")
                : L10n.text("Parking position unavailable.")
            return AnyView(Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardHeader(symbol: "location.fill", title: L10n.text("Vehicle Location"), color: .red)
                    Text(explanation)
                        .font(.system(size: 11))
                        .foregroundStyle(HisingenTheme.inkMuted)
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


struct ChargingCurveView: View {
    let samples: [ChargingSample]
    let targetPercentage: Int?
    let readyDate: Date?
    let isLive: Bool
    var currentPowerWatts: Int? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var isHovering = false
    @State private var hoverLocation: CGPoint? = nil

    private var startSample: ChargingSample { samples.first ?? ChargingSample(batteryPercentage: 0) }
    private var lastSample: ChargingSample { samples.last ?? startSample }
    private var effectiveTargetPct: Double? {
        targetPercentage.map(Double.init) ?? (isLive && readyDate != nil ? 100.0 : nil)
    }

    private var domain: (low: Double, high: Double) {
        var values = [startSample.batteryPercentage, lastSample.batteryPercentage]
        if let effectiveTargetPct { values.append(effectiveTargetPct) }
        let minV = values.min() ?? 0
        let maxV = values.max() ?? 100
        let span = max(8.0, maxV - minV)
        let padding = max(2.5, span * 0.12)
        let low = max(0, minV - padding)
        let high = min(100, maxV + padding)
        return (low, max(low + 1.0, high))
    }

    private var timeSpan: (start: Date, end: Date) {
        let start = startSample.timestamp
        let rawEnd = (isLive ? (readyDate ?? lastSample.timestamp) : lastSample.timestamp)
        let end = rawEnd.timeIntervalSince(start) > 60 ? rawEnd : start.addingTimeInterval(60)
        return (start, end)
    }

    private func xCoord(_ date: Date, horizontalInset: CGFloat, chartWidth: CGFloat, timeStart: Date, totalSpan: TimeInterval) -> CGFloat {
        let fraction = CGFloat(date.timeIntervalSince(timeStart) / totalSpan)
        return horizontalInset + min(max(fraction, 0), 1) * chartWidth
    }

    private func yCoord(_ pct: Double, verticalInset: CGFloat, chartHeight: CGFloat, domainLow: Double, domainHigh: Double) -> CGFloat {
        let fraction = CGFloat((pct - domainLow) / (domainHigh - domainLow))
        return verticalInset + (1.0 - min(max(fraction, 0), 1)) * chartHeight
    }

    private var summaryText: String {
        let pctAdded = max(0, lastSample.batteryPercentage - startSample.batteryPercentage)
        if isLive {
            if let effectiveTargetPct, effectiveTargetPct > lastSample.batteryPercentage {
                return String(format: "%.0f%% → %.0f%%", lastSample.batteryPercentage, effectiveTargetPct)
            }
            if pctAdded >= 0.5 {
                return String(format: "%.0f%% (+%.0f%%)", lastSample.batteryPercentage, pctAdded)
            }
            return String(format: "%.0f%%", lastSample.batteryPercentage)
        }
        return String(format: "%.0f%% → %.0f%% (+%.0f%%)", startSample.batteryPercentage, lastSample.batteryPercentage, pctAdded)
    }

    var body: some View {
        guard !samples.isEmpty else { return AnyView(EmptyView()) }
        let (domainLow, domainHigh) = domain
        let (timeStart, timeEnd) = timeSpan
        let totalSpan = max(60, timeEnd.timeIntervalSince(timeStart))

        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    Label(L10n.text("Charging Curve"), systemImage: "chart.xyaxis.line")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    if isLive {
                        Circle()
                            .fill(HisingenTheme.semanticGood)
                            .frame(width: 5, height: 5)
                            .opacity(pulse ? 1.0 : 0.45)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)
                        Text(L10n.text("Live").uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.3)
                            .foregroundStyle(HisingenTheme.semanticGood)
                    }
                    Spacer()
                    Text(summaryText)
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(HisingenTheme.accent)
                }

                GeometryReader { geo in
                    let width = geo.size.width
                    let height = geo.size.height
                    let horizontalInset: CGFloat = 8
                    let verticalInset: CGFloat = 7
                    let chartWidth = max(1, width - horizontalInset * 2)
                    let chartHeight = max(1, height - verticalInset * 2)
                    let bottomY = verticalInset + chartHeight

                    let points = samples.map { sample in
                        CGPoint(
                            x: xCoord(sample.timestamp, horizontalInset: horizontalInset, chartWidth: chartWidth, timeStart: timeStart, totalSpan: totalSpan),
                            y: yCoord(sample.batteryPercentage, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: domainLow, domainHigh: domainHigh)
                        )
                    }
                    let firstPoint = points.first ?? CGPoint(x: horizontalInset, y: yCoord(startSample.batteryPercentage, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: domainLow, domainHigh: domainHigh))
                    let lastPoint = points.last ?? firstPoint
                    let projectedEnd: CGPoint? = {
                        guard isLive, let readyDate, let effectiveTargetPct, effectiveTargetPct > lastSample.batteryPercentage else { return nil }
                        return CGPoint(
                            x: xCoord(readyDate, horizontalInset: horizontalInset, chartWidth: chartWidth, timeStart: timeStart, totalSpan: totalSpan),
                            y: yCoord(effectiveTargetPct, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: domainLow, domainHigh: domainHigh)
                        )
                    }()

                    let hoverInfo: (point: CGPoint, pct: Double, date: Date, powerWatts: Int?, isProjected: Bool)? = {
                        guard isHovering, let hoverPos = hoverLocation else { return nil }
                        let clampedX = min(max(hoverPos.x, horizontalInset), width - horizontalInset)
                        let timeFrac = Double((clampedX - horizontalInset) / chartWidth)
                        let hoveredDate = timeStart.addingTimeInterval(timeFrac * totalSpan)

                        if hoveredDate <= lastSample.timestamp || projectedEnd == nil {
                            let closest = samples.min(by: { abs($0.timestamp.timeIntervalSince(hoveredDate)) < abs($1.timestamp.timeIntervalSince(hoveredDate)) }) ?? lastSample
                            let pt = CGPoint(
                                x: xCoord(closest.timestamp, horizontalInset: horizontalInset, chartWidth: chartWidth, timeStart: timeStart, totalSpan: totalSpan),
                                y: yCoord(closest.batteryPercentage, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: domainLow, domainHigh: domainHigh)
                            )
                            return (pt, closest.batteryPercentage, closest.timestamp, closest.powerWatts ?? currentPowerWatts, false)
                        } else if let readyDate, let effectiveTargetPct {
                            let projTotal = readyDate.timeIntervalSince(lastSample.timestamp)
                            let projElapsed = hoveredDate.timeIntervalSince(lastSample.timestamp)
                            let projFrac = projTotal > 0 ? min(max(projElapsed / projTotal, 0), 1) : 1.0
                            let interpPct = lastSample.batteryPercentage + projFrac * (effectiveTargetPct - lastSample.batteryPercentage)
                            let pt = CGPoint(
                                x: xCoord(hoveredDate, horizontalInset: horizontalInset, chartWidth: chartWidth, timeStart: timeStart, totalSpan: totalSpan),
                                y: yCoord(interpPct, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: domainLow, domainHigh: domainHigh)
                            )
                            return (pt, interpPct, hoveredDate, nil, true)
                        }
                        return nil
                    }()

                    ZStack {

                        if let effectiveTargetPct {
                            let guideY = yCoord(effectiveTargetPct, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: domainLow, domainHigh: domainHigh)
                            Path { path in
                                path.move(to: CGPoint(x: horizontalInset, y: guideY))
                                path.addLine(to: CGPoint(x: width - horizontalInset, y: guideY))
                            }
                            .stroke(Color.secondary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                            Text(L10n.format("Target %d%%", Int(effectiveTargetPct)))
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(.regularMaterial, in: Capsule())
                                .position(x: max(32, width - 36), y: max(verticalInset + 4, guideY - 9))
                        }


                        if let projectedEnd {
                            Path { path in
                                path.move(to: lastPoint)
                                path.addLine(to: projectedEnd)
                                path.addLine(to: CGPoint(x: projectedEnd.x, y: bottomY))
                                path.addLine(to: CGPoint(x: lastPoint.x, y: bottomY))
                                path.closeSubpath()
                            }
                            .fill(
                                LinearGradient(
                                    colors: [HisingenTheme.accent.opacity(0.10), HisingenTheme.accent.opacity(0.01)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                        }


                        if points.count >= 2 {
                            smoothPath(points)
                                .addingClosedBottom(firstX: firstPoint.x, lastX: lastPoint.x, bottomY: bottomY)
                                .fill(
                                    LinearGradient(
                                        colors: [HisingenTheme.accent.opacity(0.25), HisingenTheme.accent.opacity(0.02)],
                                        startPoint: .top, endPoint: .bottom
                                    )
                                )
                        }


                        if let projectedEnd {
                            Path { path in
                                path.move(to: lastPoint)
                                path.addLine(to: projectedEnd)
                            }
                            .stroke(HisingenTheme.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [4, 4]))


                            Circle()
                                .strokeBorder(HisingenTheme.accent.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                                .background(Circle().fill(HisingenTheme.accent.opacity(0.18)))
                                .frame(width: 8, height: 8)
                                .position(projectedEnd)
                        }


                        if points.count >= 2 {
                            smoothPath(points)
                                .stroke(HisingenTheme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                                .shadow(color: HisingenTheme.accent.opacity(0.35), radius: 3, y: 1)


                            if isLive && !reduceMotion {
                                smoothPath(points)
                                    .stroke(
                                        LinearGradient(
                                            colors: [HisingenTheme.accent.opacity(0.2), Color.white.opacity(0.85), HisingenTheme.accent],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        ),
                                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                                    )
                                    .opacity(pulse ? 0.85 : 0.3)
                            }
                        }


                        Circle()
                            .fill(HisingenTheme.accent.opacity(0.75))
                            .frame(width: 5, height: 5)
                            .position(firstPoint)


                        ZStack {
                            if isLive && !reduceMotion {
                                Circle()
                                    .stroke(HisingenTheme.accent.opacity(pulse ? 0.0 : 0.65), lineWidth: 1.5)
                                    .frame(width: 16, height: 16)
                                    .scaleEffect(pulse ? 1.65 : 0.85)
                            }
                            Circle()
                                .fill(HisingenTheme.accent)
                                .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.2))
                                .frame(width: 7.5, height: 7.5)
                                .shadow(color: HisingenTheme.accent.opacity(isLive ? (pulse ? 0.75 : 0.35) : 0.25), radius: isLive ? (pulse ? 5 : 2) : 2)
                        }
                        .position(lastPoint)


                        if let info = hoverInfo {

                            Path { path in
                                path.move(to: CGPoint(x: info.point.x, y: verticalInset))
                                path.addLine(to: CGPoint(x: info.point.x, y: bottomY))
                            }
                            .stroke(HisingenTheme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))


                            Circle()
                                .fill(HisingenTheme.accent)
                                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                                .frame(width: 9, height: 9)
                                .shadow(color: HisingenTheme.accent.opacity(0.6), radius: 4)
                                .position(info.point)


                            HStack(spacing: 4) {
                                Text(String(format: "%.0f%%", info.pct))
                                    .font(.system(size: 9, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(HisingenTheme.accent)
                                if let watts = info.powerWatts, watts > 0 {
                                    Text("· \(Format.kilowatts(watts: watts))")
                                        .font(.system(size: 8.5, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                Text("· " + Format.shortTime(date: info.date))
                                    .font(.system(size: 8.5))
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                                if info.isProjected {
                                    Text("(\(L10n.text("Projected")))")
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                            .position(
                                x: min(max(info.point.x, 60), width - 60),
                                y: max(verticalInset + 10, info.point.y - 18)
                            )
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            isHovering = true
                            hoverLocation = location
                        case .ended:
                            isHovering = false
                            hoverLocation = nil
                        }
                    }
                    .onAppear {
                        guard isLive, !reduceMotion else { return }
                        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
                    }
                }
                .frame(height: 60)
                .padding(.vertical, 2)
                .accessibilityHidden(true)

                HStack(alignment: .top) {
                    curveCaption(title: L10n.text("Start"), pct: startSample.batteryPercentage, date: startSample.timestamp)
                    Spacer()
                    curveCaption(
                        title: isLive ? L10n.text("Now") : L10n.text("Finished"),
                        pct: lastSample.batteryPercentage,
                        date: lastSample.timestamp,
                        emphasized: isLive,
                        isLive: isLive
                    )
                    if let effectiveTargetPct {
                        Spacer()
                        curveCaption(
                            title: isLive ? L10n.text("Ready") : L10n.text("Target"),
                            pct: effectiveTargetPct,
                            date: isLive ? readyDate : nil,
                            isProjected: isLive
                        )
                    }
                }
            }
            .padding(9)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        )
    }

    @ViewBuilder
    private func curveCaption(
        title: String,
        pct: Double,
        date: Date?,
        emphasized: Bool = false,
        isLive: Bool = false,
        isProjected: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                if isLive {
                    Circle()
                        .fill(HisingenTheme.accent)
                        .frame(width: 4, height: 4)
                }
                Text(title.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.tertiary)
            }
            Text(String(format: "%.0f%%", pct))
                .font(.system(size: 12, weight: emphasized ? .bold : .semibold))
                .monospacedDigit()
                .foregroundStyle(emphasized ? HisingenTheme.accent : .primary)
            if let date {
                Text(Format.shortTime(date: date))
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func smoothPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
        for i in 0..<points.count - 1 {
            let p0 = points[max(0, i - 1)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(points.count - 1, i + 2)]
            let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: cp1, control2: cp2)
        }
        return path
    }
}

private extension Path {
    func addingClosedBottom(firstX: CGFloat, lastX: CGFloat, bottomY: CGFloat) -> Path {
        var closed = self
        closed.addLine(to: CGPoint(x: lastX, y: bottomY))
        closed.addLine(to: CGPoint(x: firstX, y: bottomY))
        closed.closeSubpath()
        return closed
    }
}

struct ChargingSessionRow: View {
    let session: ChargingSession

    @State private var isHovered = false

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if !session.samples.isEmpty {
                    ChargingCurveView(
                        samples: session.samples,
                        targetPercentage: session.targetPercentage,
                        readyDate: nil,
                        isLive: false
                    )
                }
                VStack(spacing: 6) {
                    KVRow(L10n.text("Duration"), Format.shortDuration(minutes: session.durationMinutes), symbol: "timer")
                    KVRow(L10n.text("Energy Delivered"), String(format: "%.1f kWh", session.kwhDelivered), symbol: "bolt.fill")
                    if let peak = session.peakPowerWatts, peak > 0 {
                        KVRow(L10n.text("Peak Power"), Format.kilowatts(watts: peak), symbol: "waveform.path.ecg")
                    }
                    if let cost = session.cost {
                        KVRow(L10n.text("Cost"), String(format: "%.2f %@", cost, Preferences.currencySymbol), symbol: "creditcard")
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Format.dateTimeFormatter.string(from: session.startDate))
                        .font(.system(size: 11, weight: .medium))
                    Text(String(format: "+%.0f%% · %.1f kWh", session.percentageAdded, session.kwhDelivered))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .disclosureGroupStyle(WholeRowDisclosureStyle())
        .font(.system(size: 11))
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
        .onHover { isHovered = $0 }
    }
}


