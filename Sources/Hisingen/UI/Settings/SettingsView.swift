import SwiftUI

@MainActor
struct SettingsView: View {
    let notificationPermission: NotificationPermission
    var state: VehicleState? = nil
    var fleet = FleetSnapshot()
    var database: VehicleDatabase = VehicleDatabase.shared
    var imageCache: CarImageCache = CarImageCache.shared
    /// When Settings is a tab, the panel's tab bar is the navigation and this header is not
    /// drawn. It survives for the full-panel presentation — before sign-in, and for an account
    /// with no snapshot yet — because there is no bar to leave by.
    var showsHeaderBar = true
    let onSettingsChanged: (SettingsChange) -> Void
    let onSignOut: () -> Void
    var onTestConnection: (VehicleBrand) async -> (success: Bool, message: String, failureKind: SignInFailureKind?) = { _ in
        (false, L10n.text("Connection testing is not available."), nil)
    }

    @State private var selectedSettingsSection = SettingsSection.all
    @State private var settingsSearchText = ""
    @State private var showEnableRemoteConfirmation = false
    @State private var persistLocationHistory = false
    @State private var prefsTick = 0
    @Environment(\.preferencesStore) private var preferences

    /// Section cards fade and settle from 98% – a nudge, not a zoom (scale floor 0.95).
    private static let sectionSwapTransition: AnyTransition =
        .opacity.combined(with: .scale(scale: 0.98))

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
            SettingsNavigationBar(
                selection: $selectedSettingsSection,
                searchText: $settingsSearchText
            )
            .padding(.horizontal, HisingenTheme.sectionSpacing)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: HisingenTheme.sectionSpacing) {
                    if shows(.accounts) {
                        Group {
                            accountCard
                            SettingsFleetCard(
                                fleet: fleet,
                                imageCache: imageCache,
                                binder: binder
                            )
                        }
                        .transition(Self.sectionSwapTransition)
                    }
                    if shows(.appearance) {
                        SettingsAppearanceCard(
                            state: state,
                            imageCache: imageCache,
                            binder: binder
                        )
                        .transition(Self.sectionSwapTransition)
                    }
                    if shows(.general) {
                        Group {
                            SettingsDisplayCard(state: state, binder: binder)
                            SettingsChargingStatOrderCard(binder: binder)
                        }
                        .transition(Self.sectionSwapTransition)
                    }
                    if shows(.tabsAndCards) {
                        SettingsTabsAndCardsCard(binder: binder, state: state)
                            .transition(Self.sectionSwapTransition)
                    }
                    if shows(.updates) {
                        SettingsUpdatesCard(binder: binder)
                            .transition(Self.sectionSwapTransition)
                    }
                    if shows(.features) {
                        Group {
                            featureQuickActions
                            CalendarPreconditioningSettingsCard(binder: binder)
                            SettingsChargingPlannerCard(binder: binder, state: state)
                            SettingsVehicleDataCard(state: state, binder: binder)
                            SettingsRemoteControlsCard(state: state, binder: binder)
                            SettingsCapabilityMatrixCard(state: state)
                        }
                        .transition(Self.sectionSwapTransition)
                    }
                    if shows(.notifications) {
                        SettingsNotificationsCard(
                            notificationPermission: notificationPermission,
                            state: state,
                            binder: binder
                        )
                        .transition(Self.sectionSwapTransition)
                    }
                    if shows(.privacyData) {
                        Group {
                            SettingsPrivacyCard(
                                persistLocationHistory: $persistLocationHistory,
                                binder: binder
                            )
                            SettingsDatabaseCard(
                                state: state,
                                database: database,
                                imageCache: imageCache,
                                persistLocationHistory: $persistLocationHistory
                            )
                        }
                        .transition(Self.sectionSwapTransition)
                    }
                    if shows(.about) {
                        Group {
                            SettingsActionsCard(binder: binder, onSignOut: onSignOut)
                            SettingsVersionFooter()
                        }
                        .transition(Self.sectionSwapTransition)
                    }

                    if !hasVisibleSection {
                        ContentUnavailableView(
                            L10n.text("No Settings Found"),
                            systemImage: "magnifyingglass",
                            description: Text(
                                L10n.text("Try a different search term or choose All.")
                            )
                        )
                        .padding(.vertical, 30)
                        .transition(.opacity)
                    }
                }
                .padding(HisingenTheme.sectionSpacing)
                .frame(maxWidth: .infinity)
                // Card insertions/removals are driven by section picks and search
                // edits; both ride Motion.cardChange so the swap reads as one system.
                .hisAnimation(Motion.cardChange, value: selectedSettingsSection)
                .hisAnimation(Motion.cardChange, value: settingsSearchText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            persistLocationHistory = preferences.persistLocationHistory
        }
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

    private func shows(_ section: SettingsSection) -> Bool {
        let selected = selectedSettingsSection == .all || selectedSettingsSection == section
        return selected && section.matches(settingsSearchText)
    }

    private var hasVisibleSection: Bool {
        SettingsSection.allCases
            .filter { $0 != .all }
            .contains(where: shows)
    }

    private var headerBar: some View {
        HStack {
            Button {
                onSettingsChanged(.closeSettings)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                    // The shell calls this tab "Vehicle"; two of Settings' three exits called it
                    // "Dashboard", so the reader was told they were going somewhere else.
                    Text(L10n.text("Vehicle"))
                }
                .hisType(.label, weight: .semibold)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            Text(L10n.text("Settings"))
                .hisType(.heading, weight: .bold)
                .foregroundStyle(HisingenTheme.ink)

            Spacer()

            Label(
                L10n.text("Changes save automatically"),
                systemImage: "checkmark.circle"
            )
            .hisType(.micro, weight: .medium)
            .foregroundStyle(.secondary)

            Button {
                onSettingsChanged(.closeSettings)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .hisType(.subhead)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.pressable)
            .help(L10n.text("Back to Vehicle"))
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private var accountCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(
                    symbol: "person.crop.circle",
                    title: L10n.text("Account"),
                    color: .accentColor
                )
                AccountCredentialsForm(
                    style: .compact,
                    onSettingsChanged: onSettingsChanged,
                    onTestConnection: onTestConnection
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
                    Image(systemName: "sparkles")
                    Text(L10n.text("Add Recommended"))
                }
                .hisType(.label, weight: .semibold)
                .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.borderedProminent)
            .tint(HisingenTheme.accent)
            .foregroundStyle(HisingenTheme.accentOn)
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
            .buttonStyle(.bordered)
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
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
