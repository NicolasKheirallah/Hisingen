import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsChange {
    case credentials
    case features
    case notifications
    case presentation
    case launchAtLogin
    case updater
    case checkForUpdates
    case volvoSignIn(clientID: String, clientSecret: String, vccApiKey: String, nickname: String)
    case polestarCommandAuthorization
    case polestarWebSignIn
    case switchToBrand(VehicleBrand)
    case selectVehicle(String)
    case closeSettings
}

/// Shared plumbing so a card extracted into its own `View` keeps the `binder(\.key, .change)`
/// ergonomics without carrying a local `@State` mirror. Writes go straight through
/// `PreferencesStore`'s own setter (where side effects like `applyAppearance()` live), then
/// `bump()` re-renders the settings composition (covering same-screen mirrored readouts) and
/// `change`, when given, is forwarded to `onSettingsChanged`.
@MainActor
struct PreferenceBinder {
    let preferences: PreferencesStore
    let notify: (SettingsChange) -> Void
    let bump: () -> Void

    func callAsFunction<Value>(
        _ keyPath: ReferenceWritableKeyPath<PreferencesStore, Value>,
        _ change: SettingsChange? = nil
    ) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { newValue in
                preferences[keyPath: keyPath] = newValue
                bump()
                if let change { notify(change) }
            }
        )
    }
}


@MainActor
struct SettingsView: View {
    let notificationPermission: NotificationPermission
    var state: VehicleState? = nil
    var cachedSnapshots: [String: VehicleState] = [:]
    var database: VehicleDatabase = VehicleDatabase.shared
    var imageCache: CarImageCache = CarImageCache.shared
    let onSettingsChanged: (SettingsChange) -> Void
    let onSignOut: () -> Void
    var onTestConnection: (VehicleBrand) async -> (success: Bool, message: String) = { _ in
        (false, L10n.text("Connection testing is not available."))
    }

    // Presentation, notification, and updater preferences bind straight to `PreferencesStore`
    // through `bind(_:_:)` below — no local `@State` mirror, no `.onAppear` seed. Only state
    // that needs bespoke handling (animation, cross-field cascades, debounced text parsing,
    // value types, or a child-managed confirmation flow) keeps a local mirror here.
    @State private var appTheme: AppTheme = .hisingen
    @State private var appearanceMode: AppearanceMode = .system
    @State private var carRenderAngle: CarRenderAngle = .frontThreeQuarter
    @State private var panelSize = PanelSize.standard
    @State private var contentDensity = ContentDensity.standard
    @State private var customSizeEnabled = false
    @State private var customWidth: Double = 0
    @State private var customHeight: Double = 0

    /// What the panel currently resolves to with these draft settings — drives the
    /// proportion preview and dimension readout live, including slider drags.
    private var resolvedLayout: PanelLayout {
        PanelLayout.resolve(
            panelSizeRaw: panelSize.rawValue,
            densityRaw: contentDensity.rawValue,
            customEnabled: customSizeEnabled,
            customWidth: customWidth,
            customHeight: customHeight
        )
    }

    private func resetPanelGeometry() {
        panelSize = .standard
        contentDensity = .standard
        customSizeEnabled = false
        customWidth = Double(PanelSize.standard.width)
        customHeight = Double(PanelSize.standard.idealHeight)
        preferences.panelSize = .standard
        preferences.contentDensity = .standard
        preferences.customPanelSizeEnabled = false
        preferences.customPanelWidth = customWidth
        preferences.customPanelHeight = customHeight
        onSettingsChanged(.presentation)
    }
    @State private var distanceUnit = DistanceUnit.kilometers
    @State private var temperatureUnit = TemperatureUnit.celsius
    @State private var pressureUnit = PressureUnit.kilopascals
    @State private var fuelVolumeUnit = FuelVolumeUnit.liters
    @State private var fuelEconomyUnit = FuelEconomyUnit.litersPer100Km
    @State private var energyConsumptionUnit = EnergyConsumptionUnit.kwhPer100Km
    @State private var selectedThemeCategory: ThemeCategory = .all
    @State private var electricityPrice = "2.00"
    @State private var currencySymbol = "kr"
    @State private var nightElectricityPrice = "2.00"
    @State private var persistLocationHistory = false
    @State private var selectedSettingsSection = SettingsSection.all
    @State private var settingsSearchText = ""
    @State private var showEnableRemoteConfirmation = false
    @State private var showSignOutConfirmation = false
    @State private var pendingSettingsImport: Data?
    @State private var showSettingsImportConfirmation = false
    @State private var showSettingsResetConfirmation = false
    @State private var settingsTransferFeedback: (message: String, isError: Bool)?
    @Environment(\.preferencesStore) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var settingsVehicleVIN: String { state?.vin ?? preferences.vin }

    /// Bumped by every `bind(...)` write so the settings screen re-renders immediately —
    /// covers same-screen mirrored readouts (e.g. the Privacy Dashboard rows) whose source
    /// control lives in another card and does not itself fire `onSettingsChanged`.
    @State private var prefsTick = 0

    /// The binder handed to extracted card views; also backs the local `bind(...)` shorthand.
    private var binder: PreferenceBinder {
        PreferenceBinder(preferences: preferences, notify: onSettingsChanged, bump: { prefsTick &+= 1 })
    }

    /// Live binding straight through to `PreferencesStore`, replacing a local `@State` mirror
    /// plus its `.onAppear` seed and `.onChange` write-back.
    private func bind<Value>(
        _ keyPath: ReferenceWritableKeyPath<PreferencesStore, Value>,
        _ change: SettingsChange? = nil
    ) -> Binding<Value> {
        binder(keyPath, change)
    }

    private var availableRenderAngles: [CarRenderAngle] {
        CarRenderAngle.allCases.filter {
            imageCache.hasImage(for: settingsVehicleVIN, angle: $0.rawValue)
        }
    }

    var body: some View {
        // Read `prefsTick` so a `bind(...)` write forces a re-render even when it fires no
        // `onSettingsChanged` (night-tariff, biometrics) — those used to re-render via their
        // now-removed `@State` mirror, and their values are still mirrored elsewhere on screen.
        let _ = prefsTick
        return VStack(spacing: 10) {
            headerBar
            SettingsNavigationBar(selection: $selectedSettingsSection, searchText: $settingsSearchText)
                .padding(.horizontal, HisingenTheme.sectionSpacing)

            ScrollView(.vertical, showsIndicators: false) {
                // Eager VStack: the settings screen has a small, bounded set of
                // heavyweight cards. LazyVStack rebuilt them on every scroll tick,
                // which froze scrolling — a plain VStack builds them once on open.
                VStack(spacing: HisingenTheme.sectionSpacing) {
                    if shows(.accounts) {
                        accountCard
                        SettingsFleetCard(
                            state: state,
                            cachedSnapshots: cachedSnapshots,
                            database: database,
                            imageCache: imageCache,
                            binder: binder
                        )
                    }
                    if shows(.appearance) { appearanceCard }
                    if shows(.general) { displayCard; SettingsChargingStatOrderCard(binder: binder) }
                    if shows(.updates) { SettingsUpdatesCard(binder: binder) }
                    if shows(.features) {
                        featureQuickActions
                        SettingsVehicleDataCard(state: state, binder: binder)
                        SettingsRemoteControlsCard(state: state, binder: binder)
                        SettingsCapabilityMatrixCard(state: state)
                    }
                    if shows(.notifications) {
                        SettingsNotificationsCard(
                            notificationPermission: notificationPermission,
                            state: state,
                            binder: binder
                        )
                    }
                    if shows(.privacyData) {
                        privacyDashboardCard
                        SettingsDatabaseCard(
                            state: state,
                            database: database,
                            persistLocationHistory: $persistLocationHistory
                        )
                    }
                    if shows(.about) { actionsCard; SettingsVersionFooter() }

                    if !hasVisibleSection {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Only the state that still keeps a local mirror is seeded here; everything else
            // reads live through `bind(_:_:)`.
            appTheme = preferences.appTheme
            appearanceMode = preferences.appearanceMode
            carRenderAngle = preferences.carRenderAngle
            if let firstAvailable = availableRenderAngles.first,
               !availableRenderAngles.contains(preferences.carRenderAngle) {
                carRenderAngle = firstAvailable
                preferences.carRenderAngle = firstAvailable
            }
            panelSize = preferences.panelSize
            contentDensity = preferences.contentDensity
            customSizeEnabled = preferences.customPanelSizeEnabled
            customWidth = preferences.customPanelWidth > 0 ? preferences.customPanelWidth : Double(PanelSize.standard.width)
            customHeight = preferences.customPanelHeight > 0 ? preferences.customPanelHeight : Double(PanelSize.standard.idealHeight)
            distanceUnit = preferences.distanceUnit
            temperatureUnit = preferences.temperatureUnit
            pressureUnit = preferences.pressureUnit
            fuelVolumeUnit = preferences.fuelVolumeUnit
            fuelEconomyUnit = preferences.fuelEconomyUnit
            energyConsumptionUnit = preferences.energyConsumptionUnit
            electricityPrice = String(format: "%.2f", preferences.electricityPricePerKwh)
            currencySymbol = preferences.currencySymbol
            nightElectricityPrice = String(format: "%.2f", preferences.nightElectricityPricePerKwh)
            persistLocationHistory = preferences.persistLocationHistory
        }
        .confirmationDialog(
            L10n.text("Enable every remote-control feature?"),
            isPresented: $showEnableRemoteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("Enable Remote Controls")) {
                var updated = preferences.features
                for feature in AppFeature.remoteFeatures { updated.set(feature, enabled: true) }
                preferences.features = updated
                prefsTick &+= 1
                onSettingsChanged(.features)
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("Remote features can change charging, climate, locks, windows, and vehicle software. Each command still requires an explicit action."))
        }
        .confirmationDialog(
            L10n.format("Sign out of %@?", preferences.activeBrand.displayName),
            isPresented: $showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("Sign Out & Remove Session"), role: .destructive) { onSignOut() }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("The saved session and account credentials for this provider will be removed from this Mac. Local vehicle history is kept."))
        }
        .confirmationDialog(
            L10n.text("Import these settings?"),
            isPresented: $showSettingsImportConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("Import & Replace Settings"), role: .destructive) { applyPendingSettingsImport() }
            Button(L10n.text("Cancel"), role: .cancel) { pendingSettingsImport = nil }
        } message: {
            Text(L10n.text("Presentation, feature, update, and notification preferences will be replaced. Accounts, sessions, vehicles, and history are not included."))
        }
        .confirmationDialog(
            L10n.text("Reset app preferences?"),
            isPresented: $showSettingsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("Reset Preferences"), role: .destructive) {
                preferences.resetTransferableSettings()
                notifyAllPreferenceSubsystems()
                onSettingsChanged(.closeSettings)
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("Presentation, feature, update, and notification preferences return to defaults. Accounts, sessions, vehicles, and history are kept."))
        }
    }

    private func shows(_ section: SettingsSection) -> Bool {
        let selected = selectedSettingsSection == .all || selectedSettingsSection == section
        return selected && section.matches(settingsSearchText)
    }

    private var hasVisibleSection: Bool {
        SettingsSection.allCases.filter { $0 != .all }.contains(where: shows)
    }


    private var headerBar: some View {
        HStack {
            Button {
                onSettingsChanged(.closeSettings)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                    Text(L10n.text("Dashboard"))
                }
                .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            Text(L10n.text("Settings"))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(HisingenTheme.ink)

            Spacer()

            Label(L10n.text("Changes save automatically"), systemImage: "checkmark.circle")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)

            Button {
                onSettingsChanged(.closeSettings)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.text("Back to Dashboard"))
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }


    private var accountCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(symbol: "person.crop.circle", title: L10n.text("Account"), color: .accentColor)
                AccountCredentialsForm(style: .compact, onSettingsChanged: onSettingsChanged,
                                        onTestConnection: onTestConnection)
            }
        }
    }

    private var filteredThemes: [AppTheme] {
        if selectedThemeCategory == .all {
            return AppTheme.allCases
        }
        return AppTheme.allCases.filter { $0.category == selectedThemeCategory }
    }

    private func themeCategoryCount(_ cat: ThemeCategory) -> Int {
        if cat == .all { return AppTheme.allCases.count }
        return AppTheme.allCases.filter { $0.category == cat }.count
    }

    private var appearanceCard: some View {
        let vehicleLabel = preferences.lastVehicleLabel(for: preferences.activeBrand)
        let availableAngles = availableRenderAngles
        let supportsMultipleAngles = availableAngles.count > 1
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CardHeader(symbol: "paintpalette.fill", title: L10n.text("Appearance & Themes"), color: HisingenTheme.accent)
                    Spacer()
                    Text(L10n.format("%d Themes", AppTheme.allCases.count))
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(HisingenTheme.accent.opacity(0.12), in: Capsule())
                        .foregroundStyle(HisingenTheme.accent)
                }

                // Appearance Mode Selector (System / Light / Dark)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Screenshot Privacy Mode"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(HisingenTheme.ink)
                            Text(L10n.text("Blurs VIN, plate and coordinates across the app for safe sharing."))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: bind(\.privacyRedactionEnabled, .presentation))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityLabel(L10n.text("Screenshot Privacy Mode"))
                    }
                    .padding(.vertical, 2)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Floating Charging Panel"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(HisingenTheme.ink)
                            Text(L10n.text("Small always-on-top panel with charge progress while plugged in."))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: bind(\.floatingChargingPanelEnabled, .presentation))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityLabel(L10n.text("Floating Charging Panel"))
                    }
                    .padding(.vertical, 2)

                    Text(L10n.text("Mode"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HisingenTheme.ink)

                    HStack(spacing: 8) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            let isModeSelected = appearanceMode == mode
                            Button {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: Motion.fast)) {
                                    appearanceMode = mode
                                    preferences.appearanceMode = mode
                                }
                                onSettingsChanged(.presentation)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: mode.symbol)
                                        .font(.system(size: 11, weight: isModeSelected ? .semibold : .regular))
                                    Text(mode.title)
                                        .font(.system(size: 11, weight: isModeSelected ? .semibold : .regular))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(
                                    isModeSelected ? HisingenTheme.accent.opacity(0.16) : Color.primary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(isModeSelected ? HisingenTheme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
                                )
                                .foregroundStyle(isModeSelected ? HisingenTheme.accent : HisingenTheme.ink)
                            }
                            .buttonStyle(.plain)
                            .withoutFocusRing()
                        }
                    }
                }

                // Vehicle Image Perspective & Studio Render Preview
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.text(supportsMultipleAngles ? "Vehicle Perspective" : "Vehicle Image"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(HisingenTheme.ink)
                        Spacer()
                        if supportsMultipleAngles {
                            Text(carRenderAngle.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Live Studio Render Preview (Async Decoded & Cached)
                    SettingsStudioRenderPreview(
                        vin: settingsVehicleVIN,
                        angle: supportsMultipleAngles ? carRenderAngle.rawValue : (availableAngles.first?.rawValue ?? 0),
                        imageCache: imageCache
                    )

                    if supportsMultipleAngles {
                        let angleChunks = stride(from: 0, to: availableAngles.count, by: 2).map {
                            Array(availableAngles[$0..<min($0 + 2, availableAngles.count)])
                        }
                        VStack(spacing: 8) {
                            ForEach(0..<angleChunks.count, id: \.self) { rowIdx in
                                let row = angleChunks[rowIdx]
                                HStack(spacing: 8) {
                                    ForEach(row, id: \.self) { angle in
                                        let isAngleSelected = carRenderAngle == angle
                                        Button {
                                            withAnimation(reduceMotion ? nil : .easeInOut(duration: Motion.fast)) {
                                                carRenderAngle = angle
                                                preferences.carRenderAngle = angle
                                            }
                                            onSettingsChanged(.presentation)
                                        } label: {
                                            HStack(spacing: 5) {
                                                Image(systemName: angle.symbol)
                                                    .font(.system(size: 11, weight: isAngleSelected ? .semibold : .regular))
                                                Text(angle.title)
                                                    .font(.system(size: 11, weight: isAngleSelected ? .semibold : .regular))
                                                    .lineLimit(1)
                                            }
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 6)
                                            .padding(.horizontal, 4)
                                            .background(
                                                isAngleSelected ? HisingenTheme.accent.opacity(0.16) : Color.primary.opacity(0.04),
                                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                    .stroke(isAngleSelected ? HisingenTheme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
                                            )
                                            .foregroundStyle(isAngleSelected ? HisingenTheme.accent : HisingenTheme.ink)
                                        }
                                        .buttonStyle(.plain)
                                        .withoutFocusRing()
                                    }
                                    if row.count == 1 {
                                        Spacer().frame(maxWidth: .infinity)
                                    }
                                }
                            }
                        }
                    }
                }

                Divider().opacity(0.4)

                Text(L10n.format("Active for %@ — each vehicle saves its own theme preference.", vehicleLabel))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)

                // Category Filter Pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ThemeCategory.allCases, id: \.self) { cat in
                            categoryFilterButton(cat)
                        }
                    }
                    .padding(.vertical, 2)
                }

                // 2-Column Responsive Grid of Themes
                let themeChunks = stride(from: 0, to: filteredThemes.count, by: 2).map {
                    Array(filteredThemes[$0..<min($0 + 2, filteredThemes.count)])
                }
                VStack(spacing: 8) {
                    ForEach(0..<themeChunks.count, id: \.self) { rowIdx in
                        let row = themeChunks[rowIdx]
                        HStack(spacing: 8) {
                            ForEach(row, id: \.self) { theme in
                                themeTile(theme)
                            }
                            if row.count == 1 {
                                Spacer().frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
    }

    private func categoryFilterButton(_ cat: ThemeCategory) -> some View {
        let isSelected = selectedThemeCategory == cat
        let count = themeCategoryCount(cat)
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: Motion.fast)) {
                selectedThemeCategory = cat
            }
        } label: {
            HStack(spacing: 4) {
                Text(cat.title)
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.85)
            }
            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                isSelected ? HisingenTheme.accent.opacity(0.18) : Color.primary.opacity(0.05),
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(isSelected ? HisingenTheme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? HisingenTheme.accent : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func themeTile(_ theme: AppTheme) -> some View {
        let isSelected = appTheme == theme
        let accentColor = Color(hex: theme.accentColorHex) ?? HisingenTheme.accent
        return Button {
            guard appTheme != theme else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: Motion.fast)) {
                appTheme = theme
                preferences.appTheme = theme
            }
            onSettingsChanged(.presentation)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    HStack(spacing: 3) {
                        ForEach(theme.previewHexColors, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex) ?? Color.gray)
                                .frame(width: 8, height: 8)
                        }
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(accentColor)
                    } else {
                        Circle()
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            .frame(width: 12, height: 12)
                    }
                }

                Text(theme.title)
                    .font(.system(size: 11.5, weight: isSelected ? .bold : .semibold))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                    .lineLimit(1)

                Text(theme.subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? accentColor.opacity(0.08) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected ? accentColor.opacity(0.6) : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(theme.title): \(theme.subtitle)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var displayCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(symbol: "display", title: L10n.text("General"), color: .blue)

                VStack(spacing: 10) {
                    HStack {
                        Text(L10n.text("Language"))
                            .font(.system(size: 12))
                        Spacer()
                        Picker("", selection: bind(\.interfaceLanguage, .presentation)) {
                            ForEach(InterfaceLanguage.allCases, id: \.self) { language in
                                Text(language.title).tag(language)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 160)
                    }

                    Divider().opacity(0.4)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Model badge position"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("Placement of model & year label"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: bind(\.vehicleModelBadgePosition, .presentation)) {
                            ForEach(VehicleModelBadgePosition.allCases, id: \.self) { pos in
                                Text(pos.title).tag(pos)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 160)
                    }

                    Divider().opacity(0.4)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("License plate position"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("Placement of registration plate"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: bind(\.registrationBadgePosition, .presentation)) {
                            ForEach(RegistrationNumberBadgePosition.allCases, id: \.self) { pos in
                                Text(pos.title).tag(pos)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 160)
                    }

                    Divider().opacity(0.4)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Vehicle display name"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("Shown in footer switcher, menus, and vehicle headers"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: bind(\.vehicleLabelFormat, .presentation)) {
                            ForEach(VehicleLabelFormat.allCases, id: \.self) { format in
                                Text(format.title).tag(format)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 160)
                    }

                    let previewTitle = preferences.formattedVehicleTitle(
                        vin: preferences.vin.isEmpty ? "YS2TESTVIN123456" : preferences.vin,
                        modelName: state?.modelName ?? (preferences.activeBrand == .polestar ? "Polestar 2" : "Volvo EX40"),
                        modelYear: state?.modelYear ?? "2024",
                        registrationNo: state?.registrationNo ?? "ZCJ 06G",
                        format: preferences.vehicleLabelFormat
                    )
                    HStack(spacing: 6) {
                        Text(L10n.text("Preview:"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Image(systemName: preferences.activeBrand == .polestar ? "bolt.car.fill" : "car.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(HisingenTheme.accent)
                            Text(previewTitle)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        Spacer()
                    }
                    .padding(.vertical, 2)

                    Divider().opacity(0.4)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Charging Session History"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("Keep up to 20 local per-vehicle charging summaries"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: bind(\.storeChargingHistory, .presentation))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    Divider().opacity(0.4)

                    HStack {
                        Text(L10n.text("Menu bar display"))
                            .font(.system(size: 12))
                        Spacer()
                        Picker("", selection: bind(\.menuBarStyle, .presentation)) {
                            ForEach(MenuBarStyle.allCases, id: \.self) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 160)
                    }


                    let previewSample = VehicleState(
                        batteryPercentage: 82, rangeKm: 348, chargingState: .charging,
                        estimatedChargingTimeToFullMinutes: 102, chargeTargetPercentage: 90,
                        chargingPowerWatts: 7200, chargingCurrentAmps: 16, chargingVoltageVolts: 230,
                        chargingType: .ac, chargerConnection: .connected, availability: .available,
                        modelName: "Polestar 2", modelYear: "2024", registrationNo: nil, vin: "YSMTEST",
                        ownerFirstName: nil, odometerKm: 12500, daysToService: nil, distanceToServiceKm: nil,
                        serviceWarning: false, fluidWarnings: [],
                        exteriorStatus: ExteriorSnapshot(openings: [], isLocked: false, alarmTriggered: false),
                        imageData: nil, fetchedAt: Date(), vehicleReportedAt: Date(), dataWarnings: []
                    )
                    let previewText = Format.barTitle(for: previewSample, style: preferences.menuBarStyle, unit: distanceUnit)
                    let previewIcon = Format.icon(for: previewSample)
                    HStack(spacing: 6) {
                        Text(L10n.text("Preview:"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Image(systemName: previewIcon)
                                .font(.system(size: 10))
                                .foregroundStyle(preferences.tintMenuBarIcon ? Color.green : Color.primary)
                            if preferences.menuBarStyle == .lockAndBattery,
                               let lockSymbol = Format.lockStatusSymbol(for: previewSample) {
                                Image(systemName: lockSymbol)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(HisingenTheme.semanticWarning)
                            }
                            Text(previewText)
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        Spacer()
                    }
                    .padding(.vertical, 2)

                    Divider().opacity(0.4)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Panel auto-close"))
                                .font(.system(size: 12, weight: .medium))
                            Text(preferences.panelCloseBehavior.subtitle)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: bind(\.panelCloseBehavior, .presentation)) {
                            ForEach(PanelCloseBehavior.allCases, id: \.self) { behavior in
                                Text(behavior.title).tag(behavior)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 220)
                    }

                    Divider().opacity(0.4)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 5) {
                                    Text(L10n.text("Panel Size"))
                                        .font(.system(size: 12, weight: .medium))
                                    if customSizeEnabled {
                                        Text(L10n.text("Custom"))
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(HisingenTheme.accent.opacity(0.14), in: Capsule())
                                            .foregroundStyle(HisingenTheme.accent)
                                    }
                                }
                                Text(L10n.text("Dropdown panel preset — applies instantly"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("", selection: $panelSize) {
                                ForEach(PanelSize.allCases, id: \.self) { size in
                                    Text(size.title).tag(size)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(maxWidth: 160)
                            .onChange(of: panelSize) { _, newSize in
                                preferences.panelSize = newSize
                                // A picked preset replaces any custom override.
                                customSizeEnabled = false
                                preferences.customPanelSizeEnabled = false
                                onSettingsChanged(.presentation)
                            }
                        }

                        SegmentedPresetRow(options: PanelSize.allCases, selection: $panelSize)
                            .onChange(of: panelSize) { _, newSize in
                                preferences.panelSize = newSize
                                customSizeEnabled = false
                                preferences.customPanelSizeEnabled = false
                                onSettingsChanged(.presentation)
                            }

                        PanelCustomSizeControls(
                            isEnabled: $customSizeEnabled,
                            width: $customWidth,
                            height: $customHeight,
                            seedValues: { [panelSize] in
                                (Double(panelSize.width), Double(panelSize.idealHeight))
                            },
                            onCommit: {
                                preferences.customPanelSizeEnabled = customSizeEnabled
                                preferences.customPanelWidth = customWidth
                                preferences.customPanelHeight = customHeight
                                onSettingsChanged(.presentation)
                            }
                        )

                        HStack(spacing: 8) {
                            HStack(spacing: 6) {
                                Text(L10n.text("Current:"))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "ruler")
                                    .font(.system(size: 10))
                                    .foregroundStyle(HisingenTheme.accent)
                                Text(resolvedLayout.dimensionsLabel)
                                    .font(.system(size: 11, weight: .semibold))
                                    .monospacedDigit()
                            }
                            Spacer(minLength: 8)
                            PanelProportionPreview(layout: resolvedLayout)
                            Button {
                                resetPanelGeometry()
                            } label: {
                                Text(L10n.text("Reset Sizes"))
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(L10n.text("Back to Standard panel and density"))
                        }
                        .padding(.vertical, 2)
                    }

                    Divider().opacity(0.4)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(L10n.text("Content Density"))
                                    .font(.system(size: 12, weight: .medium))
                                Text(L10n.text("Zoom content independently of panel size — compact shows more before scrolling"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("", selection: $contentDensity) {
                                ForEach(ContentDensity.allCases, id: \.self) { density in
                                    Text(density.title).tag(density)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(maxWidth: 160)
                            .onChange(of: contentDensity) { _, newDensity in
                                preferences.contentDensity = newDensity
                                onSettingsChanged(.presentation)
                            }
                        }

                        SegmentedPresetRow(options: ContentDensity.allCases, selection: $contentDensity)
                            .onChange(of: contentDensity) { _, newDensity in
                                preferences.contentDensity = newDensity
                                onSettingsChanged(.presentation)
                            }

                        HStack(spacing: 6) {
                            Text(L10n.text("Current:"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(HisingenTheme.accent)
                                Text(String(format: "%.0f%%", contentDensity.scale * 100))
                                    .font(.system(size: 11, weight: .semibold))
                                    .monospacedDigit()
                                Text("· " + contentDensity.subtitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }

                    Divider().opacity(0.4)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(L10n.text("Card Layout"))
                                    .font(.system(size: 12, weight: .medium))
                                Text(L10n.text("How mid-size cards flow on wide panels"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("", selection: bind(\.wideCardLayout, .presentation)) {
                                ForEach(WideCardLayout.allCases, id: \.self) { layout in
                                    Text(layout.title).tag(layout)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(maxWidth: 160)
                        }

                        SegmentedPresetRow(options: WideCardLayout.allCases, selection: bind(\.wideCardLayout, .presentation))
                    }

                    Divider().opacity(0.4)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Dynamic status bar tinting"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("Color icon green while charging and orange below 20%"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: bind(\.tintMenuBarIcon, .presentation))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    Divider().opacity(0.4)

                    unitRow("Distance unit", selection: $distanceUnit, options: DistanceUnit.allCases, label: \.title) { _ in
                            if !preferences.hasExplicitTemperatureUnit {
                                temperatureUnit = distanceUnit == .miles ? .fahrenheit : .celsius
                            }
                            if !preferences.hasExplicitPressureUnit {
                                pressureUnit = distanceUnit == .miles ? .psi : .kilopascals
                            }
                            if !preferences.hasExplicitEnergyConsumptionUnit {
                                energyConsumptionUnit = distanceUnit == .miles ? .milesPerKwh : .kwhPer100Km
                            }
                            preferences.distanceUnit = distanceUnit
                            onSettingsChanged(.presentation)
                        }

                    Divider().opacity(0.4)

                    unitRow("Temperature unit", selection: $temperatureUnit, options: TemperatureUnit.allCases, label: \.title) { _ in
                            preferences.temperatureUnit = temperatureUnit
                            onSettingsChanged(.presentation)
                        }

                    Divider().opacity(0.4)

                    unitRow("Tyre pressure unit", selection: $pressureUnit, options: PressureUnit.allCases, label: \.title) { _ in
                            preferences.pressureUnit = pressureUnit
                            onSettingsChanged(.presentation)
                        }

                    Divider().opacity(0.4)

                    unitRow("Fuel volume unit", selection: $fuelVolumeUnit, options: FuelVolumeUnit.allCases, label: \.title) { _ in
                            preferences.fuelVolumeUnit = fuelVolumeUnit
                            onSettingsChanged(.presentation)
                        }

                    Divider().opacity(0.4)

                    unitRow("Fuel economy unit", selection: $fuelEconomyUnit, options: FuelEconomyUnit.allCases, label: \.title) { _ in
                            preferences.fuelEconomyUnit = fuelEconomyUnit
                            onSettingsChanged(.presentation)
                        }

                    Divider().opacity(0.4)

                    unitRow("Electric consumption unit", selection: $energyConsumptionUnit, options: EnergyConsumptionUnit.allCases, label: \.title) { _ in
                            preferences.energyConsumptionUnit = energyConsumptionUnit
                            onSettingsChanged(.presentation)
                        }

                    Divider().opacity(0.4)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Launch at login"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("Automatically start Hisingen on macOS startup"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: bind(\.launchAtLogin, .launchAtLogin))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    Divider().opacity(0.4)

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("Electricity Rate"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("For charge cost estimates"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 4) {
                            TextField("2.00", text: $electricityPrice)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 55)
                                .multilineTextAlignment(.trailing)
                                .controlSize(.small)
                                .onChange(of: electricityPrice) { _, _ in
                                    if let price = NumberParsing.decimal(from: electricityPrice),
                                       (0.01...1_000).contains(price) {
                                        preferences.electricityPricePerKwh = price
                                    }
                                }
                            TextField("kr", text: $currencySymbol)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 45)
                                .controlSize(.small)
                                .onChange(of: currencySymbol) { _, _ in
                                    if isValidCurrencySymbol(currencySymbol) {
                                        preferences.currencySymbol = currencySymbol.trimmingCharacters(in: .whitespacesAndNewlines)
                                    }
                                }
                            Text("/kWh")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !isValidElectricityPrice(electricityPrice) {
                        inlineValidation(L10n.text("Enter a rate between 0.01 and 1,000."))
                    }
                    if !isValidCurrencySymbol(currencySymbol) {
                        inlineValidation(L10n.text("Enter a currency symbol or code using 1–8 characters."))
                    }

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("Night Tariff"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("Splits session cost by when energy actually flowed"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: bind(\.nightTariffEnabled))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    if preferences.nightTariffEnabled {
                        HStack(spacing: 4) {
                            TextField("2.00", text: $nightElectricityPrice)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 55)
                                .multilineTextAlignment(.trailing)
                                .controlSize(.small)
                                .onChange(of: nightElectricityPrice) { _, _ in
                                    if let price = NumberParsing.decimal(from: nightElectricityPrice),
                                       (0.01...1_000).contains(price) {
                                        preferences.nightElectricityPricePerKwh = price
                                    }
                                }
                            Text(L10n.text("/kWh from"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Stepper(value: bind(\.nightTariffStartHour), in: 0...23) {
                                Text(String(format: "%02d:00", preferences.nightTariffStartHour))
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .controlSize(.small)
                            Text(L10n.text("to"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Stepper(value: bind(\.nightTariffEndHour), in: 0...23) {
                                Text(String(format: "%02d:00", preferences.nightTariffEndHour))
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .controlSize(.small)
                        }
                        if !isValidElectricityPrice(nightElectricityPrice) {
                            inlineValidation(L10n.text("Enter a night rate between 0.01 and 1,000."))
                        }
                    }

                    Divider().opacity(0.4)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Require device-owner authentication"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("Authenticate before running remote commands"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: bind(\.requireBiometricsForRemoteControls))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityLabel(L10n.text("Require device-owner authentication"))
                    }
                }
            }
        }
    }


    private var featureQuickActions: some View {
        HStack(spacing: 8) {
            Button {
                preferences.features = FeatureSelection.default
                prefsTick &+= 1
                onSettingsChanged(.features)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                    Text(L10n.text("Recommended"))
                }
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.borderedProminent)
            .tint(HisingenTheme.accent)
            .controlSize(.small)

            Button {
                preferences.features = FeatureSelection(enabled: Set(AppFeature.safeBulkEnableCases))
                prefsTick &+= 1
                onSettingsChanged(.features)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                    Text(L10n.text("Enable All Safe Features"))
                }
                .font(.system(size: 11, weight: .medium))
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
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }


    private func isValidElectricityPrice(_ text: String) -> Bool {
        SettingsValidation.isValidElectricityPrice(text)
    }

    private func isValidCurrencySymbol(_ text: String) -> Bool {
        SettingsValidation.isValidCurrencySymbol(text)
    }

    private func inlineValidation(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.red)
            .accessibilityLabel(message)
    }

    /// Shared scaffolding for the unit pickers. Each caller keeps its own `onChange` because
    /// only the distance row cascades into derived defaults.
    private func unitRow<Unit: Hashable>(
        _ title: String,
        selection: Binding<Unit>,
        options: [Unit],
        label: @escaping (Unit) -> String,
        onChange: @escaping (Unit) -> Void
    ) -> some View {
        HStack {
            Text(L10n.text(title))
                .font(.system(size: 12))
            Spacer()
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { unit in
                    Text(label(unit)).tag(unit)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 160)
            .accessibilityLabel(L10n.text(title))
            .onChange(of: selection.wrappedValue) { _, newValue in
                onChange(newValue)
            }
        }
    }

    // `SettingsNotificationsCard`, the capability matrix in `SettingsCapabilityMatrixCard`,
    // and the updater in `SettingsUpdatesCard` — this file keeps the remaining sections.

    private var privacyDashboardCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "hand.raised.fill", title: L10n.text("Privacy Dashboard"), color: .purple)
                Text(L10n.text("Hisingen keeps account secrets in the macOS Keychain and vehicle history in a local SQLite database."))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                KVRow(L10n.text("Account secrets"), L10n.text("macOS Keychain"), symbol: "key.fill")
                KVRow(L10n.text("Vehicle history"), L10n.text("Stored locally on this Mac"), symbol: "internaldrive.fill")
                KVRow(
                    L10n.text("Precise location retention"),
                    persistLocationHistory ? L10n.text("Enabled") : L10n.text("Off (recommended)"),
                    symbol: persistLocationHistory ? "location.fill" : "location.slash.fill"
                )
                KVRow(
                    L10n.text("Screenshot redaction"),
                    preferences.privacyRedactionEnabled ? L10n.text("Enabled") : L10n.text("Disabled"),
                    symbol: "eye.slash.fill"
                )
                KVRow(
                    L10n.text("Remote-command authentication"),
                    preferences.requireBiometricsForRemoteControls ? L10n.text("Required") : L10n.text("Not required"),
                    symbol: "person.badge.key.fill"
                )

                Text(L10n.text("Exports may contain vehicle identifiers and telemetry. Review files before sharing them."))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(HisingenTheme.semanticWarning)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().opacity(0.4)

                HStack(spacing: 8) {
                    Button { exportSettings() } label: {
                        Label(L10n.text("Export Settings"), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    Button { chooseSettingsImport() } label: {
                        Label(L10n.text("Import Settings"), systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    Button(role: .destructive) { showSettingsResetConfirmation = true } label: {
                        Label(L10n.text("Reset Preferences"), systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let settingsTransferFeedback {
                    Label(settingsTransferFeedback.message, systemImage: settingsTransferFeedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(settingsTransferFeedback.isError ? Color.red : HisingenTheme.semanticGood)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func exportSettings() {
        do {
            let data = try preferences.exportSettingsPropertyList()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.propertyList]
            panel.nameFieldStringValue = "hisingen-settings.plist"
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                    settingsTransferFeedback = (L10n.text("Settings exported."), false)
                } catch {
                    settingsTransferFeedback = (L10n.format("Export failed: %@", error.localizedDescription), true)
                }
            }
        } catch {
            settingsTransferFeedback = (L10n.format("Export failed: %@", error.localizedDescription), true)
        }
    }

    private func chooseSettingsImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard fileSize <= 1_000_000 else {
                    settingsTransferFeedback = (L10n.text("The selected settings archive is larger than 1 MB."), true)
                    return
                }
                pendingSettingsImport = try Data(contentsOf: url, options: .mappedIfSafe)
                showSettingsImportConfirmation = true
            } catch {
                settingsTransferFeedback = (L10n.format("Import failed: %@", error.localizedDescription), true)
            }
        }
    }

    private func applyPendingSettingsImport() {
        guard let data = pendingSettingsImport else { return }
        defer { pendingSettingsImport = nil }
        do {
            try preferences.importSettingsPropertyList(data)
            settingsTransferFeedback = (L10n.text("Settings imported."), false)
            notifyAllPreferenceSubsystems()
            onSettingsChanged(.closeSettings)
        } catch {
            settingsTransferFeedback = (L10n.format("Import failed: %@", error.localizedDescription), true)
        }
    }

    private func notifyAllPreferenceSubsystems() {
        onSettingsChanged(.features)
        onSettingsChanged(.notifications)
        onSettingsChanged(.presentation)
        onSettingsChanged(.launchAtLogin)
        onSettingsChanged(.updater)
    }


    private var actionsCard: some View {
        Card {
            VStack(spacing: 8) {
                Button(role: .destructive) {
                    showSignOutConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text(L10n.format("Sign Out of %@ Account", preferences.activeBrand.displayName))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.red)

                Button {
                    NSApp.terminate(nil)
                } label: {
                    HStack {
                        Image(systemName: "power")
                        Text(L10n.text("Quit Hisingen"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
    }
}

/// App name, version/build, and author links at the foot of the About section.
@MainActor
struct SettingsVersionFooter: View {
    var body: some View {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "car.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(HisingenTheme.accent)
                Text("Hisingen")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("v\(appVersion)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("(\(buildNumber))")
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 3) {
                Text(L10n.text("Created by"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Button("Nicolas Kheirallah") {
                    if let url = URL(string: "https://github.com/NicolasKheirallah") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 10, weight: .medium))
                Text("·")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Button("GitHub") {
                    if let url = URL(string: "https://github.com/NicolasKheirallah/Hisingen") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 10, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(HisingenTheme.canvas.opacity(0.5))
        }
    }
}

@MainActor
struct SettingsStudioRenderPreview: View {
    let vin: String
    let angle: Int
    let imageCache: CarImageCache
    @State private var artwork: VehicleArtworkStore.Artwork?

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Color.primary.opacity(0.05), Color.clear],
                center: .center,
                startRadius: 30,
                endRadius: 140
            )

            if let cgImage = artwork?.image {
                Image(decorative: cgImage, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(1.22, anchor: .center)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 165)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .task(id: "\(vin)#\(angle)") {
            let store = VehicleArtworkStore.shared
            let budget = 600
            let source = VehicleArtworkStore.source(vin: vin, angle: angle)
            if let data = imageCache.image(for: vin, angle: angle) ?? imageCache.image(for: vin) {
                if let cached = store.cached(source: source, data: data, pixelBudget: budget) {
                    artwork = cached
                } else {
                    artwork = await store.artwork(source: source, data: data, pixelBudget: budget)
                }
            }
        }
    }
}
