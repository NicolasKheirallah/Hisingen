import SwiftUI

@MainActor
struct SettingsView: View {
    let notificationPermission: NotificationPermission
    var state: VehicleState? = nil
    var refreshError: String? = nil
    var fleet = FleetSnapshot()
    var database: VehicleDatabase = VehicleDatabase.shared
    var imageCache: CarImageCache = CarImageCache.shared
    /// When Settings is a tab, the panel's tab bar is the navigation and this header is not
    /// drawn. It survives for the full-panel presentation — before sign-in, and for an account
    /// with no snapshot yet — because there is no bar to leave by.
    var showsHeaderBar = true
    let onSettingsChanged: (SettingsChange) -> Void
    let onSignOut: (SignOutSelection) -> Void
    /// A live fleet read for the sign-out confirmation. The `fleet` value is a snapshot taken
    /// when the window was built; a car discovered later must still change the copy.
    var liveFleet: (@MainActor () -> FleetSnapshot)? = nil
    let accountConnection: AccountConnectionModel
    var onTestConnection: (VehicleBrand) async -> ConnectionCheck = { _ in
        ConnectionCheck(success: false, message: L10n.text("Connection testing is not available."), failureKind: nil)
    }

    var destination: SettingsDestination? = nil
    var onNavigateToPlan: ((TabItemID) -> Void)? = nil
    var onOpenHistory: (() -> Void)? = nil

    @State private var pendingDestination: SettingsDestination?
    @State private var focusPlannerAlerts = false
    @State private var selectedSettingsSection = SettingsSection.all
    @State private var settingsSearchText = ""
    @State private var showEnableRemoteConfirmation = false
    @State private var prefsTick = 0
    @Environment(\.preferencesStore) private var preferences
    @Environment(\.homeCharging) private var homeCharging

    /// Native text fields and segmented controls must not join an implicit section transition.
    /// AppKit rounds interpolated fitting widths independently, which can briefly invert
    /// SwiftUI's min/max constraints. The moving section indicator carries the continuity while
    /// the destination content swaps at its final geometry.
    private static let sectionSwapTransition: AnyTransition = .identity

    private var binder: PreferenceBinder {
        PreferenceBinder(
            preferences: preferences,
            notify: onSettingsChanged,
            bump: { prefsTick &+= 1 }
        )
    }

    var body: some View {
        let _ = prefsTick
        VStack(spacing: 10) {
            if showsHeaderBar {
                headerBar
            }
            if !showsHeaderBar || HisingenTheme.layoutWidth >= 800 {
                HStack(spacing: 0) {
                    SettingsSidebar(
                        selection: $selectedSettingsSection,
                        searchText: $settingsSearchText
                    )
                    .frame(width: HisingenTheme.layoutWidth < 600 ? 154 : 238)
                    Divider()
                    settingsContent
                }
            } else {
                SettingsNavigationBar(
                    selection: $selectedSettingsSection,
                    searchText: $settingsSearchText
                )
                .padding(.horizontal, HisingenTheme.sectionSpacing)
                settingsContent
            }
        }
        .frame(maxWidth: showsHeaderBar ? HisingenTheme.layoutWidth : .infinity, maxHeight: .infinity)
        .background(HisingenTheme.canvas)
        .confirmationDialog(
            L10n.text("Enable every remote-control feature?"),
            isPresented: $showEnableRemoteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("Enable Remote Controls")) {
                var updated = preferences.features
                for feature in AppFeature.remoteFeatures {
                    updated.set(feature, enabled: true)
                }
                preferences.features = updated
                prefsTick &+= 1
                onSettingsChanged(.features)
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("Remote features can change charging, climate, locks, windows, and vehicle software. Each command still requires an explicit action."))
        }
    }

    private var availableDestinations: [SettingsDestination] {
        SettingsDestination.allCases.filter {
            switch $0 {
            case .plannerSettings, .plannerAlerts: preferences.marketCountry.offersMarketPricing
            case .homeCharging, .electricitySupplier, .gridTariff, .houseMeter: homeCharging != nil
            default: true
            }
        }
    }

    private var isSearching: Bool {
        !SettingsDestination.searchTerms(settingsSearchText).isEmpty
    }

    private var visibleDestinations: [SettingsDestination] {
        let destinations = availableDestinations
        guard isSearching else {
            return destinations.filter {
                let matchesSection = selectedSettingsSection == .all || $0.section == selectedSettingsSection
                switch $0 {
                case .plannerAlerts: return matchesSection && focusPlannerAlerts
                case .notifications: return matchesSection && !focusPlannerAlerts
                default: return matchesSection
                }
            }
        }

        let query = SettingsDestination.searchTerms(settingsSearchText)
        return destinations.filter { target in
            let names = SettingsDestination.searchTerms(target.section.title)
            let matchesSection = query.allSatisfy { term in names.contains { $0.hasPrefix(term) } }
            if target == .plannerAlerts && matchesSection { return false }
            return matchesSection || target.matches(settingsSearchText)
        }
    }

    private func open(_ target: SettingsDestination) {
        settingsSearchText = ""
        let available = availableDestinations
        focusPlannerAlerts = target == .plannerAlerts && available.contains(target)
        selectedSettingsSection = target.section
        pendingDestination = available.contains(target) ? target : available.first { $0.section == target.section }
    }

    private var settingsContent: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: HisingenTheme.sectionSpacing) {
                    ForEach(visibleDestinations) { target in
                        destinationView(target)
                            .id(target)
                            .transition(Self.sectionSwapTransition)
                    }

                    if visibleDestinations.isEmpty {
                        ContentUnavailableView(
                            L10n.text("No Settings Found"),
                            systemImage: "magnifyingglass",
                            description: Text(L10n.text("Try a different search term or choose All."))
                        )
                        .padding(.vertical, 30)
                    }
                }
                .padding(HisingenTheme.sectionSpacing)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: destination, initial: true) { _, target in
                if let target { open(target) }
            }
            .task(id: pendingDestination) {
                guard let pendingDestination else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                proxy.scrollTo(pendingDestination, anchor: .top)
                self.pendingDestination = nil
            }
            .onChange(of: visibleDestinations) { _, destinations in
                if isSearching, let first = destinations.first { proxy.scrollTo(first, anchor: .top) }
            }
            .onChange(of: selectedSettingsSection) { _, _ in
                if isSearching { settingsSearchText = "" }
                guard pendingDestination == nil else { return }
                focusPlannerAlerts = false
                guard let first = visibleDestinations.first else { return }
                proxy.scrollTo(first, anchor: .top)
            }
        }
    }

    @ViewBuilder
    private func destinationView(_ target: SettingsDestination) -> some View {
        switch target {
        case .account:
            accountCard
        case .remoteAuthorization:
            SettingsRemoteAuthorizationCard(binder: binder)
        case .garage:
            SettingsFleetCard(fleet: fleet, imageCache: imageCache, binder: binder)
        case .vehicleReferences:
            SettingsVehicleReferencesCard(state: state, binder: binder)
        case .appearance:
            SettingsAppearanceCard(
                state: state, imageCache: imageCache, binder: binder,
                group: .themes, onOpenGarage: { open(.garage) }
            )
        case .vehicleAppearance:
            SettingsAppearanceCard(state: state, imageCache: imageCache, binder: binder, group: .vehicle)
        case .menuBar:
            SettingsAppearanceCard(state: state, imageCache: imageCache, binder: binder, group: .menuBar)
        case .panel:
            SettingsAppearanceCard(state: state, imageCache: imageCache, binder: binder, group: .panel)
        case .general:
            SettingsDisplayCard(binder: binder)
        case .electricity:
            if let homeCharging {
                SettingsElectricityWithSupplier(model: homeCharging, binder: binder, state: state)
            } else {
                SettingsElectricityCard(binder: binder, state: state)
            }
        case .plannerSettings:
            let action: (() -> Void)? = onNavigateToPlan.map { navigate in { navigate(.controlsRoutines) } }
            SettingsChargingPlannerCard(binder: binder, onOpenAutomation: action)
        case .homeCharging:
            if let homeCharging {
                VStack(alignment: .leading, spacing: HisingenTheme.sectionSpacing) {
                    if !isSearching {
                        Text(L10n.text("Connected Services"))
                            .hisType(.heading)
                            .accessibilityAddTraits(.isHeader)
                    }
                    SettingsHomeChargingCard(model: homeCharging, state: state, fleet: fleet, binder: binder)
                }
            }
        case .electricitySupplier:
            if let homeCharging { SettingsTibberCard(model: homeCharging, preferences: binder.preferences) }
        case .gridTariff:
            if let homeCharging {
                SettingsGridTariffCard(
                    model: homeCharging,
                    onOpenSupplier: isSearching ? { open(.electricitySupplier) } : nil
                )
            }
        case .houseMeter:
            if let homeCharging { SettingsHouseMeterCard(meter: homeCharging.houseMeter) }
        case .tabLayout:
            SettingsTabsAndCardsCard(
                binder: binder, state: state, refreshError: refreshError,
                onOpenFeatureSettings: { open(SettingsDestination.owner(of: $0)) },
                onOpenCardSettings: { open($0) }
            )
        case .nowControls:
            Card { SettingsNowControls(binder: binder, state: state) }
        case .chargingLayout:
            SettingsChargingStatOrderCard(binder: binder)
        case .vehicleData:
            VStack(spacing: HisingenTheme.sectionSpacing) {
                if !isSearching { featureQuickActions }
                SettingsVehicleDataCard(state: state, binder: binder)
            }
        case .remoteFeatures:
            SettingsRemoteControlsCard(
                state: state, binder: binder, onOpenAuthorization: { open(.remoteAuthorization) }
            )
        case .vehicleCapabilities:
            SettingsCapabilityMatrixCard(state: state)
        case .automation:
            if let onNavigateToPlan {
                NavigationRow(title: L10n.text("Open Plan Automations")) { onNavigateToPlan(.controlsRoutines) }
            } else {
                CalendarPreconditioningSettingsCard(binder: binder)
                if preferences.smartChargingPlannerAvailable || preferences.plannerAutoStartEnabled {
                    Card { PlannerAutoStartControl(binder: binder) }
                }
            }
        case .notifications, .plannerAlerts:
            VStack(alignment: .leading, spacing: 8) {
                if target == .plannerAlerts {
                    NavigationRow(title: L10n.text("All Notifications")) { open(.notifications) }
                }
                SettingsNotificationsCard(
                    notificationPermission: notificationPermission,
                    state: state,
                    binder: binder,
                    plannerAlertsOnly: target == .plannerAlerts
                )
            }
        case .privacy:
            SettingsPrivacyCard(binder: binder)
        case .localData:
            SettingsDatabaseCard(
                state: state,
                database: database,
                imageCache: imageCache,
                onExportDiagnosticLogs: { onSettingsChanged(.exportDiagnosticLogs) },
                onPresentationChanged: { onSettingsChanged(.presentation) },
                onOpenHistory: onOpenHistory
            )
        case .backup:
            SettingsActionsCard(binder: binder)
        case .updates:
            VStack(spacing: HisingenTheme.sectionSpacing) {
                SettingsUpdatesCard(binder: binder)
                SettingsVersionFooter()
            }
        }
    }

    private var headerBar: some View {
        HStack {
            Button {
                onSettingsChanged(.closeSettings)
            } label: {
                Label(L10n.text("Back"), systemImage: "chevron.left")
                    .hisType(.label, weight: .semibold)
            }
            .buttonStyle(.hisSecondary)
            .controlSize(.small)

            Text(L10n.text("Settings"))
                .hisType(.heading, weight: .bold)
                .foregroundStyle(HisingenTheme.ink)
                .accessibilityAddTraits(.isHeader)

            Spacer()
        }
        .padding(.horizontal, HisingenTheme.sectionSpacing)
        .padding(.top, 2)
    }

    private var accountCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(
                    symbol: "person.crop.circle",
                    title: L10n.text("Account"),
                    color: HisingenTheme.accent
                )
                AccountCredentialsForm(
                    style: .compact,
                    onSettingsChanged: onSettingsChanged,
                    onTestConnection: onTestConnection,
                    model: accountConnection
                )
                Divider().opacity(HisingenTheme.dividerOpacity)
                SettingsSignOutButton(
                    binder: binder,
                    onSignOut: onSignOut,
                    fleetProvider: liveFleet ?? { fleet }
                )
            }
        }
    }

    private var featureQuickActions: some View {
        HStack(spacing: 8) {
            // Both bulk actions are additive. Each used to *assign* a whole new selection, so
            // "Recommended" switched off all eight remote-control features for a reader who had
            // them on, and "Enable All Safe Features" — labelled and iconed as purely additive —
            // turned every remote control off by construction, because that is what its set
            // excludes. A convenience action may add; it may not silently take away.
            Button {
                preferences.features = preferences.features
                    .adding(FeatureSelection.default.enabled)
                prefsTick &+= 1
                onSettingsChanged(.features)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                    Text(L10n.text("Add Recommended"))
                }
                .hisType(.label, weight: .semibold)
                .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.hisProminent(HisingenTheme.accent))
            .controlSize(.small)

            Button {
                preferences.features = preferences.features
                    .adding(AppFeature.safeBulkEnableCases)
                prefsTick &+= 1
                onSettingsChanged(.features)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                    Text(L10n.text("Add All Safe Features"))
                }
                .hisType(.label, weight: .medium)
                .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.hisSecondary)
            .controlSize(.small)

            Button {
                showEnableRemoteConfirmation = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "key.horizontal")
                    Text(L10n.text("Enable Remote Controls"))
                }
                .hisType(.label, weight: .medium)
                .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.hisSecondary)
            .controlSize(.small)
        }
    }
}
