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
    let diagnostics: DiagnosticsSnapshot?
    let onRefresh: () -> Void
    let onSettings: () -> Void
    let onCheckForUpdates: () -> Void
    let onOpenUpdate: () -> Void
    let onRemoteCommand: (RemoteCommand) -> Void
    let onSelectCar: (String) -> Void
    let onSettingsChanged: (SettingsChange) -> Void
    let onSignOut: () -> Void
    let onTestConnection: (VehicleBrand) async -> (success: Bool, message: String)
    let settingsMode: Bool
    let database: VehicleDatabase
    let reverseGeocoder: ReverseGeocoder
    let imageCache: CarImageCache

    @State private var selectedTab: Tab
    private let tabSelection: Binding<Tab>
    @State private var refreshRotation: Double = 0
    @Namespace private var tabIndicatorNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.preferencesStore) private var preferences


    @AppStorage("app_theme") private var appTheme: AppTheme = .hisingen
    @AppStorage("his_appearanceMode") private var storedAppearanceMode: String = AppearanceMode.system.rawValue

    enum Tab: String, CaseIterable {
        case vehicle = "Vehicle"
        case info = "Info"
        case history = "History"
        case controls = "Controls"
        case settings = "Settings"

        var symbol: String {
            switch self {
            case .vehicle: return "bolt.car"
            case .info: return "info.circle"
            case .history: return "chart.xyaxis.line"
            case .controls: return "slider.horizontal.3"
            case .settings: return "gearshape"
            }
        }
    }

    init(
        state: VehicleState?, error: String?, authenticated: Bool, cars: [CarSummary],
        activeVin: String?, cachedSnapshots: [String: VehicleState],
        remoteCommandInProgress: Bool, updateVersion: String?, checkingForUpdates: Bool,
        notificationPermission: NotificationPermission, diagnostics: DiagnosticsSnapshot?,
        onRefresh: @escaping () -> Void, onSettings: @escaping () -> Void,
        onCheckForUpdates: @escaping () -> Void, onOpenUpdate: @escaping () -> Void,
        onRemoteCommand: @escaping (RemoteCommand) -> Void,
        onSelectCar: @escaping (String) -> Void,
        onSettingsChanged: @escaping (SettingsChange) -> Void,
        onSignOut: @escaping () -> Void,
        onTestConnection: @escaping (VehicleBrand) async -> (success: Bool, message: String) = { _ in
            (false, L10n.text("Connection testing is not available."))
        },
        settingsMode: Bool,
        selectedTab: Binding<Tab>, database: VehicleDatabase,
         reverseGeocoder: ReverseGeocoder, imageCache: CarImageCache
    ) {
        self.state = state
        self.error = error
        self.authenticated = authenticated
        self.cars = cars
        self.activeVin = activeVin
        self.cachedSnapshots = cachedSnapshots
        self.remoteCommandInProgress = remoteCommandInProgress
        self.updateVersion = updateVersion
        self.checkingForUpdates = checkingForUpdates
        self.notificationPermission = notificationPermission
        self.diagnostics = diagnostics
        self.onRefresh = onRefresh
        self.onSettings = onSettings
        self.onCheckForUpdates = onCheckForUpdates
        self.onOpenUpdate = onOpenUpdate
        self.onRemoteCommand = onRemoteCommand
        self.onSelectCar = onSelectCar
        self.onSettingsChanged = onSettingsChanged
        self.onSignOut = onSignOut
        self.onTestConnection = onTestConnection
        self.settingsMode = settingsMode
        self.database = database
        self.reverseGeocoder = reverseGeocoder
        self.imageCache = imageCache
        self._selectedTab = State(initialValue: selectedTab.wrappedValue)
        self.tabSelection = selectedTab
    }

    // Panel geometry mirrors. Reading the raw defaults through @AppStorage means a
    // preset / density / custom-slider change invalidates this view natively — the
    // frames below animate without needing the rootView replacement dance, which
    // also keeps scroll positions and disclosure state intact across resizes.
    @AppStorage("panel_size") private var storedPanelSizeRaw: String = PanelSize.standard.rawValue
    @AppStorage("content_density") private var storedDensityRaw: String = ContentDensity.standard.rawValue
    @AppStorage("custom_panel_size_enabled") private var storedCustomSizeEnabled = false
    @AppStorage("custom_panel_width") private var storedCustomWidth = 0.0
    @AppStorage("custom_panel_height") private var storedCustomHeight = 0.0

    private var panelLayout: PanelLayout {
        PanelLayout.resolve(
            panelSizeRaw: storedPanelSizeRaw,
            densityRaw: storedDensityRaw,
            customEnabled: storedCustomSizeEnabled,
            customWidth: storedCustomWidth,
            customHeight: storedCustomHeight
        )
    }

    var body: some View {
        let layout = panelLayout
        return VStack(spacing: 0) {
            if settingsMode || (!authenticated && selectedTab == .settings) {
                SettingsView(notificationPermission: notificationPermission,
                             state: state,
                             cachedSnapshots: cachedSnapshots,
                             database: database, imageCache: imageCache,
                             onSettingsChanged: { change in
                                 if case .closeSettings = change {
                                      withAnimation { selectedTab = .vehicle }
                                      tabSelection.wrappedValue = .vehicle
                                 }
                                 onSettingsChanged(change)
                             }, onSignOut: onSignOut, onTestConnection: onTestConnection)
                     .id(preferences.vin.isEmpty ? activeVin : preferences.vin)
            } else if !authenticated {
                WelcomeSignInView(error: error, onSettingsChanged: onSettingsChanged, onTestConnection: onTestConnection)
            } else if let state {
                tabBar
                Divider().opacity(0.4)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: HisingenTheme.sectionSpacing) {
                        if !state.retainedDataCategories.isEmpty {
                            retainedDataNotice(state)
                        }
                        switch selectedTab {
                        case .vehicle:
                            VehicleTabView(state: state, cars: cars, activeVin: activeVin,
                                           onSelectCar: onSelectCar, error: error,
                                           database: database, reverseGeocoder: reverseGeocoder,
                                           imageCache: imageCache)
                                .id(state.vin)
                        case .info:
                            InfoTabView(state: state, database: database, imageCache: imageCache,
                                        reverseGeocoder: reverseGeocoder)
                                .id(state.vin)
                        case .history:
                            HistoryDashboardView(state: state, database: database)
                                .id(state.vin)
                        case .controls:
                            ControlsTabView(state: state, remoteCommandInProgress: remoteCommandInProgress,
                                            onRemoteCommand: onRemoteCommand)
                        case .settings:
                            SettingsView(notificationPermission: notificationPermission,
                                         state: state,
                                         cachedSnapshots: cachedSnapshots,
                                         database: database, imageCache: imageCache,
                                         onSettingsChanged: { change in
                                             if case .closeSettings = change {
                                                  withAnimation { selectedTab = .vehicle }
                                                  tabSelection.wrappedValue = .vehicle
                                             }
                                             onSettingsChanged(change)
                                         }, onSignOut: onSignOut)
                                 .id(preferences.vin.isEmpty ? activeVin : preferences.vin)
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
        // Content-density zoom: lay out at panelSize/scale, then scale into the physical
        // panel — so Compact fits more content and Relaxed enlarges it, independently of
        // the window preset. Transforms are ignored by layout, hence the inverse frames.
        // Height comes pre-clamped by PanelLayout to what fits below the menu bar.
        .frame(width: layout.logicalWidth)
        .frame(height: layout.logicalHeight)
        .scaleEffect(layout.contentScale, anchor: .topLeading)
        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
        // Clips the transformed tree to the physical panel; without it, scaled
        // overflow would draw outside the transparent popover window.
        .clipped()
        .background { HisingenTheme.popoverSurface }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: panelLayout)
        .tint(HisingenTheme.accent)
        .preferredColorScheme(AppearanceMode(rawValue: storedAppearanceMode)?.colorScheme)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: appTheme)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: storedAppearanceMode)
        .id(preferences.interfaceLanguage.rawValue)
    }

    private var garageStates: [VehicleState] {
        var values = cachedSnapshots
        if let state { values[state.vin] = state }
        return values.values.sorted {
            if $0.model.brand != $1.model.brand { return $0.model.brand.rawValue < $1.model.brand.rawValue }
            return ($0.modelName ?? $0.vin) < ($1.modelName ?? $1.vin)
        }
    }

    private func retainedDataNotice(_ state: VehicleState) -> some View {
        let names = state.retainedDataCategories.map(\.title).joined(separator: ", ")
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(HisingenTheme.semanticWarning)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("Showing last-known values"))
                    .font(.system(size: 11, weight: .semibold))
                Text(names)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let timestamp = state.retainedDataAt {
                    Text(L10n.format("Source data from %@", Format.relativeAge(since: timestamp)))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(9)
        .background(HisingenTheme.semanticWarning.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(HisingenTheme.semanticWarning.opacity(0.22)))
        .help(L10n.text("The newest provider refresh did not include these fields. Hisingen retained the previous successful readings and labels them here instead of presenting them as live."))
        .accessibilityElement(children: .combine)
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
                        tabSelection.wrappedValue = tab
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 10.5, weight: selectedTab == tab ? .semibold : .regular))
                        Text(L10n.text(tab.rawValue))
                            .font(.system(size: 10, weight: selectedTab == tab ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(selectedTab == tab ? HisingenTheme.ink : HisingenTheme.inkMuted)
                    .padding(.horizontal, 6)
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
                .help(L10n.text(tab.rawValue))
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
            Text(error ?? L10n.format("Connecting to %@…", preferences.activeBrand.displayName))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }


    private var otherBrand: VehicleBrand { preferences.activeBrand == .polestar ? .volvo : .polestar }
    private var otherBrandResumable: Bool { preferences.hasResumableSession(for: otherBrand) }


    private func vehicleMenuLabel(_ car: CarSummary) -> String {
        let isActive = car.vin == activeVin
        let snapshot = isActive ? state : cachedSnapshots[car.vin]
        let baseTitle: String = {
            if let snap = snapshot {
                return preferences.formattedVehicleTitle(
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
        } else if let fuel = snapshot.fuelLevelPercent {
            label += " · \(Int(fuel))%"
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

    private func vehicleMenuLabel(state: VehicleState) -> String {
        let isActive = state.vin == activeVin
        let baseTitle = preferences.formattedVehicleTitle(
            vin: state.vin,
            modelName: state.modelName,
            modelYear: state.modelYear,
            registrationNo: state.registrationNo,
            fallbackBrand: state.model.brand
        )
        var label = baseTitle
        if let battery = state.batteryPercentage {
            label += " · \(Int(battery))%"
            if state.isCharging { label += "⚡" }
        } else if let fuel = state.fuelLevelPercent {
            label += " · \(Int(fuel))%"
        }
        let summary = state.stateSummary
        if summary.severity != .good {
            label += " · \(summary.message)"
        }
        if !isActive {
            label += " · \(Format.relativeAge(since: state.dataTimestamp))"
        }
        return label
    }

    private func vehicleMenuAccessibilityLabel(_ car: CarSummary, isSelected: Bool) -> String {
        let base = vehicleMenuLabel(car)
        return isSelected ? L10n.format("%@, selected", base) : base
    }

    private func vehicleMenuAccessibilityLabel(_ vehicle: VehicleState, isSelected: Bool) -> String {
        let base = vehicleMenuLabel(state: vehicle)
        return isSelected ? L10n.format("%@, selected", base) : base
    }

    private func otherBrandMenuLabel() -> String {
        let name = preferences.lastVehicleLabel(for: otherBrand)
        let vin = preferences.vin(for: otherBrand)
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
                return preferences.formattedVehicleTitle(
                    vin: state.vin,
                    modelName: state.modelName,
                    modelYear: state.modelYear,
                    registrationNo: state.registrationNo
                )
            }
            if let snap = cachedSnapshots[currentVin] {
                return preferences.formattedVehicleTitle(
                    vin: snap.vin,
                    modelName: snap.modelName,
                    modelYear: snap.modelYear,
                    registrationNo: snap.registrationNo
                )
            }
            if let currentCar {
                return currentCar.displayTitle()
            }
            return preferences.activeBrand.displayName
        }()
        let brandIcon = preferences.activeBrand == .polestar ? "bolt.car.fill" : "car.fill"
        let fleetStates = garageStates
        let hasMultipleVehicles = fleetStates.count > 1 || cars.count > 1

        return Menu {
            if fleetStates.count > 1 {
                ForEach(Array(fleetStates.enumerated().prefix(9)), id: \.element.vin) { index, vehicle in
                    let isSelected = vehicle.vin == currentVin
                    Button {
                        onSelectCar(vehicle.vin)
                    } label: {
                        Label(vehicleMenuLabel(state: vehicle), systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                    }
                    .accessibilityLabel(vehicleMenuAccessibilityLabel(vehicle, isSelected: isSelected))
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.option, .control])
                }
                ForEach(Array(fleetStates.enumerated().dropFirst(9)), id: \.element.vin) { _, vehicle in
                    let isSelected = vehicle.vin == currentVin
                    Button {
                        onSelectCar(vehicle.vin)
                    } label: {
                        Label(vehicleMenuLabel(state: vehicle), systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                    }
                    .accessibilityLabel(vehicleMenuAccessibilityLabel(vehicle, isSelected: isSelected))
                }
            } else if cars.count > 1 {
                ForEach(Array(cars.enumerated().prefix(9)), id: \.element.vin) { index, car in
                    let isSelected = car.vin == currentVin
                    Button {
                        onSelectCar(car.vin)
                    } label: {
                        Label(vehicleMenuLabel(car), systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                    }
                    .accessibilityLabel(vehicleMenuAccessibilityLabel(car, isSelected: isSelected))
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.option, .control])
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
            if otherBrandResumable, !fleetStates.contains(where: { $0.model.brand == otherBrand }) {
                if hasMultipleVehicles { Divider() }
                Button {
                    onSettingsChanged(.switchToBrand(otherBrand))
                } label: {
                    Label(otherBrandMenuLabel(), systemImage: "arrow.triangle.2.circlepath")
                }
            }
            Divider()
            Button {
                selectedTab = .settings
                tabSelection.wrappedValue = .settings
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
        .help(L10n.format("%@ — Switch Vehicle (⌃⌥[ / ⌃⌥])", currentTitle))
        .accessibilityLabel(L10n.format("Current vehicle: %@. Switch vehicle.", currentTitle))
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            if garageStates.count > 1 || cars.count > 1 || otherBrandResumable {
                vehicleSwitcher
            }
            // Data freshness indicator
            if let fetchedAt = state?.fetchedAt, state?.isStale() == false {
                let age = Date().timeIntervalSince(fetchedAt)
                let freshnessColor: Color = age < 30 ? .green : (age < 120 ? .yellow : .red)
                let ageText: String = age < 60 ? "\(Int(age))s" : "\(Int(age / 60))m"
                HStack(spacing: 3) {
                    Circle()
                        .fill(freshnessColor)
                        .frame(width: 6, height: 6)
                        .opacity(reduceMotion ? 1 : (age < 30 ? 1 : 0.6))
                    Text(ageText)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .help(L10n.format("Last updated %@", Format.dateTimeFormatter.string(from: fetchedAt)))
            }
            if diagnostics?.liveStreamConnected == true {
                HStack(spacing: 3) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                    Text(L10n.text("Live"))
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(HisingenTheme.semanticGood)
                .help(L10n.text("Connected to the Polestar server stream. Battery and exterior changes are applied as the provider sends them; scheduled polling remains as a reliability fallback."))
                .accessibilityLabel(L10n.text("Live vehicle stream connected"))
            } else if let retryAt = diagnostics?.liveStreamRetryAt {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help(L10n.format("Live stream disconnected. Retrying %@. Scheduled polling is still active.", Format.relativeAge(since: retryAt)))
                    .accessibilityLabel(L10n.text("Live vehicle stream reconnecting"))
            }
            Spacer()
            if let updateVersion, preferences.features.contains(.updateChecks) {
                Button {
                    onOpenUpdate()
                } label: {
                    Label("v\(updateVersion)", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tint)
                }
                .controlSize(.small)
                .withoutFocusRing()
            } else if preferences.features.contains(.updateChecks) {
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
