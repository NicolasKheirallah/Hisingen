import SwiftUI
import UniformTypeIdentifiers

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
    @AppStorage("his_appearanceMode") private var storedAppearanceMode: String = Preferences.appearanceMode.rawValue

    enum Tab: String, CaseIterable {
        case vehicle = "Vehicle"
        case info = "Info"
        case controls = "Controls"
        case settings = "Settings"

        var symbol: String {
            switch self {
            case .vehicle: return "bolt.car"
            case .info: return "info.circle"
            case .controls: return "slider.horizontal.3"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if settingsMode || (!authenticated && selectedTab == .settings) {
                SettingsView(notificationPermission: notificationPermission,
                             state: state,
                             onSettingsChanged: { change in
                                 if case .closeSettings = change {
                                     withAnimation { selectedTab = .vehicle }
                                 }
                                 onSettingsChanged(change)
                             }, onSignOut: onSignOut)
                    .id(Preferences.vin.isEmpty ? activeVin : Preferences.vin)
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
                                .id(state.vin)
                        case .info:
                            InfoTabView(state: state)
                                .id(state.vin)
                        case .controls:
                            ControlsTabView(state: state, remoteCommandInProgress: remoteCommandInProgress,
                                            onRemoteCommand: onRemoteCommand)
                        case .settings:
                            SettingsView(notificationPermission: notificationPermission,
                                         state: state,
                                         onSettingsChanged: { change in
                                             if case .closeSettings = change {
                                                 withAnimation { selectedTab = .vehicle }
                                             }
                                             onSettingsChanged(change)
                                         }, onSignOut: onSignOut)
                                .id(Preferences.vin.isEmpty ? activeVin : Preferences.vin)
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
        .preferredColorScheme(AppearanceMode(rawValue: storedAppearanceMode)?.colorScheme)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: appTheme)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: storedAppearanceMode)
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
                .withoutFocusRing()
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
        let snapshot = isActive ? state : cachedSnapshots[car.vin]
        let baseTitle: String = {
            if let snap = snapshot {
                return Preferences.formattedVehicleTitle(
                    vin: snap.vin,
                    modelName: snap.modelName,
                    modelYear: snap.modelYear,
                    registrationNo: snap.registrationNo
                )
            }
            return car.displayTitle()
        }()
        guard let snapshot else { return baseTitle }
        var label = baseTitle
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
        let currentTitle: String = {
            if let state, state.vin == currentVin {
                return Preferences.formattedVehicleTitle(
                    vin: state.vin,
                    modelName: state.modelName,
                    modelYear: state.modelYear,
                    registrationNo: state.registrationNo
                )
            }
            if let snap = cachedSnapshots[currentVin] {
                return Preferences.formattedVehicleTitle(
                    vin: snap.vin,
                    modelName: snap.modelName,
                    modelYear: snap.modelYear,
                    registrationNo: snap.registrationNo
                )
            }
            if let currentCar {
                return currentCar.displayTitle()
            }
            return Preferences.activeBrand.displayName
        }()
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
                Text(currentTitle)
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
        .withoutFocusRing()
        .help(L10n.format("%@ — Switch Vehicle (⌥[ / ⌥])", currentTitle))
        .accessibilityLabel(L10n.format("Current vehicle: %@. Switch vehicle.", currentTitle))
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
                .withoutFocusRing()
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
                .withoutFocusRing()
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
            .withoutFocusRing()
            .help(L10n.text("Refresh Telemetry (⌘R)"))
            .disabled(!authenticated)

            Button {
                onSettings()
            } label: {
                Image(systemName: settingsMode ? "car.fill" : "gearshape")
            }
            .controlSize(.small)
            .withoutFocusRing()
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
        let engine = state.isEngineRunning
        let fuel = state.fuelLevelPercent
        return "\(String(describing: locked))|\(state.chargingState.displayName)|\(String(describing: climate))|\(String(describing: engine))|\(String(describing: fuel))"
    }


    var body: some View {
        VStack(spacing: HisingenTheme.sectionSpacing) {
            multiCarChips
            heroCard
            if let card = attentionCard { card.transition(cardTransition) }
            if let card = exceptionsCard { card.transition(cardTransition) }
            if let card = chargingCard { card }
            if let card = fuelAndEngineCard { card }
            if let card = openingsCard { card }
            if let card = tireSchematicCard { card }
            if let card = locationCard { card }
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
            vehicleIdentityCard, lightingAndFluidCard,
            climateCard, softwareCard, diagnosticsCard
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
            ?? CarImageCache.shared.image(for: state.vin, angle: Preferences.carRenderAngle.rawValue)
            ?? CarImageCache.shared.image(for: state.vin)
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

                let badgePosition = Preferences.vehicleModelBadgePosition
                let regPosition = Preferences.registrationBadgePosition
                let modelIdentity = features.contains(.vehicleIdentity)
                    ? [state.modelName, state.modelYear].compactMap { $0 }.joined(separator: " · ") : ""
                let plate = features.contains(.vehicleIdentity) ? state.registrationNo : nil

                let showModelTopLeft = !modelIdentity.isEmpty && badgePosition == .topLeftOverlay
                let showModelTopRight = !modelIdentity.isEmpty && badgePosition == .topRightOverlay
                let showPlateTopLeft = (plate != nil && !plate!.isEmpty) && regPosition == .topLeftOverlay
                let showPlateTopRight = (plate != nil && !plate!.isEmpty) && regPosition == .topRightOverlay

                if features.contains(.vehicleImage), let imageData = heroImageData,
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


                let nickname = Preferences.vehicleNickname(for: state.vin)
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
                                Text("\(Format.fuelVolume(liters: liters, unit: Preferences.fuelVolumeUnit)) \(L10n.text("remaining"))")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(HisingenTheme.inkMuted)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            HStack(spacing: 4) {
                                Image(systemName: "fuelpump.fill")
                                    .font(.system(size: 11))
                                Text(state.fuelRangeKm.map { Format.distance(km: $0, unit: Preferences.distanceUnit) } ?? "—")
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

                    let fuelFraction = (state.fuelLevelPercent ?? 0) / 100.0
                    FuelGauge(
                        fraction: fuelFraction,
                        color: HisingenTheme.fuelColor(percentage: state.fuelLevelPercent ?? 0)
                    )
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
                                Text(state.primaryRangeKm.map { Format.distance(km: $0, unit: Preferences.distanceUnit) } ?? "—")
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
                        batteryFraction: (state.batteryPercentage ?? 0) / 100.0,
                        fuelFraction: (state.fuelLevelPercent ?? 0) / 100.0,
                        batteryColor: HisingenTheme.batteryColor(percentage: state.batteryPercentage ?? 0, charging: state.isCharging),
                        fuelColor: HisingenTheme.fuelColor(percentage: state.fuelLevelPercent ?? 0),
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
            if let drawAmps = state.chargingCurrentAmps, drawAmps > 0 {
                let label = (state.chargingCurrentLimitAmps != nil && state.chargingCurrentLimitAmps != drawAmps)
                    ? L10n.text("Current Draw") : L10n.text("Current Limit")
                rows.append(KVRow(label, "\(drawAmps) A", symbol: "waveform.path.ecg", info: L10n.text("Live Telematics. Active AC or DC current drawn from the EVSE charger.")))
            }
            if let limitAmps = state.chargingCurrentLimitAmps, limitAmps > 0, limitAmps != state.chargingCurrentAmps {
                rows.append(KVRow(L10n.text("Current Limit"), "\(limitAmps) A", symbol: "gauge.with.dots.needle.bottom.100percent", info: L10n.text("User Setting. Max AC charging current limit configured in vehicle charging settings.")))
            }
            if let volts = state.chargingVoltageVolts, volts > 0 {
                rows.append(KVRow(L10n.text("Voltage"), "\(volts) V", symbol: "bolt.fill", info: L10n.text("Live Telematics. Active AC input voltage or DC bus voltage measured by onboard charger.")))
            }
            if let target = state.chargeTargetPercentage {
                rows.append(KVRow(L10n.text("Target Limit"), "\(target)%", symbol: "target", info: L10n.text("User Setting. Selected high-voltage battery charge limit target.")))
            }
        }
        if features.contains(.batteryDiagnostics), let diag = state.batteryDiagnostics {
            if diag.chargerPowerState != .unknown {
                rows.append(KVRow(L10n.text("Power Module"), diag.chargerPowerState.displayName,
                                  symbol: "batteryblock", valueWarning: diag.chargerPowerState == .fault))
            }
            if let m = diag.timeToTargetMinutes {
                rows.append(KVRow(L10n.text("Time to Target"), Format.shortDuration(minutes: m), symbol: "timer", info: L10n.text("Vehicle Dynamic Calculation. Estimated time remaining until the high-voltage battery reaches the configured charge target.")))
            }
            if let minM = diag.timeToMinimumSOCMinutes {
                rows.append(KVRow(L10n.text("Time to Min SOC"), Format.shortDuration(minutes: minM), symbol: "battery.50percent", info: L10n.text("Vehicle Dynamic Calculation. Estimated time to reach minimum operating state of charge.")))
            }
            if let minM = diag.timeToMinimumSOCMinutes {
                rows.append(KVRow(L10n.text("Time to Min SOC"), Format.shortDuration(minutes: minM), symbol: "battery.50percent"))
            }
            if let v = diag.averageConsumption {
                rows.append(KVRow(L10n.text("Avg Consumption"), String(format: "%.1f kWh/100km", v), symbol: "chart.line.uptrend.xyaxis", info: L10n.text("Vehicle Calculation. Lifetime or long-term average energy consumption from trip computer.")))
            }
            if let avgSince = diag.averageConsumptionSinceCharge {
                rows.append(KVRow(L10n.text("Avg Since Last Charge"), String(format: "%.1f kWh/100km", avgSince), symbol: "chart.line.uptrend.xyaxis", info: L10n.text("Vehicle Calculation. Average electric consumption recorded since the vehicle was last unplugged.")))
            }
            if let avgSince = diag.averageConsumptionSinceCharge {
                rows.append(KVRow(L10n.text("Avg Since Last Charge"), String(format: "%.1f kWh/100km", avgSince), symbol: "chart.line.uptrend.xyaxis"))
            }
            if let wh = diag.energyUsedSinceChargeWh {
                rows.append(KVRow(L10n.text("Energy Since Charge"), String(format: "%.1f kWh", wh / 1_000), symbol: "leaf.fill", info: L10n.text("Vehicle Calculation. Total high-voltage energy consumed by powertrain and HVAC since the last charge.")))
            }
        }
        return rows
    }

    private var chargingReadyDate: Date? {
        guard let minutes = state.estimatedChargingTimeToFullMinutes, minutes > 0 else { return nil }
        return Date().addingTimeInterval(TimeInterval(minutes * 60))
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
        guard state.powertrain.hasElectricRange, (headline != nil || !details.isEmpty || !activeSamples.isEmpty
            || !state.chargingSessions.isEmpty) else { return nil }
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

                if !state.chargingSessions.isEmpty {
                    DisclosureGroup {
                        VStack(spacing: 8) {
                            ForEach(state.chargingSessions.reversed(), id: \.id) { session in
                                ChargingSessionRow(session: session)
                            }
                            Divider().opacity(0.4)
                            HStack {
                                Spacer()
                                Menu {
                                    Button(L10n.text("Export as CSV...")) {
                                        exportChargingHistoryCSV(sessions: state.chargingSessions)
                                    }
                                    Button(L10n.text("Export as JSON...")) {
                                        exportChargingHistoryJSON(sessions: state.chargingSessions)
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
                            Text(L10n.format("%d sessions", state.chargingSessions.count))
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
            let litersStr = state.fuelAmountLiters.map { " (\(Format.fuelVolume(liters: $0, unit: Preferences.fuelVolumeUnit)))" } ?? ""
            rows.append(KVRow(L10n.text("Fuel Level"), String(format: "%.0f%%%@", pct, litersStr), symbol: "fuelpump.fill", valueWarning: pct <= 12))
        } else if let liters = state.fuelAmountLiters {
            rows.append(KVRow(L10n.text("Fuel Remaining"), Format.fuelVolume(liters: liters, unit: Preferences.fuelVolumeUnit), symbol: "fuelpump.fill"))
        }

        if let range = state.fuelRangeKm {
            rows.append(KVRow(L10n.text("Distance to Empty"), Format.distance(km: range, unit: Preferences.distanceUnit), symbol: "gauge.with.needle"))
        }

        if let consumption = state.averageFuelConsumptionLPer100Km {
            rows.append(KVRow(L10n.text("Avg Fuel Consumption"), Format.fuelEconomy(lPer100Km: consumption, unit: Preferences.fuelEconomyUnit), symbol: "chart.line.uptrend.xyaxis"))
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
            if let trigger = state.formattedServiceTrigger { val += " (\(trigger))" }
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
                                      String(format: "%.1f °C", temperature), symbol: "thermometer.medium"))
                }
                if let target = climate.requestedTemperatureCelsius {
                    rows.append(KVRow(L10n.text("Climate Target"),
                                      String(format: "%.1f °C", target), symbol: "target"))
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
                var val = String(format: "%.0f °C", t)
                if let cond = weather.condition { val += " · \(L10n.text(cond))" }
                if let hum = weather.relativeHumidity { val += " · \(hum)% " + L10n.text("humidity") }
                if let feels = weather.apparentTemperatureCelsius { val += " (" + L10n.format("feels like %@", String(format: "%.0f °C", feels)) + ")" }
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
            rows.append(KVRow(L10n.text("Fluid Levels"), L10n.text("Normal"), symbol: "drop.fill"))
        }

        if let health = state.healthDetails {
            let battery12vWarning = health.warnings.contains(.lowVoltageBattery)
            rows.append(KVRow(
                L10n.text("12V Battery"),
                battery12vWarning ? L10n.text("Low Voltage") : L10n.text("Normal"),
                symbol: "minus.plus.batteryblock.fill",
                warning: battery12vWarning
            ))
        }

        if let lightFailures = state.healthDetails?.lightFailures, !lightFailures.isEmpty {
            for failure in lightFailures {
                rows.append(KVRow(failure, L10n.text("Fault"), symbol: "lightbulb.slash.fill", warning: true))
            }
        } else if let warnings = Optional(state.dataWarnings), !warnings.isEmpty {
            for w in warnings {
                rows.append(KVRow(L10n.text("Exterior Light"), w, symbol: "lightbulb.slash.fill", warning: true))
            }
        } else {
            rows.append(KVRow(L10n.text("Lighting Systems"), L10n.text("All Systems OK"), symbol: "lightbulb.fill"))
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
            isLive: !state.isStale(), freshnessText: state.freshnessDescription
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
            rows.append(KVRow(L10n.text("Installed Version"), installed, symbol: "checkmark.seal.fill"))
        }
        if let latest = software.latestAvailableVersion {
            rows.append(KVRow(L10n.text("Available Version"), latest, symbol: "shippingbox.fill"))
        }
        if let title = software.title {
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
        let updateAvailable = software.state == .available || software.state == .downloaded
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "gearshape.2.fill", title: L10n.text("Vehicle Software"), color: .blue)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
                if updateAvailable {
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
            }
        })
    }

    private var diagnosticsCard: AnyView? {
        var rows: [KVRow] = []
        if state.powertrain.hasElectricRange && (features.contains(.batteryDiagnostics) || features.contains(.chargingDetails)) {
            if let health = state.estimatedRangeHealth {
                rows.append(KVRow(
                    L10n.text("Range Efficiency (vs WLTP)"),
                    String(format: "%.1f%% · %@", health.percentage, health.rating),
                    symbol: "gauge.with.dots.needle.67percent",
                    info: L10n.text("Dynamic driving efficiency based on recent speed, weather, and climate heating compared to standard WLTP. For physical battery pack health (SoH), see the Info tab.")
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
            rows.append(KVRow(L10n.text("Average Speed"), String(format: "%.1f km/h", speed), symbol: "speedometer"))
        }
        if let consumption = state.averageFuelConsumptionLPer100Km {
            rows.append(KVRow(L10n.text("Avg Fuel Consumption"), Format.fuelEconomy(lPer100Km: consumption, unit: Preferences.fuelEconomyUnit), symbol: "chart.line.uptrend.xyaxis"))
        }
        if let tripRange = state.tripComputerElectricRangeKm {
            rows.append(KVRow(L10n.text("Trip Computer EV Range"), Format.distance(km: tripRange, unit: Preferences.distanceUnit), symbol: "gauge.with.needle", info: L10n.text("Vehicle Dynamic Estimate. Real-time driving range estimated by the onboard computer based on recent driving speed, elevation profile, and climate consumption.")))
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
        let headers = "Date,Start Battery %,End Battery %,Battery Added %,kWh Delivered,Peak Power (kW),Duration (min),Estimated Cost,Currency\n"
        let rows = sessions.map { s in
            let dateStr = ISO8601DateFormatter().string(from: s.startDate)
            let costStr = s.estimatedCost(tariff: Preferences.electricityPricePerKwh).map { String(format: "%.2f", $0) } ?? ""
            let peakKw = s.peakPowerWatts.map { String(format: "%.1f", Double($0) / 1000.0) } ?? ""
            return "\(dateStr),\(s.startBatteryPercentage),\(s.endBatteryPercentage),\(s.percentageAdded),\(s.kwhDelivered),\(peakKw),\(s.durationMinutes),\(costStr),\(Preferences.currencySymbol)"
        }.joined(separator: "\n")
        let csvData = headers + rows

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

struct OpeningChipView: View {
    let reading: OpeningReading
    var isHighlighted: Bool = false
    var onHoverChange: ((Bool) -> Void)? = nil

    @State private var isHovered = false

    private var isOpen: Bool { reading.state == .open || reading.state == .ajar }

    private var shortTitle: String {
        switch reading.opening {
        case .frontLeftDoor: return L10n.text("Front Left")
        case .frontRightDoor: return L10n.text("Front Right")
        case .rearLeftDoor: return L10n.text("Rear Left")
        case .rearRightDoor: return L10n.text("Rear Right")
        case .frontLeftWindow: return L10n.text("FL Window")
        case .frontRightWindow: return L10n.text("FR Window")
        case .rearLeftWindow: return L10n.text("RL Window")
        case .rearRightWindow: return L10n.text("RR Window")
        case .hood: return L10n.text("Hood")
        case .tailgate: return L10n.text("Tailgate")
        case .chargeLid: return L10n.text("Charge Lid")
        case .fuelFlap: return L10n.text("Fuel Flap")
        case .sunroof: return L10n.text("Sunroof")
        }
    }

    private var symbol: String {
        switch reading.opening {
        case .frontLeftDoor, .rearLeftDoor: return isOpen ? "door.left.hand.open" : "door.left.hand.closed"
        case .frontRightDoor, .rearRightDoor: return isOpen ? "door.right.hand.open" : "door.right.hand.closed"
        case .frontLeftWindow, .frontRightWindow, .rearLeftWindow, .rearRightWindow: return "window.vertical.closed"
        case .hood: return "car.front.waves.up"
        case .tailgate: return "car.rear.and.tire.marks"
        case .chargeLid: return "powerplug.fill"
        case .fuelFlap: return "fuelpump.fill"
        case .sunroof: return "sun.max.fill"
        }
    }

    var body: some View {
        let active = isHovered || isHighlighted
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9.5))
                .foregroundStyle(isOpen ? HisingenTheme.semanticWarning : .secondary)
                .frame(width: 12)
            Text(shortTitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isOpen ? HisingenTheme.semanticWarning : HisingenTheme.ink)
                .lineLimit(1)
            Spacer(minLength: 2)
            Circle()
                .fill(isOpen ? HisingenTheme.semanticWarning : HisingenTheme.semanticGood)
                .frame(width: 5, height: 5)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4.5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active ? (isOpen ? HisingenTheme.semanticWarning.opacity(0.12) : Color.primary.opacity(0.06)) : (isOpen ? HisingenTheme.semanticWarning.opacity(0.07) : Color.primary.opacity(0.03)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    active
                        ? (isOpen ? HisingenTheme.semanticWarning.opacity(0.6) : HisingenTheme.accent.opacity(0.5))
                        : (isOpen ? HisingenTheme.semanticWarning.opacity(0.3) : Color.primary.opacity(0.04)),
                    lineWidth: active ? 1.0 : 0.5
                )
        )
        .scaleEffect(active ? 1.02 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: active)
        .onHover { hovered in
            isHovered = hovered
            onHoverChange?(hovered)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reading.opening.displayName): \(isOpen ? L10n.text("Open") : L10n.text("Closed"))")
    }
}

struct DoorsAndOpeningsCardView: View {
    let ext: ExteriorSnapshot
    let isLocked: Bool?

    @State private var hoveredOpening: VehicleOpening? = nil

    private var openItems: [VehicleOpening] {
        ext.itemsNeedingAttention
    }

    private var hasOpen: Bool {
        !openItems.isEmpty
    }

    private func reading(for op: VehicleOpening) -> OpeningReading? {
        ext.openings.first(where: { $0.opening == op })
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                // Header
                HStack {
                    CardHeader(symbol: "car.side.lock", title: L10n.text("Doors & Openings"), color: .indigo)
                    Spacer()
                    if hasOpen {
                        Pill(
                            text: L10n.format("%d Open", openItems.count),
                            color: HisingenTheme.semanticWarning,
                            symbol: "exclamationmark.triangle.fill"
                        )
                    } else if let isLocked {
                        Pill(
                            text: isLocked ? L10n.text("All Closed & Locked") : L10n.text("All Closed"),
                            color: isLocked ? HisingenTheme.semanticGood : .secondary,
                            symbol: isLocked ? "lock.fill" : "lock.open.fill"
                        )
                    }
                }

                VehicleSideProfileDoorsView(
                    openings: ext.openings,
                    isLocked: isLocked,
                    hoveredOpening: hoveredOpening
                )
                .padding(.horizontal, 4)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 5) {
                    ForEach(displayOrder, id: \.self) { op in
                        if let r = reading(for: op) {
                            openingChip(reading: r)
                        }
                    }
                }
            }
        }
    }

    private let displayOrder: [VehicleOpening] = [
        .hood, .tailgate,
        .frontLeftDoor, .frontRightDoor,
        .rearLeftDoor, .rearRightDoor,
        .frontLeftWindow, .frontRightWindow,
        .rearLeftWindow, .rearRightWindow,
        .sunroof, .chargeLid
    ]

    @ViewBuilder
    private func openingChip(reading: OpeningReading) -> some View {
        OpeningChipView(
            reading: reading,
            isHighlighted: hoveredOpening == reading.opening,
            onHoverChange: { hovered in
                if hovered {
                    hoveredOpening = reading.opening
                } else if hoveredOpening == reading.opening {
                    hoveredOpening = nil
                }
            }
        )
    }
}

struct TireStatusCardView: View {
    let tyres: [TyrePressure]
    let hasWarning: Bool

    @State private var hoveredPosition: TyrePosition? = nil

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: "circle.grid.2x2", title: L10n.text("Tire Status (iTPMS)"), color: .blue)
                    Spacer()
                    Pill(
                        text: hasWarning ? L10n.text("Check Pressure") : L10n.text("All Normal"),
                        color: hasWarning ? HisingenTheme.semanticWarning : HisingenTheme.semanticGood,
                        symbol: hasWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    )
                }

                VehicleSideProfileTiresView(tyres: tyres, hoveredPosition: hoveredPosition)
                    .padding(.horizontal, 4)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 6) {
                    tirePill(title: L10n.text("Front Left"), position: .frontLeft)
                    tirePill(title: L10n.text("Front Right"), position: .frontRight)
                    tirePill(title: L10n.text("Rear Left"), position: .rearLeft)
                    tirePill(title: L10n.text("Rear Right"), position: .rearRight)
                }
            }
        }
    }

    @ViewBuilder
    private func tirePill(title: String, position: TyrePosition) -> some View {
        TirePillView(
            title: title,
            tyre: tyres.first(where: { $0.position == position }),
            isHighlighted: hoveredPosition == position,
            onHoverChange: { hovered in
                hoveredPosition = hovered ? position : (hoveredPosition == position ? nil : hoveredPosition)
            }
        )
    }
}

struct TirePillView: View {
    let title: String
    let tyre: TyrePressure?
    var isHighlighted: Bool = false
    var onHoverChange: ((Bool) -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        let warning = tyre?.warning.needsAttention == true
        let statusText = tyre?.kilopascals.map { String(format: "%.0f kPa", $0) } ?? (warning ? L10n.text("Check") : L10n.text("Normal"))
        let activeHover = isHovered || isHighlighted

        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Circle()
                    .fill(warning ? HisingenTheme.semanticWarning : HisingenTheme.semanticGood)
                    .frame(width: 6.5, height: 6.5)
                    .shadow(color: (warning ? HisingenTheme.semanticWarning : HisingenTheme.semanticGood).opacity(activeHover ? 0.5 : 0), radius: 2)
                    .accessibilityHidden(true)
                Text(statusText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(warning ? HisingenTheme.semanticWarning : HisingenTheme.ink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(activeHover ? Color.primary.opacity(0.08) : Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    activeHover
                        ? (warning ? HisingenTheme.semanticWarning.opacity(0.5) : HisingenTheme.accent.opacity(0.45))
                        : Color.primary.opacity(0.06),
                    lineWidth: activeHover ? 1.0 : 0.5
                )
        )
        .scaleEffect(activeHover ? 1.02 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: activeHover)
        .onHover { hovered in
            isHovered = hovered
            onHoverChange?(hovered)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(statusText)")
    }
}

struct LocationCardView: View {
    let lat: Double
    let lon: Double
    let speed: Double?
    let heading: Double?
    var timestamp: Date? = nil
    var altitude: Double? = nil
    var accuracy: Double? = nil
    var parkingBrake: Bool? = nil
    var gear: String? = nil
    var weather: VehicleWeather? = nil
    let isLive: Bool
    let freshnessText: String

    @State private var streetAddress: String? = nil
    @State private var copiedCoordinates = false

    private var isMoving: Bool { (speed ?? 0) > 3 }

    private var statusLine: String {
        if isMoving { return L10n.text("Moving now") }
        if let timestamp {
            return L10n.format("Parked at %@", Format.shortTime(date: timestamp))
        }
        if isLive { return L10n.text("Parked here") }
        return L10n.format("Last seen here · %@", freshnessText)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: "location.fill", title: L10n.text("Vehicle Location"), color: .red)
                    Spacer()
                    if let parkingBrake, parkingBrake {
                        Pill(
                            text: L10n.text("Brake Set"),
                            color: .orange,
                            symbol: "parkingsign.circle.fill"
                        )
                    }
                    if let gear, !gear.isEmpty {
                        Pill(
                            text: gear,
                            color: HisingenTheme.accent,
                            symbol: "gearshape.fill"
                        )
                    }
                    Pill(
                        text: isMoving ? L10n.text("Moving") : L10n.text("Parked"),
                        color: isMoving ? HisingenTheme.semanticActive : .secondary,
                        symbol: isMoving ? "arrow.up.right.circle.fill" : "parkingsign.circle"
                    )
                }

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusLine)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isLive ? .secondary : HisingenTheme.semanticWarning)

                        if let streetAddress, !streetAddress.isEmpty {
                            Text(streetAddress)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(HisingenTheme.ink)
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }

                        HStack(spacing: 5) {
                            Text(String(format: "GPS: %.4f°, %.4f°", lat, lon))
                                .font(.system(size: streetAddress != nil ? 10 : 11, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(streetAddress != nil ? .secondary : HisingenTheme.ink)

                            Button {
                                let coords = String(format: "%.6f, %.6f", lat, lon)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(coords, forType: .string)
                                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                                withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                                    copiedCoordinates = true
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        copiedCoordinates = false
                                    }
                                }
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: copiedCoordinates ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 9))
                                    if copiedCoordinates {
                                        Text(L10n.text("Copied"))
                                            .font(.system(size: 9, weight: .semibold))
                                    }
                                }
                                .foregroundStyle(copiedCoordinates ? HisingenTheme.semanticGood : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help(L10n.text("Copy Coordinates"))
                        }

                        if let weather, let temp = weather.temperatureCelsius {
                            HStack(spacing: 4) {
                                Image(systemName: "cloud.sun.fill")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.orange)
                                Text(String(format: "%.1f °C", temp))
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(HisingenTheme.ink)
                                if let cond = weather.condition {
                                    Text("· \(L10n.text(cond))")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(HisingenTheme.inkMuted)
                                }
                                if let hum = weather.relativeHumidity {
                                    Text("· \(hum)%")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.top, 2)
                        }

                        if let speed, speed > 0 {
                            HStack(spacing: 6) {
                                Text(String(format: "%@: %.0f km/h", L10n.text("Speed"), speed))
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                                if let heading {
                                    Text("· \(Int(heading))°")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }

                        if altitude != nil || accuracy != nil {
                            HStack(spacing: 6) {
                                if let altitude {
                                    Text(String(format: "%.0f m %@", altitude, L10n.text("elevation")))
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.secondary)
                                }
                                if let accuracy {
                                    Text(String(format: "±%.1f m", accuracy))
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 6) {
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

                        Button {
                            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                            if let url = URL(string: "https://maps.google.com/?q=\(lat),\(lon)") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "safari")
                                Text(L10n.text("Google Maps"))
                            }
                            .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
        }
        .task {
            streetAddress = await ReverseGeocoder.shared.geocode(latitude: lat, longitude: lon)
        }
    }
}


enum CurveMode: String, CaseIterable, Identifiable {
    case soc = "SoC %"
    case power = "Power kW"
    case dual = "Dual"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .soc: return L10n.text("SoC %")
        case .power: return L10n.text("Power kW")
        case .dual: return L10n.text("Dual")
        }
    }
}

@MainActor
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
    @State private var curveMode: CurveMode = .soc

    private var hasPowerData: Bool {
        samples.contains { ($0.powerWatts ?? 0) > 0 } || (currentPowerWatts ?? 0) > 0
    }

    private var startSample: ChargingSample { samples.first ?? ChargingSample(batteryPercentage: 0) }
    private var lastSample: ChargingSample { samples.last ?? startSample }
    private var effectiveTargetPct: Double? {
        targetPercentage.map(Double.init) ?? (isLive && readyDate != nil ? 100.0 : nil)
    }

    private var peakWatts: Int {
        let samplePeaks = samples.compactMap(\.powerWatts).max() ?? 0
        return max(samplePeaks, currentPowerWatts ?? 0)
    }

    private var averageWatts: Int {
        let valid = samples.compactMap(\.powerWatts).filter { $0 > 0 }
        guard !valid.isEmpty else { return currentPowerWatts ?? 0 }
        return valid.reduce(0, +) / valid.count
    }

    private var socDomain: (low: Double, high: Double) {
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

    private var powerDomain: (low: Double, high: Double) {
        let maxKw = Double(max(peakWatts, 7400)) / 1000.0 * 1.15
        return (0.0, max(3.7, maxKw))
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
        switch curveMode {
        case .power:
            if peakWatts > 0 {
                return String(format: "%@ · %@", Format.kilowatts(watts: peakWatts), L10n.text("Peak"))
            }
            return ""
        case .dual:
            let pctAdded = max(0, lastSample.batteryPercentage - startSample.batteryPercentage)
            if peakWatts > 0 {
                return String(format: "+%.0f%% · %@", pctAdded, Format.kilowatts(watts: peakWatts))
            }
            return String(format: "+%.0f%%", pctAdded)
        case .soc:
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
    }

    var body: some View {
        guard !samples.isEmpty else { return AnyView(EmptyView()) }
        let (domainLow, domainHigh) = socDomain
        let (pwrLow, pwrHigh) = powerDomain
        let (timeStart, timeEnd) = timeSpan
        let totalSpan = max(60, timeEnd.timeIntervalSince(timeStart))

        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    Label(curveMode == .power ? L10n.text("Power Curve") : L10n.text("Charging Curve"), systemImage: curveMode == .power ? "waveform.path.ecg" : "chart.xyaxis.line")
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

                    if hasPowerData {
                        Picker("", selection: $curveMode) {
                            ForEach(CurveMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.mini)
                        .frame(width: 140)
                    }

                    Spacer()
                    Text(summaryText)
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(curveMode == .power ? Color.green : HisingenTheme.accent)
                }

                GeometryReader { geo in
                    let width = geo.size.width
                    let height = geo.size.height
                    let horizontalInset: CGFloat = 8
                    let verticalInset: CGFloat = 7
                    let chartWidth = max(1, width - horizontalInset * 2)
                    let chartHeight = max(1, height - verticalInset * 2)
                    let bottomY = verticalInset + chartHeight

                    let socPoints = samples.map { sample in
                        CGPoint(
                            x: xCoord(sample.timestamp, horizontalInset: horizontalInset, chartWidth: chartWidth, timeStart: timeStart, totalSpan: totalSpan),
                            y: yCoord(sample.batteryPercentage, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: domainLow, domainHigh: domainHigh)
                        )
                    }

                    let powerPoints = samples.map { sample in
                        let kw = Double(sample.powerWatts ?? currentPowerWatts ?? 0) / 1000.0
                        return CGPoint(
                            x: xCoord(sample.timestamp, horizontalInset: horizontalInset, chartWidth: chartWidth, timeStart: timeStart, totalSpan: totalSpan),
                            y: yCoord(kw, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: pwrLow, domainHigh: pwrHigh)
                        )
                    }

                    let firstSocPoint = socPoints.first ?? CGPoint(x: horizontalInset, y: yCoord(startSample.batteryPercentage, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: domainLow, domainHigh: domainHigh))
                    let lastSocPoint = socPoints.last ?? firstSocPoint
                    let firstPowerPoint = powerPoints.first ?? CGPoint(x: horizontalInset, y: bottomY)
                    let lastPowerPoint = powerPoints.last ?? firstPowerPoint

                    let projectedEnd: CGPoint? = {
                        guard isLive, curveMode != .power, let readyDate, let effectiveTargetPct, effectiveTargetPct > lastSample.batteryPercentage else { return nil }
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
                            let kw = Double(closest.powerWatts ?? currentPowerWatts ?? 0) / 1000.0
                            let targetY = curveMode == .power ? yCoord(kw, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: pwrLow, domainHigh: pwrHigh) : yCoord(closest.batteryPercentage, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: domainLow, domainHigh: domainHigh)
                            let pt = CGPoint(
                                x: xCoord(closest.timestamp, horizontalInset: horizontalInset, chartWidth: chartWidth, timeStart: timeStart, totalSpan: totalSpan),
                                y: targetY
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
                        if curveMode != .power, let effectiveTargetPct {
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

                        if (curveMode == .power || curveMode == .dual) && averageWatts > 0 {
                            let avgKw = Double(averageWatts) / 1000.0
                            let avgY = yCoord(avgKw, verticalInset: verticalInset, chartHeight: chartHeight, domainLow: pwrLow, domainHigh: pwrHigh)
                            Path { path in
                                path.move(to: CGPoint(x: horizontalInset, y: avgY))
                                path.addLine(to: CGPoint(x: width - horizontalInset, y: avgY))
                            }
                            .stroke(Color.green.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        }

                        if curveMode == .soc || curveMode == .dual {
                            if let projectedEnd {
                                Path { path in
                                    path.move(to: lastSocPoint)
                                    path.addLine(to: projectedEnd)
                                    path.addLine(to: CGPoint(x: projectedEnd.x, y: bottomY))
                                    path.addLine(to: CGPoint(x: lastSocPoint.x, y: bottomY))
                                    path.closeSubpath()
                                }
                                .fill(
                                    LinearGradient(
                                        colors: [HisingenTheme.accent.opacity(0.10), HisingenTheme.accent.opacity(0.01)],
                                        startPoint: .top, endPoint: .bottom
                                    )
                                )
                            }

                            if socPoints.count >= 2 {
                                smoothPath(socPoints)
                                    .addingClosedBottom(firstX: firstSocPoint.x, lastX: lastSocPoint.x, bottomY: bottomY)
                                    .fill(
                                        LinearGradient(
                                            colors: [HisingenTheme.accent.opacity(0.25), HisingenTheme.accent.opacity(0.02)],
                                            startPoint: .top, endPoint: .bottom
                                        )
                                    )
                            }

                            if let projectedEnd {
                                Path { path in
                                    path.move(to: lastSocPoint)
                                    path.addLine(to: projectedEnd)
                                }
                                .stroke(HisingenTheme.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [4, 4]))

                                Circle()
                                    .strokeBorder(HisingenTheme.accent.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                                    .background(Circle().fill(HisingenTheme.accent.opacity(0.18)))
                                    .frame(width: 8, height: 8)
                                    .position(projectedEnd)
                            }

                            if socPoints.count >= 2 {
                                smoothPath(socPoints)
                                    .stroke(HisingenTheme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                                    .shadow(color: HisingenTheme.accent.opacity(0.35), radius: 3, y: 1)
                            }
                        }

                        if curveMode == .power || curveMode == .dual {
                            if powerPoints.count >= 2 {
                                if curveMode == .power {
                                    smoothPath(powerPoints)
                                        .addingClosedBottom(firstX: firstPowerPoint.x, lastX: lastPowerPoint.x, bottomY: bottomY)
                                        .fill(
                                            LinearGradient(
                                                colors: [Color.green.opacity(0.3), Color.green.opacity(0.02)],
                                                startPoint: .top, endPoint: .bottom
                                            )
                                        )
                                }

                                smoothPath(powerPoints)
                                    .stroke(
                                        Color.green,
                                        style: StrokeStyle(lineWidth: curveMode == .dual ? 1.8 : 2.2, lineCap: .round, lineJoin: .round, dash: curveMode == .dual ? [4, 3] : [])
                                    )
                                    .shadow(color: Color.green.opacity(0.35), radius: 3, y: 1)
                            }
                        }

                        if curveMode != .power {
                            Circle()
                                .fill(HisingenTheme.accent.opacity(0.75))
                                .frame(width: 5, height: 5)
                                .position(firstSocPoint)

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
                            .position(lastSocPoint)
                        } else {
                            Circle()
                                .fill(Color.green)
                                .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.2))
                                .frame(width: 7.5, height: 7.5)
                                .position(lastPowerPoint)
                        }

                        if let info = hoverInfo {
                            Path { path in
                                path.move(to: CGPoint(x: info.point.x, y: verticalInset))
                                path.addLine(to: CGPoint(x: info.point.x, y: bottomY))
                            }
                            .stroke(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

                            Circle()
                                .fill(curveMode == .power ? Color.green : HisingenTheme.accent)
                                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                                .frame(width: 9, height: 9)
                                .shadow(color: (curveMode == .power ? Color.green : HisingenTheme.accent).opacity(0.6), radius: 4)
                                .position(info.point)

                            HStack(spacing: 4) {
                                Text(String(format: "%.0f%%", info.pct))
                                    .font(.system(size: 9, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(HisingenTheme.accent)
                                if let watts = info.powerWatts, watts > 0 {
                                    Text("· \(Format.kilowatts(watts: watts))")
                                        .font(.system(size: 8.5, weight: .semibold))
                                        .foregroundStyle(.green)
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
                .frame(height: 64)
                .padding(.vertical, 2)
                .accessibilityHidden(true)

                HStack(alignment: .top) {
                    curveCaption(title: L10n.text("Start"), pct: startSample.batteryPercentage, date: startSample.timestamp)
                    Spacer()
                    if curveMode == .power && peakWatts > 0 {
                        VStack(alignment: .center, spacing: 1) {
                            Text(L10n.text("PEAK POWER"))
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text(Format.kilowatts(watts: peakWatts))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.green)
                        }
                        Spacer()
                    }
                    curveCaption(
                        title: isLive ? L10n.text("Now") : L10n.text("Finished"),
                        pct: lastSample.batteryPercentage,
                        date: lastSample.timestamp,
                        emphasized: isLive,
                        isLive: isLive
                    )
                    if curveMode != .power, let effectiveTargetPct {
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

struct MiniSparklineView: View {
    let samples: [ChargingSample]

    var body: some View {
        guard samples.count >= 2 else { return AnyView(EmptyView()) }
        let pcts = samples.map(\.batteryPercentage)
        let minV = pcts.min() ?? 0
        let maxV = pcts.max() ?? 100
        let span = max(1.0, maxV - minV)

        return AnyView(
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let points = samples.enumerated().map { (idx, s) -> CGPoint in
                    let x = CGFloat(idx) / CGFloat(samples.count - 1) * w
                    let y = (1.0 - CGFloat((s.batteryPercentage - minV) / span)) * (h - 4) + 2
                    return CGPoint(x: x, y: y)
                }

                ZStack {
                    smoothPath(points)
                        .addingClosedBottom(firstX: points.first?.x ?? 0, lastX: points.last?.x ?? w, bottomY: h)
                        .fill(
                            LinearGradient(
                                colors: [HisingenTheme.accent.opacity(0.35), HisingenTheme.accent.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )

                    smoothPath(points)
                        .stroke(HisingenTheme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                    if let last = points.last {
                        Circle()
                            .fill(HisingenTheme.accent)
                            .frame(width: 3.5, height: 3.5)
                            .position(last)
                    }
                }
            }
            .frame(width: 44, height: 16)
        )
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
                        isLive: false,
                        currentPowerWatts: session.peakPowerWatts
                    )
                }
                VStack(spacing: 6) {
                    KVRow(L10n.text("Duration"), Format.shortDuration(minutes: session.durationMinutes), symbol: "timer")
                    KVRow(L10n.text("Energy Delivered"), String(format: "%.1f kWh", session.kwhDelivered), symbol: "bolt.fill")
                    if let peak = session.peakPowerWatts, peak > 0 {
                        KVRow(L10n.text("Peak Power"), Format.kilowatts(watts: peak), symbol: "waveform.path.ecg")
                    }
                    if let cost = session.estimatedCost(tariff: Preferences.electricityPricePerKwh) {
                        KVRow(L10n.text("Estimated Cost"), String(format: "%.2f %@", cost, Preferences.currencySymbol), symbol: "creditcard")
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Format.dateTimeFormatter.string(from: session.startDate))
                        .font(.system(size: 11, weight: .medium))
                    let costStr = session.estimatedCost(tariff: Preferences.electricityPricePerKwh).map { String(format: " · %.2f %@", $0, Preferences.currencySymbol) } ?? ""
                    Text(String(format: "+%.0f%% · %.1f kWh%@", session.percentageAdded, session.kwhDelivered, costStr))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if session.samples.count >= 2 {
                    MiniSparklineView(samples: session.samples)
                }
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


