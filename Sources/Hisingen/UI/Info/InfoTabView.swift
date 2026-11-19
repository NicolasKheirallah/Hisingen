import AppKit
import SwiftUI

/// The Info tab. The card bodies are split across `InfoTabView+*.swift` (Hero, Capabilities,
/// Diagnostics, BatteryHealth, Location, Specs); this file keeps the section list, the nav
/// bar, async data loading, and the shared vehicle-report export. Swift extensions in other
/// files can only reach `internal` members, so the view state and helpers those cards touch
/// are declared without `private`.
@MainActor
struct InfoTabView: View {
    @Environment(\.dynamicTypeSize) var passportTypeSize

    /// The reader's layout for this tab: what to draw, and in what order. The default draws
    /// everything exactly as designed.
    var layout: TabLayout = .everything

    func draws(_ item: TabItemID) -> Bool { layout.draws(item) }

    func ordered<T>(_ entries: [T], by item: (T) -> TabItemID) -> [T] {
        let resolved = layout.isDefault ? TabLayout(items: TabItemCatalog.defaultItems(for: .info)) : layout
        return resolved.ordered(entries, by: item)
    }

    let state: VehicleState
    let history: HistoryWorkspace
    let imageCache: CarImageCache
    let reverseGeocoder: ReverseGeocoder
    var onNavigateToHistory: (() -> Void)? = nil
    var onRemoteCommand: (RemoteCommand) -> Void = { _ in }
    /// The command context for the controls that live on Car: locks, windows and locate, and
    /// software install.
    var brand: VehicleBrand = .polestar
    var remoteCommandInProgress = false
    var inFlightCommandID: String? = nil
    var onRefresh: () -> Void = {}
    var initialSection: TabItemID? = nil
    var onNavigateToSettings: ((SettingsDestination) -> Void)? = nil
    var onNavigateToPlan: ((TabItemID) -> Void)? = nil
    var onNavigateToChargeLocation: ((String) -> Void)? = nil
    var onNavigateToLogSection: ((TabItemID) -> Void)? = nil

    @State var selectedAngleIndex: Int = CarRenderAngle.frontThreeQuarter.rawValue
    @State var addressText: String?
    @State var addressResolved = false
    @Environment(\.preferencesStore) var preferences
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var vinCopied = false
    @State var asyncData = InfoAsyncData()
    /// Whether the local read has completed once. The activity section used to be added only when
    /// it had rows, so "nothing recorded" and "not read yet" were both simply silence: the section
    /// appeared out of nowhere a moment after the tab opened, and an empty store looked the same
    /// as an unread one.
    @State var asyncDataLoaded = false
    @State var showAllCapabilities = false
    @State var reportError: String?
    @State private var selectedCategory: InfoCategory = .all

    enum InfoCategory: String, CaseIterable, Identifiable {
        case all
        case specs
        case battery
        case status

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return L10n.text("All")
            case .specs: return L10n.text("Specs")
            case .battery: return L10n.text("Battery")
            case .status: return L10n.text("Status")
            }
        }

        func matches(_ section: InfoSection) -> Bool {
            switch self {
            case .all:
                return true
            case .specs:
                switch section {
                case .overview, .factoryBuild, .powertrain, .exterior, .interior, .software, .softwareControls, .connectivity:
                    return true
                default:
                    return false
                }
            case .battery:
                return section == .powertrain || section == .batteryHealth || section == .batteryDiagnostics || section == .chargeLocations
            case .status:
                return section == .doors || section == .tyres || section == .fluids || section == .location || section == .weather || section == .trip || section == .airQuality || section == .service || section == .warranty || section == .capabilities || section == .activity || section == .freshness || section == .lockControls || section == .windowControls
            }
        }
    }

    /// Declared explicitly: non-`private` `@State`/`@Environment` (needed so the split-out
    /// `InfoTabView+*.swift` extensions can reach them) otherwise perturbs the synthesized
    /// memberwise initializer.
    init(
        state: VehicleState,
        history: HistoryWorkspace,
        imageCache: CarImageCache,
        reverseGeocoder: ReverseGeocoder,
        onNavigateToHistory: (() -> Void)? = nil,
        onRemoteCommand: @escaping (RemoteCommand) -> Void = { _ in },
        brand: VehicleBrand = .polestar,
        remoteCommandInProgress: Bool = false,
        inFlightCommandID: String? = nil,
        onRefresh: @escaping () -> Void = {},
        layout: TabLayout = .everything,
        initialSection: TabItemID? = nil,
        onNavigateToSettings: ((SettingsDestination) -> Void)? = nil,
        onNavigateToPlan: ((TabItemID) -> Void)? = nil,
        onNavigateToChargeLocation: ((String) -> Void)? = nil,
        onNavigateToLogSection: ((TabItemID) -> Void)? = nil
    ) {
        self.brand = brand
        self.remoteCommandInProgress = remoteCommandInProgress
        self.inFlightCommandID = inFlightCommandID
        self.onRefresh = onRefresh
        self.state = state
        self.history = history
        self.imageCache = imageCache
        self.reverseGeocoder = reverseGeocoder
        self.onNavigateToHistory = onNavigateToHistory
        self.onRemoteCommand = onRemoteCommand
        self.layout = layout
        self.initialSection = initialSection
        self.onNavigateToSettings = onNavigateToSettings
        self.onNavigateToPlan = onNavigateToPlan
        self.onNavigateToChargeLocation = onNavigateToChargeLocation
        self.onNavigateToLogSection = onNavigateToLogSection
    }

    /// Everything the Info tab derives from the local store lives on the Vehicle History
    /// ledger's read model (aliased here so the split-out card extensions keep their names).
    typealias InfoAsyncData = VehicleHistoryLedger.RecentRecords

    /// Stable identity + ordering for every card, so the "jump to section" menu and the render
    /// loop derive from one list instead of two hand-synced copies.
    enum InfoSection: String, CaseIterable, Hashable {
        case overview, doors, tyres, fluids, software, location, weather
        case trip, powertrain, batteryHealth, batteryDiagnostics, airQuality
        case connectivity, service, warranty, exterior, interior, chargeLocations
        case factoryBuild, capabilities, activity, freshness
        case lockControls, windowControls, softwareControls

        var title: String {
            switch self {
            case .overview: return L10n.text("Overview")
            case .doors: return L10n.text("Doors & Openings")
            case .tyres: return L10n.text("Tyres")
            case .fluids: return L10n.text("Fluids & Lighting")
            case .software: return L10n.text("Software & Updates")
            case .location: return L10n.text("Parking Location")
            case .weather: return L10n.text("Ambient Conditions")
            case .trip: return L10n.text("Trip Computer")
            case .powertrain: return L10n.text("Powertrain & Specs")
            case .batteryHealth: return L10n.text("Battery Health")
            case .batteryDiagnostics: return L10n.text("Battery Diagnostics")
            case .airQuality: return L10n.text("Air Quality")
            case .connectivity: return L10n.text("Connectivity & Wake")
            case .service: return L10n.text("Service Schedule")
            case .warranty: return L10n.text("Warranty & Protection")
            case .exterior: return L10n.text("Exterior & Styling")
            case .interior: return L10n.text("Interior & Cabin")
            case .chargeLocations: return L10n.text("Saved Charge Locations")
            case .factoryBuild: return L10n.text("Factory Build & Identity")
            case .capabilities: return L10n.text("Vehicle Capabilities")
            case .activity: return L10n.text("Activity History")
            case .freshness: return L10n.text("Reading Freshness")
            case .lockControls: return L10n.text("Lock controls")
            case .windowControls: return L10n.text("Windows, honk & flash")
            case .softwareControls: return L10n.text("Vehicle software controls")
            }
        }
    }


    /// The composition identity of each section. The section list and the catalog are the same
    /// inventory under two names, and this is the one place they are tied together.
    static func item(for section: InfoSection) -> TabItemID {
        switch section {
        case .overview: return .infoOverview
        case .doors: return .infoDoors
        case .tyres: return .infoTyres
        case .fluids: return .infoFluids
        case .software: return .infoSoftware
        case .location: return .infoLocation
        case .weather: return .infoWeather
        case .trip: return .infoTrip
        case .powertrain: return .infoPowertrain
        case .batteryHealth: return .infoBatteryHealth
        case .batteryDiagnostics: return .infoBatteryDiagnostics
        case .airQuality: return .infoAirQuality
        case .connectivity: return .infoConnectivity
        case .service: return .infoService
        case .warranty: return .infoWarranty
        case .exterior: return .infoExterior
        case .interior: return .infoInterior
        case .chargeLocations: return .infoChargeLocations
        case .factoryBuild: return .infoFactoryBuild
        case .capabilities: return .infoCapabilities
        case .activity: return .infoActivity
        case .freshness: return .infoFreshness
        case .lockControls: return .controlsAccess
        case .windowControls: return .controlsWindowsLocate
        case .softwareControls: return .controlsOTA
        }
    }

    var commandGate: ControlsCommandGate {
        ControlsCommandGate(
            state: state,
            brand: brand,
            preferences: preferences,
            remoteCommandInProgress: remoteCommandInProgress,
            inFlightCommandID: inFlightCommandID,
            onRemoteCommand: onRemoteCommand
        )
    }

    struct InfoSectionEntry: Identifiable {
        let id: InfoSection
        let view: AnyView
    }

    private enum Workflow {
        case specifications, access, software, service, battery

        init?(section: InfoSection) {
            switch section {
            case .factoryBuild, .powertrain, .exterior, .interior: self = .specifications
            case .location, .doors, .lockControls, .windowControls: self = .access
            case .software, .softwareControls: self = .software
            case .service, .fluids, .warranty: self = .service
            case .batteryHealth, .batteryDiagnostics: self = .battery
            default: return nil
            }
        }

        var title: String? {
            switch self {
            case .specifications: return L10n.text("Vehicle Specifications")
            case .access: return L10n.text("Parking & Access")
            case .service: return L10n.text("Service & Protection")
            case .battery: return L10n.text("Battery")
            case .software: return nil
            }
        }
    }

    private struct WorkflowRun: Identifiable {
        let workflow: Workflow?
        var sections: [InfoSectionEntry]
        var id: InfoSection { sections[0].id }
    }

    private func workflows(for entries: [InfoSectionEntry]) -> [WorkflowRun] {
        entries.reduce(into: []) { runs, entry in
            let workflow = Workflow(section: entry.id)
            if let workflow, runs.last?.workflow == workflow {
                runs[runs.count - 1].sections.append(entry)
            } else {
                runs.append(WorkflowRun(workflow: workflow, sections: [entry]))
            }
        }
    }

    var availableExteriorAngles: [CarRenderAngle] {
        CarRenderAngle.allCases.filter { angle in
            imageCache.hasImage(for: state.identity.vin, angle: angle.rawValue)
                || (angle == preferences.carRenderAngle && state.identity.imageData != nil)
        }
    }

    var body: some View {
        let allEntries = makeSections()
        let category = draws(.infoNavBar) ? selectedCategory : .all
        let entries = allEntries.filter { category.matches($0.id) }
        return ScrollViewReader { proxy in
            VStack(spacing: HisingenTheme.sectionSpacing) {
                if draws(.infoNavBar) {
                    infoNavBar(proxy: proxy, entries: allEntries)
                }
                ForEach(workflows(for: entries)) { run in
                    VStack(alignment: .leading, spacing: run.sections.count > 1 ? 6 : 0) {
                        if run.sections.count > 1, let title = run.workflow?.title {
                            Text(title)
                                .hisType(.heading, weight: .semibold)
                                .foregroundStyle(HisingenTheme.ink)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.horizontal, HisingenTheme.cardPadding)
                        }
                        ForEach(run.sections) { entry in
                            entry.view
                                .id(entry.id)
                                .transition(.opacity)
                        }
                    }
                }
            }
            .hisAnimation(Motion.cardChange, value: entries.map(\.id))
            .onAppear {
                let preferred = preferences.carRenderAngle
                selectedAngleIndex = availableExteriorAngles.contains(preferred)
                    ? preferred.rawValue
                    : (availableExteriorAngles.first?.rawValue ?? selectedAngleIndex)
            }
            .task(id: "\(state.identity.vin)|\(state.freshness.fetchedAt.timeIntervalSince1970)") { await loadAsyncData() }
            .task(id: coordinateKey) { await resolveAddressIfNeeded() }
            .onChange(of: initialSection, initial: true) { _, target in
                guard let target, let section = allEntries.first(where: { Self.item(for: $0.id) == target }) else { return }
                jump(to: section.id, proxy: proxy)
            }
            // Every `reportError` comes from writing a report, CSV, pack or image out of the
            // app, so the title names that; the message carries the system's cause.
            .alert(
                L10n.text("Export failed"),
                isPresented: Binding(get: { reportError != nil }, set: { if !$0 { reportError = nil } })
            ) {
                Button(L10n.text("OK"), role: .cancel) {}
            } message: {
                Text(reportError ?? "")
            }
        }
    }

    // MARK: - Section assembly

    private func makeSections() -> [InfoSectionEntry] {
        var out: [InfoSectionEntry] = []
        func add(_ id: InfoSection, _ view: some View) {
            // The reader's layout decides what this tab draws. Hidden sections are simply not
            // built, so a card switched off costs nothing to render.
            guard draws(Self.item(for: id)) else { return }
            out.append(InfoSectionEntry(id: id, view: AnyView(view)))
        }

        if HisingenTheme.layoutWidth < 580 && hasVehiclePhotos {
            add(.overview, heroVisualSection)
        } else {
            add(.overview, awardVehiclePassport)
        }

        if let ext = state.exteriorStatus, !ext.openings.isEmpty {
            add(.doors, DoorsAndOpeningsCardView(ext: ext, isLocked: ext.isLocked,
                                                 isTailgateLocked: ext.isTailgateLocked,
                                                 model: state.model))
        }
        if preferences.features.contains(.tyreAndWarnings) {
            add(.tyres, VehicleTyresCard(state: state))
        }
        add(.fluids, fluidsAndLightingCard)
        if softwareCardHasContent {
            add(.software, softwareUpdateCard)
        }
        let features = preferences.features.enabled
        let profile = state.capabilityProfile
        let showsOTAStatus = !softwareCardHasContent || !draws(.infoSoftware)
        if features.contains(.remoteOTA) && profile.permits(.softwareInstallControl),
           showsOTAStatus || OTAControlsCard.hasCurrentControls(state.softwareInfo) {
            add(.softwareControls, OTAControlsCard(
                state: state, gate: commandGate, onRefresh: onRefresh, showsStatus: showsOTAStatus
            ))
        }
        if preferences.features.contains(.vehicleLocation) {
            add(.location, parkingLocationCard)
        }
        if features.contains(.remoteLocks) {
            add(.lockControls, AccessControlsCard(state: state, gate: commandGate))
        }
        if (features.contains(.remoteWindows) && profile.permits(.windows)) || features.contains(.remoteHonkFlash) {
            add(.windowControls, WindowsLocateCard(state: state, gate: commandGate))
        }
        if weatherCardHasContent {
            add(.weather, ambientWeatherCard)
        }
        if state.hasTripContent {
            add(.trip, tripComputerCard)
        }
        add(.powertrain, powertrainSpecsCard)
        if state.powertrain.hasElectricRange {
            add(.batteryHealth, batteryHealthCard)
        }
        if !batteryDiagnosticsRows.isEmpty {
            add(.batteryDiagnostics, batteryDiagnosticsCard)
        }
        if state.airQuality != nil {
            add(.airQuality, airQualityCleanZoneCard)
        }
        if state.connectivity != nil || state.identity.usageModeDisplayName != nil {
            add(.connectivity, connectivityWakeCard)
        }
        if serviceCardHasContent {
            add(.service, serviceAndHealthCard)
        }
        add(.warranty, warrantyAndProtectionCard)
        if exteriorCardHasContent {
            add(.exterior, exteriorStylingCard)
        }
        if interiorCardHasContent {
            add(.interior, interiorCabinCard)
        }
        if features.contains(.chargeLocations), !savedChargeLocations.isEmpty {
            add(.chargeLocations, chargeLocationsCard)
        }
        add(.factoryBuild, factoryBuildCard)
        if state.otaCapabilities != nil, !state.isVolvo {
            add(.capabilities, capabilitySection(capabilityInspectorCard))
        } else if !capabilityProfileEntries.positive.isEmpty || !capabilityProfileEntries.negative.isEmpty {
            add(.capabilities, capabilitySection(vehicleCapabilityCard))
        }
        // Present from the first paint, with a placeholder until the read lands and an explicit
        // empty state after it, rather than appearing only once it has something to show.
        if !asyncDataLoaded {
            add(.activity, activityPlaceholderCard(message: nil))
        } else if asyncData.storeUnreadable {
            add(.activity, activityPlaceholderCard(
                message: L10n.text("Hisingen could not read the local history database. Nothing has been deleted; this is a read failure, not an empty history."),
                retry: { Task { await loadAsyncData() } }
            ))
        } else {
            add(.activity, activityHistoryCard)
        }
        // Timestamps per reading are reference material: after the specifications, and only when
        // the car reported any.
        if state.hasReportedDates {
            add(.freshness, readingFreshnessCard)
        }
        // The reader's order, when they have one. Sections the layout does not name — none by
        // default — keep the position they were added in, after the ones it does.
        return ordered(out, by: { Self.item(for: $0.id) })
    }

    private func capabilitySection<Content: View>(_ content: Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content
            if let onNavigateToSettings {
                NavigationRow(title: L10n.text("Vehicle Data Settings")) { onNavigateToSettings(.vehicleCapabilities) }
                    .padding(.horizontal, HisingenTheme.cardPadding)
            }
        }
    }

    private func jump(to section: InfoSection, proxy: ScrollViewProxy) {
        if !selectedCategory.matches(section) { selectedCategory = .all }
        Task { @MainActor in
            await Task.yield()
            withAnimation(Motion.resolve(Motion.entrance)) {
                proxy.scrollTo(section, anchor: .top)
            }
        }
    }

    /// The activity section's loading and empty states, matching the header the loaded card uses so
    /// the section does not change shape when its rows arrive.
    @ViewBuilder
    private func activityPlaceholderCard(message: String?, retry: (() -> Void)? = nil) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "clock.arrow.circlepath", title: L10n.text("Recent Vehicle Activity"), color: HisingenTheme.chartInfo)
                if let message {
                    if retry != nil {
                        Label(L10n.text("History could not be read"), systemImage: "exclamationmark.triangle.fill")
                            .hisType(.label, weight: .semibold)
                            .foregroundStyle(HisingenTheme.semanticWarning)
                    }
                    Text(message).hisType(.label).foregroundStyle(.secondary)
                    if let retry {
                        Button(L10n.text("Refresh history"), action: retry)
                            .buttonStyle(.hisSecondary)
                            .controlSize(.small)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    /// An offline copy, or a reading Hisingen has not been able to re-check, is worth flagging.
    /// A car that is merely asleep, with a recent successful check, is not.
    private var freshnessNeedsAttention: Bool {
        state.freshness.isCached || state.isStale()
    }

    /// The footer already says when the panel last updated, so the Car tab names freshness only
    /// when it qualifies what follows: an offline copy, a stale check, or a sleeping car's old
    /// reading.
    private var showsFreshnessLine: Bool { freshnessNeedsAttention || state.hasOldData() }

    private func infoNavBar(proxy: ScrollViewProxy, entries: [InfoSectionEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
        if showsFreshnessLine {
        HStack(spacing: 8) {
            // A sleeping car's hour-old reading is the normal resting state, so it stays muted.
            // Warning colour is kept for when Hisingen itself could not reach the car (`isStale`),
            // which keeps it meaningful next to a real fault such as a service warning.
            Image(systemName: state.hasOldData() ? "moon.stars" : "clock.arrow.circlepath")
                .hisType(.label)
                .foregroundStyle(freshnessNeedsAttention ? HisingenTheme.semanticWarning : HisingenTheme.inkMuted)
                .hisAnimation(Motion.theme, value: freshnessNeedsAttention)
                .accessibilityHidden(true)
            Text(state.freshness.isCached ? L10n.text("Showing an offline copy") : state.freshnessDescription)
                .hisType(.caption, weight: freshnessNeedsAttention ? .semibold : .regular)
                .foregroundStyle(freshnessNeedsAttention ? HisingenTheme.semanticWarning : HisingenTheme.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .truncationMode(.middle)
                .hisAnimation(Motion.theme, value: freshnessNeedsAttention)
        }
        }
        HStack(alignment: .bottom, spacing: 12) {
            UnderlineSegments(
                options: InfoCategory.allCases.map { ($0, $0.title) },
                selection: $selectedCategory,
                accessibilityLabel: L10n.text("Info section category")
            )

            Menu {
                ForEach(entries) { entry in
                    Button(entry.id.title) {
                        jump(to: entry.id, proxy: proxy)
                    }
                }
            } label: {
                Image(systemName: "list.bullet.indent")
                    .hisType(.label, weight: .medium)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .hisCaptionLeading()
            .fixedSize(horizontal: false, vertical: true)
            .help(L10n.text("Jump to section"))
            .accessibilityLabel(L10n.text("Jump to section"))

            Menu {
                Button {
                    copyVehicleReport()
                } label: {
                    Label(L10n.text("Copy Vehicle Report"), systemImage: "doc.on.doc")
                }
                Button {
                    exportVehicleReport()
                } label: {
                    Label(L10n.text("Export Vehicle Report…"), systemImage: "square.and.arrow.up")
                }
                Button {
                    exportHandoverPack()
                } label: {
                    Label(L10n.text("Export Handover Pack…"), systemImage: "shippingbox")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .hisType(.label, weight: .medium)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .hisCaptionLeading()
            .fixedSize(horizontal: false, vertical: true)
            .help(L10n.text("Vehicle report"))
            .accessibilityLabel(L10n.text("Vehicle report"))

            // No refresh button here: the panel footer's Refresh Telemetry (⌘R) is the same
            // action, and two identical glyphs on one screen read as two different things.
        }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Async data

    private var coordinateKey: String? {
        guard draws(.infoLocation), preferences.features.contains(.vehicleLocation),
              !preferences.privacyRedactionEnabled,
              let lat = state.location?.latitude, let lon = state.location?.longitude else { return nil }
        return "\(lat),\(lon)"
    }

    private func loadAsyncData() async {
        let loaded = await history.recentRecords(vin: state.identity.vin)
        guard !Task.isCancelled else { return }
        asyncData = loaded
        asyncDataLoaded = true
    }

    private func resolveAddressIfNeeded() async {
        addressResolved = false
        addressText = nil
        guard coordinateKey != nil,
              let lat = state.location?.latitude, let lon = state.location?.longitude else { return }
        let resolved = await reverseGeocoder.geocode(latitude: lat, longitude: lon)
        guard !Task.isCancelled else { return }
        addressText = resolved
        addressResolved = true
    }

    // MARK: - Section visibility helpers

    var weatherCardHasContent: Bool { state.hasWeatherContent }

    private var serviceCardHasContent: Bool {
        state.maintenance.service.daysToService != nil
            || serviceForecast != nil
            || (state.maintenance.service.engineHoursToService ?? 0) > 0
            || (state.maintenance.service.preferredWorkshopName?.isEmpty == false)
            || (state.maintenance.service.preferredWorkshopID?.isEmpty == false)
    }

    private var exteriorCardHasContent: Bool { state.hasExteriorContent }

    private var interiorCardHasContent: Bool { state.hasInteriorContent }

    var savedChargeLocations: [ChargeLocationSnapshot] { state.savedChargeLocations }

    private var softwareCardHasContent: Bool { state.hasSoftwareContent }

    var batteryHealthEstimate: BatteryHealthEstimate? {
        if let current = BatteryHealthEstimator.estimate(
            state: state,
            specification: preferences.vehicleSpecificationOverride(for: state.identity.vin)
        ) { return current }
        let historyRecords = asyncData.batteryHealthHistory
        let rangeSources: Set<String> = [
            BatteryHealthRecord.fullChargeRangeSource,
            BatteryHealthRecord.calculatedSource,
            BatteryHealthRecord.legacyEstimateSource
        ]
        let latestRange = historyRecords.first { rangeSources.contains($0.measurementSource) }
        let latestSession = historyRecords.first {
            $0.measurementSource == BatteryHealthRecord.sessionEnergySource
        }
        if let range = latestRange, let session = latestSession,
           let fused = BatteryHealthEstimator.fusedSoH(
               rangeSoH: range.stateOfHealthPct, sessionSoH: session.stateOfHealthPct
           ) {
            let reference = history.usableCapacityKwh(vin: state.identity.vin, state: state)
            return BatteryHealthEstimator.remembered(
                stateOfHealthPercent: fused,
                degradationPercent: ((100 - fused) * 10).rounded() / 10,
                estimatedUsableCapacityKwh: (reference * fused / 100 * 10).rounded() / 10,
                recordedAt: max(range.timestamp, session.timestamp),
                fallbackReferenceCapacityKwh: reference,
                method: BatteryHealthEstimator.fusedMethod
            )
        }
        guard let saved = [latestRange, latestSession].compactMap({ $0 }).max(by: { $0.timestamp < $1.timestamp }) else { return nil }
        return BatteryHealthEstimator.remembered(
            stateOfHealthPercent: saved.stateOfHealthPct,
            degradationPercent: saved.degradationPct,
            estimatedUsableCapacityKwh: saved.effectiveUsableKwh,
            recordedAt: saved.timestamp,
            fallbackReferenceCapacityKwh: history.usableCapacityKwh(vin: state.identity.vin, state: state),
            method: saved.measurementSource == BatteryHealthRecord.sessionEnergySource
                ? BatteryHealthEstimator.sessionEnergyMethod
                : BatteryHealthEstimator.fullChargeRangeMethod
        )
    }

    // MARK: - Chart & geo helpers

    func headingToCardinal(_ heading: Double) -> String {
        let normalized = (heading.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"].map { L10n.text($0) }
        let index = Int(((normalized + 22.5) / 45.0).truncatingRemainder(dividingBy: 8))
        return directions[index]
    }

    // MARK: - Vehicle report

    private func buildVehicleReport() -> String {
        // A report is easy to paste into an email or forum thread, so honour the same
        // screenshot-privacy switch that redacts the VIN, plate, and coordinates on screen.
        let redacted = preferences.privacyRedactionEnabled
        var lines: [String] = []
        func row(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            lines.append("\(key): \(value)")
        }

        lines.append(L10n.text("Vehicle Report"))
        lines.append(String(repeating: "=", count: 44))
        row(L10n.text("Generated"), Format.dateTimeFormatter.string(from: Date()))
        row(L10n.text("Data From"), Format.relativeAge(since: state.dataTimestamp))
        if redacted {
            row(L10n.text("Privacy"), L10n.text("VIN, plate, and location redacted"))
        }
        lines.append("")

        row(L10n.text("Model"), [state.identity.modelName, state.identity.modelYear].compactMap { $0 }.joined(separator: " "))
        row(L10n.text("VIN"), redacted
            ? String(repeating: "•", count: max(0, state.identity.vin.count - 4)) + state.identity.vin.suffix(4)
            : state.identity.vin)
        if !redacted { row(L10n.text("Registration"), state.identity.registrationNo) }
        row(L10n.text("Vehicle ID"), state.identity.internalVehicleIdentifier)
        row(L10n.text("Architecture"), state.powertrain.displayName)
        if let odo = state.maintenance.odometerKm {
            row(L10n.text("Odometer"), Format.distance(km: odo, grouped: true, unit: preferences.distanceUnit))
        }
        if let battery = state.energy.batteryPercentage {
            row(L10n.text("Battery"), String(format: "%.0f%%", locale: L10n.displayLocale, battery))
        }
        if let range = state.primaryRangeKm {
            row(L10n.text("Range"), Format.distance(km: range, unit: preferences.distanceUnit))
        }
        if state.powertrain.hasElectricRange {
            row(L10n.text("Charging"), state.energy.chargingState.displayName)
            if let target = state.energy.targetPercentage {
                row(L10n.text("Charge Target"), "\(target)%")
            }
        }
        row(L10n.text("Exterior Paint"), state.identity.externalColour)
        row(L10n.text("Interior Trim"), state.identity.upholstery)
        row(L10n.text("Factory Build Week"), state.formattedBuildWeek ?? state.identity.structureWeek)
        row(L10n.text("Factory Spec (PNO34)"), state.identity.pno34)
        row(L10n.text("Market Delivery"), state.otaCapabilities?.identity?.market ?? state.identity.accountMarket)
        row(L10n.text("Backend-Reported Software"), state.softwareInfo?.installedVersion ?? state.softwareInfo?.version)

        if let days = state.maintenance.service.daysToService {
            row(L10n.text("Service Due"), L10n.format("in %d days", days))
        }
        if let inService = preferences.warrantyInServiceDate(for: state.identity.vin) {
            row(L10n.text("In-Service Date"), Format.dateFormatter.string(from: inService))
        }
        if let warranty = state.maintenance.warranty?.factoryWarrantyValidUntil {
            row(L10n.text("Manufacturer Warranty"), Format.dateFormatter.string(from: warranty))
        }

        if let estimate = batteryHealthEstimate {
            lines.append("")
            row(L10n.text("Calculated SoH"), String(format: "%.1f%%", locale: L10n.displayLocale, estimate.stateOfHealthPercent))
            row(L10n.text("Calculation Method"), L10n.text("Full-charge range estimate"))
            row(L10n.text("Last 100% calculation"), Format.dateTimeFormatter.string(from: estimate.recordedAt))
            row(L10n.text("Calculated Degradation"), String(format: "%.1f%%", locale: L10n.displayLocale, estimate.degradationPercent))
        }

        if !redacted {
            if let address = addressText {
                lines.append("")
                row(L10n.text("Parking Address"), address)
            }
            if let lat = state.location?.latitude, let lon = state.location?.longitude {
                row(L10n.text("Coordinates"), String(format: "%.5f, %.5f", locale: L10n.displayLocale, lat, lon))
            }
        }

        lines.append("")
        lines.append(L10n.text("Generated by Hisingen. Calculated values are estimates, not vehicle telemetry."))
        return lines.joined(separator: "\n")
    }

    private func copyVehicleReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(buildVehicleReport(), forType: .string)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    private func exportVehicleReport() {
        let report = buildVehicleReport()
        FileExport.save(report, type: .plainText,
                        filename: "vehicle_report_\(state.identity.vin.prefix(8)).txt") { _, error in
            if let error {
                reportError = error.localizedDescription
            } else {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
        }
    }
}
