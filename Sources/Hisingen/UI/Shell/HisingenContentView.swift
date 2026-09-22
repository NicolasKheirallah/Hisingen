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
    let onTestConnection: (VehicleBrand) async -> ConnectionCheck
    /// One-time post-sign-in pass. Rendered full-panel like Settings; cleared only through
    /// `onCompleteSetup`, which also persists `hasCompletedSetupPass`.
    let setupMode: Bool
    let onCompleteSetup: () -> Void
    let history: HistoryWorkspace
    let accountConnection: AccountConnectionModel
    let reverseGeocoder: ReverseGeocoder
    let imageCache: CarImageCache

    @State private var selectedTab: TabRef
    @State private var historyJumpTarget: String?
    private let tabSelection: Binding<TabRef>
    @State private var refreshRotation: Double = 0
    @State private var dismissedRetainedDataNotice: RetainedDataNoticeID?
    @State private var firstLaunchCardDismissed = false
    // MARK: Instrument layer state (gesture physics + material arrival)

    /// Distance from the scroll content's top; `<= 0.5` means the reader is at the top and a
    /// downward drag is a pull-to-refresh rather than a scroll.
    @State private var scrollOffsetFromTop: CGFloat = 0
    /// Rubber-banded pull distance feeding ``PullToRefreshOverlay``.
    @State private var pullDistance: CGFloat = 0
    /// Whether the current pull has crossed the commit threshold. The arm tick fires on the
    /// crossing and re-arms only below a hysteresis band, so a pull hovering at the line
    /// cannot stutter the haptic.
    @State private var pullArmed = false
    /// Horizontal translation while a tab swipe is in progress; `nil` when the active gesture
    /// is not a swipe. Release animates the value back to `nil` rather than clearing it, so
    /// the page settles from wherever the drag left it.
    @State private var swipeTranslation: CGFloat?
    /// A card reorder owns the pointer. Reported upward by ``TabCardStack`` through
    /// ``ReorderDragActiveKey``; while it lasts, the panel's own drag coordinator must stand
    /// down instead of reading the same movement as a swipe or a pull.
    @State private var reorderDragActive = false
    /// The axis the active drag committed to, latched on the first dominant movement so a
    /// wobbly diagonal cannot flip between pull and swipe mid-gesture.
    @State private var dragAxis: Axis?
    /// The panel's material arrival: scale + opacity travel the entrance curve once per open.
    @State private var hasMaterialized = false
    /// Drives ``EnvironmentValues/ambientMotionAllowed``. Starts true: the panel is built while the
    /// app is becoming active, and a first frame of frozen motion would be the bug in reverse.
    @State private var isAppActive = true
    /// The tab Settings was opened over, so backing out returns the reader to where they were
    /// rather than to a fixed tab.
    @State private var settingsReturnTab: TabRef?
    /// Scroll anchor for the shared container. See the reset in `body`.
    private static let scrollTopAnchor = "hisingen.scrollTop"
    @Namespace private var tabIndicatorNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.preferencesStore) private var preferences


    @AppStorage("app_theme") private var appTheme: AppTheme = .hisingen
    @AppStorage("his_appearanceMode") private var storedAppearanceMode: String = AppearanceMode.system.rawValue

    /// The tab currently drawn.
    ///
    /// The selection is stored, not derived, so a reader can hide or re-order tabs in Settings
    /// without the panel jumping elsewhere. When their selection disappears — a hidden tab, a
    /// deleted custom tab — the first visible one stands in, which is the only behaviour that
    /// leaves them somewhere real. The rule itself lives in `TabRouting`, where it can be tested;
    /// it used to live here, and nothing could reach it.
    private var currentTab: TabRef {
        TabRouting.resolve(composition: tabComposition, selected: selectedTab)
    }

    private var tabComposition: TabComposition { preferences.tabComposition }

    /// The Settings tab, spelled once. Settings used to be reachable two ways at once — a
    /// controller-owned `settingsMode` flag and a tab — and the two disagreed: with the Settings
    /// tab selected, tapping the footer gear flipped the mode off and the panel fell back to
    /// whichever tab was stored behind it, which read as "pressing Settings jumps to Info".
    ///
    /// The flag is gone. The selection is the one switch — see `select(_:)`.
    private static let settingsTab = TabRef.settings

    /// Whether the Settings surface is on screen. One answer, from one place: the selected tab.
    private var showsSettings: Bool { currentTab == Self.settingsTab }

    /// Where the gear returns to. Only ever a tab the reader was actually on.
    private var returnTab: TabRef? {
        guard let tab = settingsReturnTab, tabComposition.isVisible(tab) else { return nil }
        return tab
    }

    /// Whether Settings is drawn as one tab among the others, with the panel's tab bar above it.
    ///
    /// It is not, before sign-in or before the first snapshot: there is no bar to draw, and the
    /// account form is the only way forward, so Settings fills the panel and carries its own
    /// header. Gating the tab-bar branch on this is what makes the header navigation identical on
    /// every tab — `showsSettings` alone made the first branch swallow Settings, and the
    /// `tabBar` that every other tab draws never rendered.
    private var showsSettingsAsTab: Bool {
        TabRouting.settingsDrawsAsTab(
            authenticated: authenticated,
            hasSnapshot: state != nil,
            setupMode: setupMode
        )
    }

    /// Settings as a tab and Settings full-panel take the same inputs; only the surface's
    /// transition and the header it draws differ, so it is built in one place.
    private var settingsScreen: some View {
        SettingsView(
            notificationPermission: notificationPermission,
            state: state,
            fleet: fleet,
            imageCache: imageCache,
            showsHeaderBar: !showsSettingsAsTab,
            onSettingsChanged: { change in
                if case .closeSettings = change {
                    withAnimation(tabIndicatorAnimation) { select(returnTab ?? .vehicle) }
                }
                onSettingsChanged(change)
            },
            onSignOut: onSignOut,
            accountConnection: accountConnection,
            onTestConnection: onTestConnection
        )
    }

    /// The panel reads everything from one observed model: display state updated wholesale
    /// by the app layer, the fixed action seam, and the services it reads on demand. The
    /// stored fields below are copies taken at construction, so the body stays untouched;
    /// the popover re-constructs this view whenever the model publishes.
    init(panel: PanelModel, selectedTab: Binding<TabRef>) {
        let display = panel.display
        let actions = panel.actions
        self.state = display.state
        self.error = display.error
        self.authenticated = display.authenticated
        self.activeVin = display.activeVin
        self.fleet = display.fleet
        self.remoteCommandInProgress = display.remoteCommandInProgress
        self.commandBrand = display.commandBrand
        self.inFlightRemoteCommandID = display.inFlightRemoteCommandID
        self.lastRemoteCommandFeedback = display.lastRemoteCommandFeedback
        self.updateVersion = display.updateVersion
        self.checkingForUpdates = display.checkingForUpdates
        self.notificationPermission = display.notificationPermission
        self.diagnostics = display.diagnostics
        self.onRefresh = actions.onRefresh
        self.onSettings = actions.onSettings
        self.onClose = actions.onClose
        self.onCheckForUpdates = actions.onCheckForUpdates
        self.onOpenUpdate = actions.onOpenUpdate
        self.onRemoteCommand = actions.onRemoteCommand
        self.onSelectCar = actions.onSelectCar
        self.onDismissCommandReceipt = actions.onDismissCommandReceipt
        self.onSettingsChanged = actions.onSettingsChanged
        self.onSignOut = actions.onSignOut
        self.onTestConnection = actions.onTestConnection
        self.setupMode = display.setupMode
        self.onCompleteSetup = actions.onCompleteSetup
        self.history = panel.history
        self.accountConnection = panel.accountConnection
        self.reverseGeocoder = panel.reverseGeocoder
        self.imageCache = panel.imageCache
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
        let tab = currentTab
        return VStack(spacing: 0) {
            if showsFirstLaunchWelcome {
                firstLaunchWelcomeCard
            }
            // Settings is a tab like any other once the panel has a bar to navigate by, so it
            // rides the same branch as every other tab (below). Only the full-panel presentation
            // — sign-in ends here, and an account with no snapshot yet — is drawn without one.
            if showsSettings, !showsSettingsAsTab {
                settingsScreen
                    .id(preferences.vin.isEmpty ? activeVin : preferences.vin)
                    .transition(modeTransition)
            } else if !authenticated {
                WelcomeSignInView(error: error, onSettingsChanged: onSettingsChanged,
                                  accountConnection: accountConnection, onTestConnection: onTestConnection)
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
                if tab == .settings {
                    settingsScreen
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
                                selectedTabContent(state: state, tab: tab)
                            }
                            .padding(HisingenTheme.sectionSpacing)
                            .animation(reduceMotion ? nil : Motion.interaction, value: tab)
                            .hisAnimation(Motion.cardChange, value: activeVin)
                            .hisAnimation(Motion.stateChange, value: noticeIdentity)
                            .environment(\.scrollRevealAction) { target in
                                withAnimation(Motion.resolve(Motion.layout)) {
                                    proxy.scrollTo(target, anchor: .bottom)
                                }
                            }
                            .onChange(of: tab) { _, _ in
                                if tab != .history { historyJumpTarget = nil }
                                proxy.scrollTo(Self.scrollTopAnchor, anchor: .top)
                            }
                            // A command's outcome renders in the banner at the top of this one
                            // shared scroller, with indicators hidden. A reader who scrolled to the
                            // OTA card, tapped Install and got "Command failed" saw nothing at all:
                            // no result, no scroll-to, not even a scrollbar to hint that content
                            // existed above. The outcome now comes to them.
                            .onChange(of: lastRemoteCommandFeedback?.id) { _, feedbackID in
                                guard feedbackID != nil, tab == .controls else { return }
                                withAnimation(Motion.resolve(Motion.cardChange)) {
                                    proxy.scrollTo(Self.scrollTopAnchor, anchor: .top)
                                }
                            }
                            // A swipe drags the page with the pointer (at a dampened ratio so
                            // it tracks without pretending to be a full page), released into
                            // the flick spring that carries the real velocity.
                            .offset(x: swipeTranslation.map { $0 * 0.22 } ?? 0)
                        }
                    }
                    // Scroll geometry is what lets a downward drag mean two things: a pull
                    // that can refresh at the top, and a plain scroll everywhere else.
                    .onScrollGeometryChange(for: CGFloat.self) { geometry in
                        geometry.contentOffset.y + geometry.contentInsets.top
                    } action: { _, offset in
                        scrollOffsetFromTop = offset
                    }
                    .simultaneousGesture(panelDragGesture)
                    // The scroll edge effect: content softens as it passes under the floating
                    // tab strip and over the footer, instead of meeting a drawn divider. This is
                    // the 2026 replacement for the hairline strip the panel used to draw there.
                    .mask {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom)
                                .frame(height: 18)
                            Color.white
                            LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: 14)
                        }
                    }
                    .overlay(alignment: .top) {
                        PullToRefreshOverlay(pullDistance: pullDistance, threshold: Self.pullThreshold)
                    }
                }
            } else {
                placeholderView
                    .transition(.opacity)
            }
            footerBar
        }
        // Content-density zoom: lay out at panelSize/scale, then scale into the physical
        // panel – so Compact fits more content and Relaxed enlarges it, independently of
        // the window preset. Transforms are ignored by layout, hence the inverse frames.
        // Height comes pre-clamped by PanelLayout to what fits below the menu bar.
        .frame(width: layout.logicalWidth, alignment: .topLeading)
        .frame(height: layout.logicalHeight, alignment: .topLeading)
        .scaleEffect(layout.contentScale, anchor: .topLeading)
        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
        // Clips the transformed tree to the physical panel; without it, scaled
        // overflow would draw outside the transparent popover window.
        .clipped()
        .background { HisingenTheme.popoverSurface }
        // The material arrival: the panel settles from a slightly smaller, dimmer state on
        // the shared entrance curve, so opening reads as glass arriving rather than a picture
        // appearing. `hisAnimation` keeps a crossfade under Reduce Motion.
        .scaleEffect(hasMaterialized ? 1 : 0.965)
        .opacity(hasMaterialized ? 1 : 0)
        .hisAnimation(Motion.materialize, value: hasMaterialized)
        .onAppear { hasMaterialized = true }
        .animation(reduceMotion ? nil : Motion.layout, value: panelLayout)
        .animation(reduceMotion ? nil : Motion.entrance, value: setupMode)
        .animation(reduceMotion ? nil : Motion.entrance, value: authenticated)
        .tint(HisingenTheme.accent)
        // SwiftUI's own date renderings (`Text(date, style: .date)`, FormatStyle in Text) read
        // the environment locale, which is the system region by default; an English UI on a
        // Swedish-region Mac got "19 september 2026". Pin the environment to the same display
        // locale the string formatters use, so every date answers to one policy.
        .environment(\.locale, L10n.displayLocale)
        .preferredColorScheme(AppearanceMode(rawValue: storedAppearanceMode)?.colorScheme)
        // A theme or appearance change is a palette swap: nothing moves, only colour interpolates.
        // That makes it the case Reduce Motion should *keep* — a cross-fade is the non-vestibular
        // equivalent of the transition, and hard-cutting nine palettes is exactly the abrupt
        // brightness jump the setting exists to avoid. `hisAnimation` resolves to a short
        // cross-fade under Reduce Motion instead of dropping the animation entirely.
        .hisAnimation(Motion.theme, value: appTheme)
        .hisAnimation(Motion.theme, value: storedAppearanceMode)
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
        .onPreferenceChange(ReorderDragActiveKey.self) { reorderDragActive = $0 }
        // Escape closes the panel. The tabs carry their own shortcuts, the footer buttons are
        // reachable, and a panel that traps you in it is the thing a keyboard user notices first.
        .onExitCommand(perform: onClose)
    }

    private var retainedDataTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95))
    }

    // MARK: - Instrument layer: gestures

    /// Pull-to-refresh threshold in points — deep enough that a scroll that happens to end at
    /// the top never commits, shallow enough to reach with a thumb on a trackpad.
    private static let pullThreshold: CGFloat = 56
    /// The nominal page width for tab-swipe projection. Tabs are not literally pages, but the
    /// projection needs a distance scale, and the panel's own width is the honest one.
    private var swipePageWidth: CGFloat { HisingenTheme.layoutWidth }

    /// The visible tab list and the current index into it, shared by the swipe gesture and
    /// the tab bar so the two can never disagree about what "next tab" means.
    private var swipeTabs: [TabRef] {
        tabComposition.visibleTabs()
    }

    /// The one drag coordinator for the panel: latches to an axis on the first dominant
    /// movement, tracks the pull with rubber-band physics at the scroll top, tracks the tab
    /// swipe everywhere else, and commits by release velocity — position alone never commits.
    private var panelDragGesture: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .global)
            .onChanged { value in
                guard !reorderDragActive else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                if dragAxis == nil, abs(dx) > 14 || abs(dy) > 14 {
                    dragAxis = abs(dx) > abs(dy) * 1.3 ? .horizontal : .vertical
                }
                switch dragAxis {
                case .horizontal:
                    swipeTranslation = dx
                case .vertical:
                    guard scrollOffsetFromTop <= 0.5, dy > 0 else { return }
                    let pulled = InstrumentMath.rubberBandDisplacement(overshoot: dy, dimension: 300)
                    if pulled >= Self.pullThreshold, !pullArmed {
                        pullArmed = true
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    } else if pulled < Self.pullThreshold * 0.85, pullArmed {
                        pullArmed = false
                    }
                    pullDistance = pulled
                case nil:
                    break
                }
            }
            .onEnded { value in
                defer {
                    dragAxis = nil
                    pullArmed = false
                    if pullDistance > 0 {
                        // The pull was gesture-carried, so its return takes the flick spring
                        // rather than a fixed fade.
                        withAnimation(reduceMotion ? nil : Motion.flick) { pullDistance = 0 }
                    }
                }
                if dragAxis == .horizontal {
                    // The page leaves the pointer the way it arrived: on the flick spring,
                    // from wherever the drag left it. Clearing the offset without an
                    // animation read as a hard cut back to rest on every swipe that landed
                    // where it started.
                    withAnimation(reduceMotion ? nil : Motion.flick) { swipeTranslation = nil }
                    let tabs = swipeTabs
                    guard let current = tabs.firstIndex(of: currentTab),
                          let target = InstrumentMath.projectedTab(
                              currentIndex: current,
                              count: tabs.count,
                              translation: value.translation.width,
                              releaseVelocity: value.velocity.width,
                              pageWidth: swipePageWidth
                          ),
                          target != current else { return }
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    withAnimation(reduceMotion ? nil : Motion.flick) { select(tabs[target]) }
                }
                if dragAxis == .vertical, pullDistance > 0,
                   InstrumentMath.pullRefreshShouldCommit(
                       dragDistance: pullDistance,
                       releaseVelocity: value.velocity.height,
                       threshold: Self.pullThreshold
                   ) {
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                    withAnimation(reduceMotion ? nil : Motion.refreshSweep) {
                        refreshRotation += 360
                    }
                    onRefresh()
                }
            }
    }


    private func navigateFromInfoToHistory() {
        historyJumpTarget = "activity"
        withAnimation(tabIndicatorAnimation) { select(.history) }
    }

    /// One place that writes the selection, so the local mirror and the controller's stored tab
    /// can never disagree.
    ///
    /// The selection is also what puts Settings on screen, for the menu-bar item, the `⌘,`
    /// shortcut and a sign-in that ends inside Settings. There is deliberately no second switch:
    /// a mode and a tab that can each be toggled are two switches for one light, and this UI has
    /// now broken twice from exactly that — once as "pressing Settings jumps to Info", and once
    /// as a gear that did nothing because the resolver refused `.settings`.
    private func select(_ tab: TabRef) {
        selectedTab = tab
        tabSelection.wrappedValue = tab
    }

    /// One tab's content.
    ///
    /// A shipped tab renders through its own view, which knows how to lay its cards out and
    /// keeps its own scroll state. A tab the reader built renders through `TabCardStack`, which
    /// draws the cards they placed there from anywhere in the app. Both read the same
    /// composition, so hiding a card takes it out of either.
    @ViewBuilder
    private func selectedTabContent(state: VehicleState, tab: TabRef) -> some View {
        switch tab {
        case .builtIn(.vehicle):
            VehicleTabView(layout: TabLayout.resolve(tabComposition, for: tab),
                           state: state, cars: cars, activeVin: activeVin,
                           brand: commandBrand,
                           remoteCommandInProgress: remoteCommandInProgress,
                           inFlightCommandID: inFlightRemoteCommandID,
                           onRemoteCommand: onRemoteCommand,
                           onSelectCar: onSelectCar,
                           onDismissCommandReceipt: onDismissCommandReceipt,
                           onVerifyReceipt: { _ in onRefresh() },
                           error: error,
                           history: history, reverseGeocoder: reverseGeocoder,
                           imageCache: imageCache)
                .id(state.identity.vin)
                .transition(.opacity)

        case .builtIn(.info):
            InfoTabView(state: state, history: history, imageCache: imageCache,
                        reverseGeocoder: reverseGeocoder,
                        onRefresh: onRefresh,
                        onNavigateToHistory: navigateFromInfoToHistory,
                        onRemoteCommand: onRemoteCommand,
                        layout: TabLayout.resolve(tabComposition, for: tab))
                .id(state.identity.vin)
                .transition(.opacity)

        case .builtIn(.history):
            HistoryDashboardView(state: state, history: history,
                                 initialSection: historyJumpTarget,
                                 layout: TabLayout.resolve(tabComposition, for: tab))
                .id(state.identity.vin)
                .transition(.opacity)

        case .builtIn(.controls):
            ControlsTabView(state: state,
                            brand: commandBrand,
                            remoteCommandInProgress: remoteCommandInProgress,
                            inFlightCommandID: inFlightRemoteCommandID,
                            feedback: lastRemoteCommandFeedback,
                            imageCache: imageCache,
                            onRemoteCommand: onRemoteCommand,
                            onRefresh: onRefresh,
                            onDismissCommandReceipt: onDismissCommandReceipt,
                            layout: TabLayout.resolve(tabComposition, for: tab))
                .transition(.opacity)

        case .builtIn(.settings):
            EmptyView()

        case .custom:
            TabCardStack(
                tab: tab,
                state: state,
                preferences: preferences,
                history: history,
                reverseGeocoder: reverseGeocoder,
                imageCache: imageCache,
                cars: cars,
                activeVin: activeVin,
                error: error,
                remoteCommandInProgress: remoteCommandInProgress,
                inFlightRemoteCommandID: inFlightRemoteCommandID,
                onRefresh: onRefresh,
                onRemoteCommand: onRemoteCommand,
                onSelectCar: onSelectCar,
                onDismissCommandReceipt: onDismissCommandReceipt
            )
            .id(state.identity.vin)
            .transition(.opacity)
        }
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
            && !showsSettings
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
        // The bar is the reader's tab list, in their order, including the tabs they built and
        // excluding the ones they hid, with Settings last. Settings is a tab like the others
        // here because it is where the list is managed: a reader who hid every other tab still
        // needs one place that answers "where did everything go?".
        let tabs = tabComposition.visibleTabs()
        let current = currentTab
        return awardConceptHeader(tabs: tabs, current: current)
    }

    /// Production counterpart of the award concept's instrument header. The compact panel uses
    /// the same destinations as the wide panel, expressed as icons instead of hiding tabs in a
    /// horizontal scroller. At standard width the labels return and the full wordmark still fits.
    private func awardConceptHeader(tabs: [TabRef], current: TabRef) -> some View {
        let compact = HisingenTheme.layoutWidth < 540
        let wide = HisingenTheme.layoutWidth >= 700
        return HStack(spacing: wide ? 18 : 8) {
            HStack(spacing: 7) {
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(HisingenTheme.accent)
                        .frame(width: 4, height: 18)
                        .rotationEffect(.degrees(8))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(HisingenTheme.accent)
                        .frame(width: 4, height: 18)
                        .rotationEffect(.degrees(8))
                }
                .accessibilityHidden(true)
                if !compact {
                    Text("Hisingen")
                        .hisType(size: wide ? 17 : 15, relativeTo: .title2, weight: .semibold)
                }
            }
            .frame(width: compact ? 14 : (wide ? 104 : 82), alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)

            HStack(spacing: wide ? 5 : 2) {
                ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                    Button {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        withAnimation(tabIndicatorAnimation) { select(tab) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tabComposition.symbol(for: tab))
                                .hisType(.label, weight: current == tab ? .semibold : .regular)
                            if !compact {
                                Text(tabComposition.title(for: tab))
                                    .hisType(.label, weight: current == tab ? .bold : .medium)
                                    .lineLimit(1)
                            }
                        }
                        .foregroundStyle(current == tab ? HisingenTheme.ink : HisingenTheme.inkMuted)
                        .padding(.horizontal, compact ? 11 : (wide ? 15 : 7))
                        .frame(minWidth: compact ? 38 : nil, minHeight: wide ? 46 : 38)
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .background {
                            if current == tab { tabIndicator }
                        }
                    }
                    .buttonStyle(.pressable)
                    .focusEffectDisabled()
                    .help(tabComposition.title(for: tab))
                    .accessibilityLabel(tabComposition.title(for: tab))
                    .applyTabShortcut(index: index)
                    .accessibilityAddTraits(current == tab ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                onSettings()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .hisSymbolSize(16, weight: .semibold)
                    .frame(width: wide ? 40 : 34, height: wide ? 40 : 34)
            }
            .buttonStyle(.pressable)
            .keyboardShortcut(",", modifiers: .command)
            .help(L10n.text("Settings…"))
            .accessibilityLabel(L10n.text("Settings…"))
        }
        .padding(.horizontal, wide ? 22 : 12)
        .padding(.vertical, wide ? 14 : 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// The tab selection, drawn as the one piece of chrome that moves: in the 2026 language it
    /// is glass, a lens over the panel material that carries the system's own hover and press
    /// responses rather than a tinted rectangle. On macOS 15 the same capsule falls back to the
    /// palette's selected fill, so the selection still reads without the material.
    private var tabIndicator: some View {
        Color.clear
            .hisControlGlass(in: Capsule(), fallback: HisingenTheme.fill(.selected))
            .matchedGeometryEffect(id: "tabIndicator", in: tabIndicatorNamespace)
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
                    .hisSymbolSize(22)
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
                select(.settings)
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
                let freshnessColor: Color = age < 30 ? HisingenTheme.semanticGood : (age < 120 ? HisingenTheme.semanticWarning : HisingenTheme.semanticCritical)
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

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .hisAnimation(Motion.stateChange, value: updateVersion)
        .hisAnimation(Motion.stateChange, value: checkingForUpdates)
    }
}

private extension View {
    /// ⌘1–⌘9 for the first nine tabs, and nothing for the rest.
    ///
    /// A tab bar that grows with the reader's tabs cannot promise a key for every tab, and
    /// binding an eleventh button to "1" would silently take the shortcut away from the first.
    @ViewBuilder
    func applyTabShortcut(index: Int) -> some View {
        if index < 9 {
            keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        } else {
            self
        }
    }
}
