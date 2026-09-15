import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Identifies one continuous last-known-data incident. A dismissal survives ordinary view
/// refreshes for that incident, while a different source timestamp or affected category gets
/// a new identity and is surfaced again.
struct RetainedDataNoticeID: Hashable {
    let vin: String
    let sourceAt: Date?
    let categories: [String]

    init?(state: VehicleState) {
        guard !state.freshness.retainedDataCategories.isEmpty else { return nil }
        vin = state.identity.vin
        sourceAt = state.freshness.retainedDataAt
        categories = state.freshness.retainedDataCategories.map(\.rawValue).sorted()
    }
}

@MainActor
struct HisingenContentView: View {
    let state: VehicleState?
    let error: String?
    let authenticated: Bool
    private var cars: [CarSummary] { fleet.cars }
    let activeVin: String?
    let fleet: FleetSnapshot
    let remoteCommandInProgress: Bool
    /// The live session's brand, threaded to the controls gate so UI dimming and command
    /// dispatch answer availability from the same authority.
    let commandBrand: VehicleBrand
    let inFlightRemoteCommandID: String?
    let lastRemoteCommandFeedback: RemoteCommandFeedback?
    let updateVersion: String?
    let checkingForUpdates: Bool
    let notificationPermission: NotificationPermission
    let diagnostics: DiagnosticsSnapshot?
    let onRefresh: () -> Void
    let onSettings: () -> Void
    /// Dismisses the panel. Reached from Escape, which is the one key every panel-shaped surface
    /// on this platform answers and which nothing here answered before.
    let onClose: () -> Void
    let onCheckForUpdates: () -> Void
    let onOpenUpdate: () -> Void
    let onRemoteCommand: (RemoteCommand) -> Void
    let onSelectCar: (String) -> Void
    let onDismissCommandReceipt: (UUID) -> Void
    let onSettingsChanged: (SettingsChange) -> Void
    let onSignOut: () -> Void
    let onTestConnection: (VehicleBrand) async -> (success: Bool, message: String, failureKind: SignInFailureKind?)
    let settingsMode: Bool
    /// One-time post-sign-in pass. Rendered full-panel like Settings; cleared only through
    /// `onCompleteSetup`, which also persists `hasCompletedSetupPass`.
    let setupMode: Bool
    let onCompleteSetup: () -> Void
    let database: VehicleDatabase
    let reverseGeocoder: ReverseGeocoder
    let imageCache: CarImageCache

    @State private var selectedTab: Tab
    @State private var historyJumpTarget: String?
    private let tabSelection: Binding<Tab>
    @State private var refreshRotation: Double = 0
    @State private var dismissedRetainedDataNotice: RetainedDataNoticeID?
    @State private var firstLaunchCardDismissed = false
    /// Drives ``EnvironmentValues/ambientMotionAllowed``. Starts true: the panel is built while the
    /// app is becoming active, and a first frame of frozen motion would be the bug in reverse.
    @State private var isAppActive = true
    /// Scroll anchor for the shared container. See the reset in `body`.
    private static let scrollTopAnchor = "hisingen.scrollTop"
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
        state: VehicleState?, error: String?, authenticated: Bool,
        activeVin: String?, fleet: FleetSnapshot,
        remoteCommandInProgress: Bool,
        commandBrand: VehicleBrand,
        inFlightRemoteCommandID: String? = nil,
        lastRemoteCommandFeedback: RemoteCommandFeedback? = nil,
        updateVersion: String?, checkingForUpdates: Bool,
        notificationPermission: NotificationPermission, diagnostics: DiagnosticsSnapshot?,
        onRefresh: @escaping () -> Void, onSettings: @escaping () -> Void,
        onClose: @escaping () -> Void = {},
        onCheckForUpdates: @escaping () -> Void, onOpenUpdate: @escaping () -> Void,
        onRemoteCommand: @escaping (RemoteCommand) -> Void,
        onSelectCar: @escaping (String) -> Void,
        onDismissCommandReceipt: @escaping (UUID) -> Void = { _ in },
        onSettingsChanged: @escaping (SettingsChange) -> Void,
        onSignOut: @escaping () -> Void,
        onTestConnection: @escaping (VehicleBrand) async -> (success: Bool, message: String, failureKind: SignInFailureKind?) = { _ in
            (false, L10n.text("Connection testing is not available."), nil)
        },
        settingsMode: Bool,
        setupMode: Bool = false,
        onCompleteSetup: @escaping () -> Void = {},
        selectedTab: Binding<Tab>, database: VehicleDatabase,
         reverseGeocoder: ReverseGeocoder, imageCache: CarImageCache
    ) {
        self.state = state
        self.error = error
        self.authenticated = authenticated
        self.activeVin = activeVin
        self.fleet = fleet
        self.remoteCommandInProgress = remoteCommandInProgress
        self.commandBrand = commandBrand
        self.inFlightRemoteCommandID = inFlightRemoteCommandID
        self.lastRemoteCommandFeedback = lastRemoteCommandFeedback
        self.updateVersion = updateVersion
        self.checkingForUpdates = checkingForUpdates
        self.notificationPermission = notificationPermission
        self.diagnostics = diagnostics
        self.onRefresh = onRefresh
        self.onSettings = onSettings
        self.onClose = onClose
        self.onCheckForUpdates = onCheckForUpdates
        self.onOpenUpdate = onOpenUpdate
        self.onRemoteCommand = onRemoteCommand
        self.onSelectCar = onSelectCar
        self.onDismissCommandReceipt = onDismissCommandReceipt
        self.onSettingsChanged = onSettingsChanged
        self.onSignOut = onSignOut
        self.onTestConnection = onTestConnection
        self.settingsMode = settingsMode
        self.setupMode = setupMode
        self.onCompleteSetup = onCompleteSetup
        self.database = database
        self.reverseGeocoder = reverseGeocoder
        self.imageCache = imageCache
        self._selectedTab = State(initialValue: selectedTab.wrappedValue)
        self.tabSelection = selectedTab
    }

    // Panel geometry mirrors. Reading the raw defaults through @AppStorage means a
    // preset / density / custom-slider change invalidates this view natively – the
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
            if showsFirstLaunchWelcome {
                firstLaunchWelcomeCard
            }
            if settingsMode || (!authenticated && selectedTab == .settings) {
                SettingsView(notificationPermission: notificationPermission,
                             state: state,
                             fleet: fleet,
                             database: database, imageCache: imageCache,
                             onSettingsChanged: { change in
                                 if case .closeSettings = change {
                                      withAnimation(tabIndicatorAnimation) { selectedTab = .vehicle }
                                      tabSelection.wrappedValue = .vehicle
                                 }
                                 onSettingsChanged(change)
                             }, onSignOut: onSignOut, onTestConnection: onTestConnection)
                     .id(preferences.vin.isEmpty ? activeVin : preferences.vin)
                     .transition(modeTransition)
            } else if !authenticated {
                WelcomeSignInView(error: error, onSettingsChanged: onSettingsChanged, onTestConnection: onTestConnection)
                    .transition(modeTransition)
            } else if setupMode {
                // Deliberately not gated on `state`. SetupPassView only needs the brand, and
                // requiring vehicle data meant an account with no VIN, or a first fetch that
                // failed, could never reach the pass that explains what to do next.
                SetupPassView(brand: commandBrand,
                              onSettingsChanged: onSettingsChanged,
                              onComplete: onCompleteSetup)
                    .id(state?.identity.vin ?? commandBrand.rawValue)
                    .transition(modeTransition)
            } else if let state {
                tabBar
                scrollEdgeFade
                if selectedTab == .settings {
                    SettingsView(notificationPermission: notificationPermission,
                                 state: state,
                                 fleet: fleet,
                                 database: database, imageCache: imageCache,
                                 onSettingsChanged: { change in
                                     if case .closeSettings = change {
                                          withAnimation(tabIndicatorAnimation) { selectedTab = .vehicle }
                                          tabSelection.wrappedValue = .vehicle
                                     }
                                     onSettingsChanged(change)
                                 }, onSignOut: onSignOut, onTestConnection: onTestConnection)
                        .id(preferences.vin.isEmpty ? activeVin : preferences.vin)
                        .transition(.opacity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        ScrollViewReader { proxy in
                            VStack(spacing: HisingenTheme.sectionSpacing) {
                                // Zero-height anchor: one scroll container serves every tab, so a
                                // new tab used to open at the previous tab's offset — its heading,
                                // primary value and any banner already scrolled off. Resetting to an
                                // anchor avoids giving each tab its own identity, which would discard
                                // its internal state (expanded sections, disclosure rows).
                                Color.clear.frame(height: 0).id(Self.scrollTopAnchor)
                                if let noticeID = RetainedDataNoticeID(state: state),
                                   noticeID != dismissedRetainedDataNotice {
                                    retainedDataNotice(state, id: noticeID)
                                        .transition(retainedDataTransition)
                                }
                                selectedTabContent(state: state)
                            }
                            .padding(HisingenTheme.sectionSpacing)
                            .animation(reduceMotion ? nil : Motion.interaction, value: selectedTab)
                            .hisAnimation(Motion.cardChange, value: activeVin)
                            .hisAnimation(Motion.stateChange, value: noticeIdentity)
                            .onChange(of: selectedTab) { _, _ in
                                if selectedTab != .history { historyJumpTarget = nil }
                                proxy.scrollTo(Self.scrollTopAnchor, anchor: .top)
                            }
                            // A command's outcome renders in the banner at the top of this one
                            // shared scroller, with indicators hidden. A reader who scrolled to the
                            // OTA card, tapped Install and got "Command failed" saw nothing at all:
                            // no result, no scroll-to, not even a scrollbar to hint that content
                            // existed above. The outcome now comes to them.
                            .onChange(of: lastRemoteCommandFeedback?.id) { _, feedbackID in
                                guard feedbackID != nil, selectedTab == .controls else { return }
                                withAnimation(Motion.resolve(Motion.cardChange)) {
                                    proxy.scrollTo(Self.scrollTopAnchor, anchor: .top)
                                }
                            }
                        }
                    }
                }
            } else {
                placeholderView
                    .transition(.opacity)
            }
            scrollEdgeFade
            footerBar
        }
        // Content-density zoom: lay out at panelSize/scale, then scale into the physical
        // panel – so Compact fits more content and Relaxed enlarges it, independently of
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
        .animation(reduceMotion ? nil : Motion.layout, value: panelLayout)
        .animation(reduceMotion ? nil : Motion.entrance, value: settingsMode)
        .animation(reduceMotion ? nil : Motion.entrance, value: setupMode)
        .animation(reduceMotion ? nil : Motion.entrance, value: authenticated)
        .tint(HisingenTheme.accent)
        .preferredColorScheme(AppearanceMode(rawValue: storedAppearanceMode)?.colorScheme)
        .animation(reduceMotion ? nil : Motion.theme, value: appTheme)
        .animation(reduceMotion ? nil : Motion.theme, value: storedAppearanceMode)
        .id(preferences.interfaceLanguage.rawValue)
        // Ambient motion stops when the app is not frontmost. The panel can be kept open behind
        // another window for hours, and the charging particle flow, the gauge breath and the fan
        // all ran whether or not anyone could see them.
        .environment(\.ambientMotionAllowed, isAppActive)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isAppActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            isAppActive = false
        }
        // Escape closes the panel. The tabs carry their own shortcuts, the footer buttons are
        // reachable, and a panel that traps you in it is the thing a keyboard user notices first.
        .onExitCommand(perform: onClose)
    }

    private var retainedDataTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95))
    }

    private func navigateFromInfoToHistory() {
        historyJumpTarget = "activity"
        withAnimation(tabIndicatorAnimation) { selectedTab = .history }
        tabSelection.wrappedValue = .history
    }

    @ViewBuilder
    private func selectedTabContent(state: VehicleState) -> some View {
        switch selectedTab {
        case .vehicle:
            VehicleTabView(state: state, cars: cars, activeVin: activeVin,
                           onSelectCar: onSelectCar,
                           onDismissCommandReceipt: onDismissCommandReceipt,
                           error: error,
                           database: database, reverseGeocoder: reverseGeocoder,
                           imageCache: imageCache)
                .id(state.identity.vin)
                .transition(.opacity)
        case .info:
            InfoTabView(state: state, database: database, imageCache: imageCache,
                        reverseGeocoder: reverseGeocoder,
                        onRefresh: onRefresh,
                        onNavigateToHistory: navigateFromInfoToHistory,
                        onRemoteCommand: onRemoteCommand)
                .id(state.identity.vin)
                .transition(.opacity)
        case .history:
            HistoryDashboardView(state: state, database: database,
                                 initialSection: historyJumpTarget)
                .id(state.identity.vin)
                .transition(.opacity)
        case .controls:
            ControlsTabView(state: state,
                            brand: commandBrand,
                            remoteCommandInProgress: remoteCommandInProgress,
                            inFlightCommandID: inFlightRemoteCommandID,
                            feedback: lastRemoteCommandFeedback,
                            onRemoteCommand: onRemoteCommand,
                            onRefresh: onRefresh,
                            onDismissCommandReceipt: onDismissCommandReceipt)
                .transition(.opacity)
        case .settings:
            EmptyView()
        }
    }

    private var scrollEdgeFade: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [HisingenTheme.hairline.opacity(0.55), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(height: 5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var garageStates: [VehicleState] {
        fleet.vehicles.compactMap { fleet.snapshot(for: $0) }.sorted {
            if $0.model.brand != $1.model.brand { return $0.model.brand.rawValue < $1.model.brand.rawValue }
            return ($0.identity.modelName ?? $0.identity.vin) < ($1.identity.modelName ?? $1.identity.vin)
        }
    }

    /// The card marks the very first panel session ever. It hides inside Settings and the
    /// setup pass (both already orient the user) and goes away for good on dismissal – or
    /// when the panel closes, which `StatusItemController.popoverDidClose` records.
    private var showsFirstLaunchWelcome: Bool {
        !firstLaunchCardDismissed
            && !preferences.hasSeenFirstLaunchWelcome
            && !setupMode
            && !settingsMode
            && !(!authenticated && selectedTab == .settings)
    }

    private func dismissFirstLaunchWelcome() {
        firstLaunchCardDismissed = true
        preferences.markFirstLaunchWelcomeSeen()
    }

    private var firstLaunchWelcomeCard: some View {
        var details = [L10n.text("Click the car icon in the menu bar any time to open this panel.")]
        if !authenticated {
            details.append(L10n.text("Connect your vehicle account below to get started."))
        }
        return DismissibleNoticeBanner(
            icon: "hand.wave",
            title: L10n.text("Hisingen lives in your menu bar"),
            details: details,
            tint: HisingenTheme.accent,
            onDismiss: dismissFirstLaunchWelcome
        )
        .padding(.horizontal, HisingenTheme.sectionSpacing)
        .padding(.top, HisingenTheme.sectionSpacing)
        .padding(.bottom, 6)
    }

    private func retainedDataNotice(_ state: VehicleState, id: RetainedDataNoticeID) -> some View {
        DismissibleNoticeBanner(
            icon: "clock.badge.exclamationmark",
            title: L10n.text("Showing last-known values"),
            details: [state.freshness.retainedDataCategories.map(\.title).joined(separator: ", ")],
            footnote: state.freshness.retainedDataAt.map {
                L10n.format("Source data from %@", Format.relativeAge(since: $0))
            },
            tint: HisingenTheme.semanticWarning,
            containerHelp: L10n.text("The newest provider refresh did not include these fields. Hisingen retained the previous successful readings and labels them here instead of presenting them as live."),
            onDismiss: { dismissedRetainedDataNotice = id }
        )
    }


    private var tabIndicatorAnimation: Animation? {
        reduceMotion ? nil : Motion.selection
    }

    /// Full-panel mode swaps (dashboard ↔ settings ↔ welcome ↔ setup pass). The
    /// slight scale grounds the entering surface; Reduce Motion keeps the
    /// crossfade and drops the movement.
    private var modeTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96))
    }

    /// Identity of the active retained-data notice, so its appearance and
    /// replacement animate instead of popping in mid-scroll.
    private var noticeIdentity: RetainedDataNoticeID? {
        state.flatMap { RetainedDataNoticeID(state: $0) }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.self) { tab in
                let tabNumber = (Tab.allCases.firstIndex(of: tab) ?? 0) + 1
                Button {
                    withAnimation(tabIndicatorAnimation) {
                        selectedTab = tab
                        tabSelection.wrappedValue = tab
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                            .hisType(.caption, weight: selectedTab == tab ? .semibold : .regular)
                        Text(L10n.text(tab.rawValue))
                            .hisType(.caption, weight: selectedTab == tab ? .semibold : .medium)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                    }
                    .foregroundStyle(selectedTab == tab ? HisingenTheme.ink : HisingenTheme.inkMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
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
                .buttonStyle(.pressable)
                .focusEffectDisabled()
                .help(L10n.text(tab.rawValue))
                .keyboardShortcut(KeyEquivalent(Character("\(tabNumber)")), modifiers: .command)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }


    /// Shown while authenticated but with no snapshot yet.
    ///
    /// A failure is not a loading state. Printing the error under a spinner that keeps
    /// spinning made "still connecting" and "this failed for good" look identical, and left
    /// the user watching an indicator that would never resolve.
    private var placeholderView: some View {
        VStack(spacing: 12) {
            if let error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(HisingenTheme.semanticWarning)
                Text(error)
                    .hisType(.body)
                    .foregroundStyle(HisingenTheme.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("Refresh Now")) { onRefresh() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                ProgressView()
                    .controlSize(.regular)
                Text(L10n.format("Connecting to %@…", preferences.activeBrand.displayName))
                    .hisType(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, HisingenTheme.sectionSpacing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }


    private var otherBrand: VehicleBrand { preferences.activeBrand == .polestar ? .volvo : .polestar }
    private var otherBrandResumable: Bool { preferences.hasResumableSession(for: otherBrand) }


    private func vehicleMenuLabel(_ car: CarSummary) -> String {
        let isActive = car.vin == activeVin
        let snapshot = fleet.snapshot(for: car.vin)
        let baseTitle: String = {
            if let snap = snapshot {
                return preferences.formattedVehicleTitle(
                    vin: snap.identity.vin,
                    modelName: snap.identity.modelName,
                    modelYear: snap.identity.modelYear,
                    registrationNo: snap.identity.registrationNo
                )
            }
            return car.displayTitle()
        }()
        guard let snapshot else { return baseTitle }
        var label = baseTitle
        if let battery = snapshot.energy.batteryPercentage {
            label += " · \(Int(battery))%"
            if snapshot.isCharging { label += "⚡" }
        } else if let fuel = snapshot.fuelSystem.levelPercent {
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
        let isActive = state.identity.vin == activeVin
        let baseTitle = preferences.formattedVehicleTitle(
            vin: state.identity.vin,
            modelName: state.identity.modelName,
            modelYear: state.identity.modelYear,
            registrationNo: state.identity.registrationNo,
            fallbackBrand: state.model.brand
        )
        var label = baseTitle
        if let battery = state.energy.batteryPercentage {
            label += " · \(Int(battery))%"
            if state.isCharging { label += "⚡" }
        } else if let fuel = state.fuelSystem.levelPercent {
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
        if !vin.isEmpty, let battery = fleet.snapshot(for: vin)?.energy.batteryPercentage {
            return L10n.format("Switch to %@ (%@ · %d%%)…", otherBrand.displayName, name, Int(battery))
        }
        return L10n.format("Switch to %@ (%@)…", otherBrand.displayName, name)
    }

    private var vehicleSwitcher: some View {
        let currentVin = activeVin ?? cars.first?.vin ?? ""
        let currentCar = cars.first { $0.vin == currentVin }
        let currentTitle: String = {
            if let state, state.identity.vin == currentVin {
                return preferences.formattedVehicleTitle(
                    vin: state.identity.vin,
                    modelName: state.identity.modelName,
                    modelYear: state.identity.modelYear,
                    registrationNo: state.identity.registrationNo
                )
            }
            if let snap = fleet.snapshot(for: currentVin) {
                return preferences.formattedVehicleTitle(
                    vin: snap.identity.vin,
                    modelName: snap.identity.modelName,
                    modelYear: snap.identity.modelYear,
                    registrationNo: snap.identity.registrationNo
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
                ForEach(Array(fleetStates.enumerated().prefix(9)), id: \.element.identity.vin) { index, vehicle in
                    let isSelected = vehicle.identity.vin == currentVin
                    Button {
                        onSelectCar(vehicle.identity.vin)
                    } label: {
                        Label(vehicleMenuLabel(state: vehicle), systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                    }
                    .accessibilityLabel(vehicleMenuAccessibilityLabel(vehicle, isSelected: isSelected))
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.option, .control])
                }
                ForEach(Array(fleetStates.enumerated().dropFirst(9)), id: \.element.identity.vin) { _, vehicle in
                    let isSelected = vehicle.identity.vin == currentVin
                    Button {
                        onSelectCar(vehicle.identity.vin)
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
                    .hisType(.caption)
                Text(currentTitle)
                    .hisType(.label, weight: .medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                    .hisType(.nano, weight: .bold)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 155, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .help(L10n.format("%@ · Switch Vehicle (⌃⌥1–9)", currentTitle))
        .accessibilityLabel(L10n.format("Current vehicle: %@. Switch vehicle.", currentTitle))
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            if garageStates.count > 1 || cars.count > 1 || otherBrandResumable {
                vehicleSwitcher
            }
            // Data freshness indicator
            if let fetchedAt = state?.freshness.fetchedAt, state?.hasOldData() == false {
                let age = Date().timeIntervalSince(fetchedAt)
                let freshnessColor: Color = age < 30 ? .green : (age < 120 ? .yellow : .red)
                let ageText: String = age < 60 ? "\(Int(age))s" : "\(Int(age / 60))m"
                HStack(spacing: 3) {
                    Circle()
                        .fill(freshnessColor)
                        .frame(width: 6, height: 6)
                        // The hue already changes with age (green, yellow, red). Fading the dot
                        // as well spent legibility on the one message that most needs reading.
                        .hisAnimation(Motion.stateChange, value: freshnessColor)
                    Text(ageText)
                        // Tabular figures rather than a monospaced face: this is an ordinary UI
                        // numeral, and SF Mono here was a different typeface from the battery
                        // percentage one row above. `.secondary` because 9pt in `.tertiary` over
                        // a material is below AA.
                        .hisType(.micro, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .hisAnimation(Motion.telemetry, value: ageText)
                }
                .help(L10n.format("Last updated %@", Format.dateTimeFormatter.string(from: fetchedAt)))
            }
            if diagnostics?.liveStreamConnected == true {
                HStack(spacing: 3) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                    Text(L10n.text("Live"))
                }
                .hisType(.micro, weight: .semibold)
                .foregroundStyle(HisingenTheme.semanticGood)
                .help(L10n.text("Connected to the Polestar server stream. Battery and exterior changes are applied as the provider sends them; scheduled polling remains as a reliability fallback."))
                .accessibilityLabel(L10n.text("Live vehicle stream connected"))
            } else if let retryAt = diagnostics?.liveStreamRetryAt {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .hisType(.micro)
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
                        .hisType(.label, weight: .medium)
                        .foregroundStyle(.tint)
                }
                .controlSize(.small)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else if preferences.features.contains(.updateChecks) {
                Button {
                    onCheckForUpdates()
                } label: {
                    if checkingForUpdates {
                        ProgressView().controlSize(.small)
                            .transition(.opacity)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                            .transition(.opacity)
                    }
                }
                .controlSize(.small)
                .help(L10n.text("Check for Updates…"))
                .accessibilityLabel(L10n.text("Check for Updates…"))
            }
            Button {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                withAnimation(reduceMotion ? nil : Motion.refreshSweep) {
                    refreshRotation += 360
                }
                onRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(refreshRotation))
            }
            .controlSize(.small)
            .help(L10n.text("Refresh Telemetry (⌘R)"))
            .accessibilityLabel(L10n.text("Refresh Telemetry"))
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!authenticated)

            Button {
                onSettings()
            } label: {
                Image(systemName: settingsMode ? "car.fill" : "gearshape")
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
            .controlSize(.small)
            .help(settingsMode ? L10n.text("Back to Dashboard") : L10n.text("Settings…"))
            .accessibilityLabel(settingsMode ? L10n.text("Back to Dashboard") : L10n.text("Settings…"))
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .hisAnimation(Motion.stateChange, value: updateVersion)
        .hisAnimation(Motion.stateChange, value: checkingForUpdates)
    }
}
