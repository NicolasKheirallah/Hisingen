import SwiftUI

@MainActor
struct HistoryDashboardView: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.locale) private var locale
    let state: VehicleState

    let history: HistoryWorkspace

    /// A deep link from Info can target the observed activity after the initial database load.
    let initialSection: String?

    /// The reader's layout for this tab: what to draw, and in what order. The default draws
    /// everything exactly as designed.
    var layout: TabLayout = .everything
    var initialChargingSessionID: String? = nil

    func draws(_ item: TabItemID) -> Bool { layout.draws(item) }

    func ordered<T>(_ entries: [T], by item: (T) -> TabItemID) -> [T] {
        let resolved = layout.isDefault ? TabLayout(items: TabItemCatalog.defaultItems(for: .history)) : layout
        return resolved.ordered(entries, by: item)
    }

    @Environment(\.preferencesStore) var preferences

    @Environment(\.accessibilityReduceMotion) var reduceMotion

    /// The system setting for readers who cannot separate the chart series by hue. The two series
    /// that share axes carry a dash pattern on the second one when this is on.
    @Environment(\.accessibilityDifferentiateWithoutColor) var differentiateWithoutColor

    @State var period: HistoryPeriod = .month
    /// Which group of sections the tab shows. All by default, so a jump from another tab always
    /// lands on its section.
    @State var sectionGroup: HistorySectionGroup = .all

    @State var selectedSessionID: String?

    @State var sessionSearchText: String = ""
    @State var sessionFilter: ChargingSessionFilter?
    @State private var activityFilter: ActivityFilter = .all
    @State private var requestedSection: String?

    @State var tripSearchText: String = ""

    @State var tripSort: TripSort = .newest

    @State var expandedTripIDs: Set<String> = []

    @State var showHiddenTrips = false
    /// Restores applied this session; keeps the hidden list in sync without waiting for
    /// the next refresh to observe the preference change.
    @State var restoredTripIDs: Set<String> = []

    @State var mileageReportMonthStart: Date?

    /// Bumped by the manual Refresh button and fuel edits – reloads everything.
    @State var refreshToken = 0

    /// Bumped when the vehicle reports fresh data – reloads only the period-scoped queries
    /// (new trips/sessions/telemetry rows); the lifetime series barely move minute to minute.
    @State var dataToken = 0

    @State var didInitialLoad = false

    // Starts true so the first paint shows the skeleton instead of a flash of empty cards;
    // the first successful load clears it.
    @State var isLoading = true

    @State var overlayPreviousSession = false

    /// Drives the selected-session curve card's live dot (same treatment as the live
    /// curve in ChargingCurveView).
    @State var curveLivePulse = false

    /// One base value the whole dashboard scales from, so the OS "larger text" setting grows
    /// the charts and captions instead of being ignored by hard-coded point sizes.
    @ScaledMetric(relativeTo: .body) var chartHeight: CGFloat = 112

    enum HistoryPeriod: String, CaseIterable, Identifiable {
        case week = "7 Days"
        case month = "30 Days"
        case quarter = "90 Days"
        case year = "1 Year"
        case all = "All"
        case custom = "Custom…"
        var id: String { rawValue }
        var days: Int? {
            switch self {
            case .week: return 7
            case .month: return 30
            case .quarter: return 90
            case .year: return 365
            case .all, .custom: return nil
            }
        }
    }

    typealias TripSort = HistoryTripSort

    @State var fuelLitersText: String = ""

    @State var fuelPriceText: String = ""

    @State var fuelOdometerText: String = ""

    @State var showFuelSheet = false

    @State var fuelEntryPendingDeletion: HistoryWorkspace.FuelEntry?

    // The charging-session entry sheet. One set of fields covers both logging a session by hand
    // and editing a stored one; `editingChargingSession` says which.
    @State var showChargingSessionSheet = false
    @State var editingChargingSession: HistoricalChargingSession?
    @State var sessionStartedAt = Date().addingTimeInterval(-1_800)
    @State var sessionEndedAt = Date()
    @State var sessionLocationText = ""
    @State var sessionEnergyText = ""
    @State var sessionTotalPriceText = ""
    @State var sessionPricePerKwhText = ""
    @State var sessionPlace: ChargingSessionPlace = .publicCharging

    @State var exportError: String?

    @State var exportNotice: String?

    @State var customRangeStart: Date = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()

    @State var customRangeEnd: Date = Date()

    @State var showCustomRangeEditor = false

    typealias HistoryDataSnapshot = VehicleHistoryLedger.DashboardSnapshot
    typealias LifetimeSnapshot = VehicleHistoryLedger.LifetimeSnapshot

    @State var snapshot = HistoryDataSnapshot()

    @State var lifetime = LifetimeSnapshot()

    /// Hidden-trip rows, loaded off the main actor when the hidden set changes so
    /// `hiddenTripsSection` only filters this cache instead of re-running `derivedTrips`
    /// on every render.
    @State var hiddenTripRows: [TripHistoryEntry] = []

    @State private var tripDateStrings: [String: String] = [:]
    @State private var sessionLabelStrings: [String: String] = [:]

    @State var selectedSessionSamples: [HistoricalChargingSample] = []
    @State var selectedSessionChargerPower: [VehicleMetricRecord] = []
    /// The price per kWh through the selected session, loaded apart from the curve because it
    /// may wait on Tibber. `loadedSessionPricesID` says which session it belongs to.
    @State var selectedSessionPrices: SessionPriceSeries?
    @State var loadedSessionPricesID: String?
    @State var sessionNoteDraft = ""
    /// Notes the reader wrote on sessions, keyed by session id; loaded with the dashboard and
    /// updated in place when one is saved.
    @State var sessionNotes: [String: String] = [:]
    @State var loadedSessionCurveID: String?

    @State var presentation = HistoryPresentationSnapshot()

    @State var tripPresentation = HistoryTripPresentation()

    @State var filteredSessionRows: [HistoricalChargingSession] = []

    @State var selectedSessionCurvePoints: [HistoryInsights.ChargingCurvePoint] = []

    @State var loadedLifetimeKey: String?

    @State var previousSessionCurve: [HistoryInsights.ChargingCurvePoint] = []

    @Environment(\.homeCharging) var homeCharging
    /// The car's part of the house's metered electricity for the period, when a house meter (Tibber or
    /// Perific) is connected and a home charger measured sessions in it.
    @State var houseLoad: HouseLoadShare?

    /// Inclusive date window for the selected period. `nil` means "no filter" (the All case).
    var activeRange: ClosedRange<Date>? {
        let calendar = Calendar.current
        switch period {
        case .all:
            return nil
        case .custom:
            let low = calendar.startOfDay(for: min(customRangeStart, customRangeEnd))
            let highDay = calendar.startOfDay(for: max(customRangeStart, customRangeEnd))
            let high = calendar.date(byAdding: .day, value: 1, to: highDay) ?? max(customRangeStart, customRangeEnd)
            return low...high
        default:
            guard let days = period.days,
                  let low = calendar.date(byAdding: .day, value: -days, to: Date()) else { return nil }
            return low...Date().addingTimeInterval(60)
        }
    }

    var trips: [TripHistoryEntry] { tripPresentation.trips }
    /// Period-scoped, hidden-filtered, search-ignored: what the summary cards describe.
    var aggregateTrips: [TripHistoryEntry] { tripPresentation.aggregateTrips }

    var tripFilterText: String { tripSearchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var chargingSessions: [HistoricalChargingSession] { snapshot.chargingSessions }

    var commands: [RemoteCommandAuditRecord] { snapshot.commands }

    var batteryHealthRecords: [BatteryHealthRecord] { lifetime.batteryHealthRecords }

    var airQualityRecords: [AirQualityRecord] { snapshot.airQualityRecords }

    var telemetryRecords: [HistoricalTelemetryRecord] { snapshot.telemetryRecords }

    var allTimeTelemetryRecords: [HistoricalTelemetryRecord] { lifetime.allTimeTelemetryRecords }

    var fuelEntries: [HistoryWorkspace.FuelEntry] { lifetime.fuelEntries }

    var cabinClimateRecords: [HistoryWorkspace.CabinClimateRecord] { lifetime.cabinClimateRecords }

    var efficiencyPoints: [HistoryInsights.EfficiencyPoint] {
        presentation.efficiencyPoints
    }

    var combustionConsumptionPoints: [HistoryInsights.EfficiencyPoint] {
        presentation.combustionConsumptionPoints
    }

    var odometerPoints: [HistoryInsights.OdometerPoint] {
        presentation.odometerPoints
    }

    var allTimeOdometerPoints: [HistoryInsights.OdometerPoint] {
        presentation.allTimeOdometerPoints
    }

    var selectedSession: HistoricalChargingSession? {
        guard let selectedSessionID else { return nil }
        return chargingSessions.first { $0.id.caseInsensitiveCompare(selectedSessionID) == .orderedSame }
    }

    var selectedSessionCurve: [HistoryInsights.ChargingCurvePoint] {
        selectedSessionCurvePoints
    }

    var filteredSessionsForPicker: [HistoricalChargingSession] {
        filteredSessionRows
    }

    var commandStatistics: HistoryInsights.CommandStatistics {
        presentation.commandStatistics
    }

    var hasAnyDataInRange: Bool {
        !trips.isEmpty || !chargingSessions.isEmpty || !commands.isEmpty || !snapshot.activities.isEmpty
            || airQualityRecords.count >= 2 || odometerPoints.count >= 3
            || !tyreRecords.isEmpty || !warningEvents.isEmpty
            || efficiencyPoints.count >= 3 || combustionConsumptionPoints.count >= 3
    }

    /// The store could not be read, so nothing below is evidence about the user's history.
    var storeUnreadable: Bool { snapshot.storeUnreadable }

    var hasAnyDataAtAll: Bool {
        hasAnyDataInRange || snapshot.hasHistoryOutsideRange
            || !batteryHealthRecords.isEmpty || !fuelEntries.isEmpty
            || cabinClimateRecords.count >= 2 || !allTimeTelemetryRecords.isEmpty
    }

    struct SmoothedPoint: Identifiable {
        let id: Int64
        let timestamp: Date
        let value: Double
    }

    var observedChangesCard: some View {
        HistoryCardSurface {
            VStack(alignment: .leading, spacing: 8) {
                HistorySectionHeading(symbol: "clock.arrow.circlepath", title: L10n.text("Observed Changes"), color: HisingenTheme.chartInfo)
                PaginatedSection(items: snapshot.activities, pageSize: preferences.historyPageSize(for: .historyActivity),
                                 resetKeys: [periodLoadKey],
                                 emptyMessage: L10n.text("No activity was recorded in this period.")) { visible, footer in
                    VehicleActivityList(events: Array(visible))
                    footer
                }
            }
        }
    }

    enum HistorySectionGroup: String, CaseIterable, Hashable {
        case all, charging, driving, energy, climate, activity, status

        var title: String {
            switch self {
            case .all: return L10n.text("All")
            case .charging: return L10n.text("Charging")
            case .driving: return L10n.text("Driving")
            case .energy: return L10n.text("Energy & Fuel")
            case .climate: return L10n.text("Cabin")
            case .activity: return L10n.text("Activity")
            case .status: return L10n.text("Status")
            }
        }

        func contains(_ sectionID: String) -> Bool {
            if self == .all || sectionID == "overview" { return true }
            if sectionID == "month" { return self == .charging || self == .driving }
            return HistoryCollection.forSection(sectionID)?.group == self
        }
    }

    private enum ActivityFilter: String, CaseIterable {
        case all, observations, warnings, commands

        var title: String {
            switch self {
            case .all: return L10n.text("All")
            case .observations: return L10n.text("Observed Changes")
            case .warnings: return L10n.text("Warnings")
            case .commands: return L10n.text("Commands")
            }
        }

        func shows(_ id: String) -> Bool {
            switch self {
            case .all: return true
            case .observations: return id == "activity"
            case .warnings: return id == "warnings"
            case .commands: return id == "automations"
            }
        }
    }

    private enum HistoryCollection: String {
        case sessions, chargingSummary, driving, energy, cabin, activity, status

        static func forSection(_ id: String) -> Self? {
            switch id {
            case "charging-sessions", "charging-curve": return .sessions
            case "charging-history", "monthly-charging", "charge-locations": return .chargingSummary
            case "trips", "driving-patterns", "distance", "monthly-mileage", "odometer": return .driving
            case "efficiency", "consumption", "fuel-economy", "recent-fills", "emissions": return .energy
            case "air-cleaning", "air-quality", "cabin-climate": return .cabin
            case "activity", "warnings", "automations": return .activity
            case "battery-health", "tyre-pressure": return .status
            default: return nil
            }
        }

        var group: HistorySectionGroup {
            switch self {
            case .sessions, .chargingSummary: return .charging
            case .driving: return .driving
            case .energy: return .energy
            case .cabin: return .climate
            case .activity: return .activity
            case .status: return .status
            }
        }

        var title: String {
            self == .chargingSummary ? L10n.text("Charging Summary") : group.title
        }
    }

    private struct HistoryRun: Identifiable {
        let collection: HistoryCollection?
        var sections: [HistorySection]
        var id: String { "group-\(sections[0].id)" }
    }

    struct HistorySection: Identifiable {
        let id: String
        let title: String
        let isVisible: Bool

        var item: TabItemID? { TabItemID(rawValue: "history-\(id)") }
    }

    var historySections: [HistorySection] {
        [
            HistorySection(id: "overview", title: L10n.text("Overview"), isVisible: true),
            HistorySection(id: "activity", title: L10n.text("Observed Changes"), isVisible: !snapshot.activities.isEmpty),
            HistorySection(id: "warnings", title: L10n.text("Warning Timeline"), isVisible: !warningEvents.isEmpty),
            HistorySection(id: "month", title: L10n.text("Month Comparison"), isVisible: true),
            HistorySection(id: "air-cleaning", title: L10n.text("Air Cleaning"),
                           isVisible: snapshot.activities.contains(where: { $0.kind == .airCleaning })),
            HistorySection(id: "emissions", title: L10n.text("Emissions"), isVisible: true),
            HistorySection(id: "driving-patterns", title: L10n.text("Driving Patterns"), isVisible: !trips.isEmpty),
            HistorySection(id: "distance", title: L10n.text("Distance"), isVisible: !trips.isEmpty),
            HistorySection(id: "monthly-mileage", title: L10n.text("Monthly Mileage"), isVisible: !trips.isEmpty),
            HistorySection(id: "trips", title: L10n.text("Trips"), isVisible: !trips.isEmpty),
            HistorySection(id: "charging-sessions", title: L10n.text("Charging Sessions"),
                           isVisible: !chargingSessions.isEmpty),
            HistorySection(id: "charging-curve", title: L10n.text("Charging Curve"),
                           isVisible: selectedSession != nil),
            HistorySection(id: "monthly-charging", title: L10n.text("Charging by Month"),
                           isVisible: !chargingSessions.isEmpty),
            HistorySection(id: "charge-locations", title: L10n.text("Charge Locations"),
                           isVisible: !chargingSessions.isEmpty),
            HistorySection(id: "charging-history", title: L10n.text("Charging Trends"),
                           isVisible: !chargingSessions.isEmpty),
            HistorySection(id: "fuel-economy", title: L10n.text("Fuel Economy"), isVisible: !fuelEntries.isEmpty),
            HistorySection(id: "recent-fills", title: L10n.text("Recent Fill-ups"), isVisible: state.powertrain.hasCombustionEngine || !fuelEntries.isEmpty),
            HistorySection(id: "efficiency", title: L10n.text("Efficiency"),
                           isVisible: efficiencyPoints.count >= 3),
            HistorySection(id: "consumption", title: L10n.text("Consumption"),
                           isVisible: combustionConsumptionPoints.count >= 3),
            HistorySection(id: "odometer", title: L10n.text("Odometer"),
                           isVisible: odometerPoints.count >= 3),
            HistorySection(id: "battery-health", title: L10n.text("Battery Health"),
                           isVisible: !batteryHealthRecords.isEmpty || snapshot.batteryLevels.count >= 3),
            HistorySection(id: "tyre-pressure", title: L10n.text("Tyre Pressure"),
                           isVisible: tyreRecords.count >= 2),
            HistorySection(id: "air-quality", title: L10n.text("Air Quality"),
                           isVisible: airQualityRecords.count >= 2),
            HistorySection(id: "cabin-climate", title: L10n.text("Cabin Climate"),
                           isVisible: cabinClimateRecords.count >= 2),
            HistorySection(id: "automations", title: L10n.text("Automations"), isVisible: !commands.isEmpty),
            // The terminal states, first because every other state is a claim about the data and
            // this one says the data could not be reached at all.
            HistorySection(id: "store-unreadable", title: L10n.text("History could not be read"),
                           isVisible: storeUnreadable),
            HistorySection(id: "empty", title: L10n.text("No history yet"),
                           isVisible: !storeUnreadable && hasAnyDataAtAll == false),
            HistorySection(id: "nothing-in-range", title: L10n.text("Nothing in this period"),
                           isVisible: !storeUnreadable && hasAnyDataAtAll && !hasAnyDataInRange)
        ]
    }

    var visibleHistorySections: [HistorySection] {
        let drawn = historySections.filter { section in
            guard section.isVisible else { return false }
            // The terminal states are never composable: a reader who emptied the tab still
            // needs to be told the store could not be read, or that nothing was recorded.
            guard let item = section.item else { return true }
            return draws(item)
        }
        // The reader's order, with the terminal states left where they are: they describe the
        // data, not the layout, and belong at the end whichever way the cards are arranged.
        let group = draws(.historyPeriodPicker) ? sectionGroup : .all
        let grouped = drawn.filter { $0.item == nil || group.contains($0.id) }
        let cards = grouped.compactMap { section in section.item.map { (section: section, item: $0) } }
        return ordered(cards, by: \.item).map(\.section) + grouped.filter { $0.item == nil }
    }

    var showsChargingSummary: Bool {
        guard draws(.historyChargingHistory), !chargingSessions.isEmpty else { return false }
        return !draws(.historyPeriodPicker) || sectionGroup.contains("charging-history")
    }

    var embedsChargingCurve: Bool {
        layout.includesNewItems && draws(.historyChargingSessions) && draws(.historyChargingCurve)
    }

    private var historyRuns: [HistoryRun] {
        visibleHistorySections.reduce(into: []) { runs, section in
            if embedsChargingCurve && section.id == "charging-curve" { return }
            let collection = layout.includesNewItems ? HistoryCollection.forSection(section.id) : nil
            if let collection, runs.last?.collection == collection {
                runs[runs.count - 1].sections.append(section)
            } else {
                runs.append(HistoryRun(collection: collection, sections: [section]))
            }
        }
    }

    var dashboardContent: some View {
        LazyVStack(spacing: HisingenTheme.sectionSpacing) {
            ForEach(historyRuns) { run in
                historyRun(run)
                    .id(run.id)
            }
        }
        .hisAnimation(Motion.cardChange, value: periodDataKey)
        .hisAnimation(Motion.layout, value: sessionCurveKey)
    }

    @ViewBuilder
    private func historyRun(_ run: HistoryRun) -> some View {
        if let collection = run.collection, collection != .sessions,
           run.sections.count > 1 || collection == .activity {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader(symbol: "", title: collection.title, color: HisingenTheme.ink)
                    if collection == .activity, run.sections.count > 1 {
                        activityFilterPicker(for: run.sections)
                    }
                    let sections = collection == .activity && run.sections.contains(where: { activityFilter.shows($0.id) })
                        ? run.sections.filter { activityFilter.shows($0.id) }
                        : run.sections
                    ForEach(sections) { section in
                        if section.id != sections.first?.id { PanelRule() }
                        historySectionContent(section.id).id(section.id)
                    }
                }
                .environment(\.historyCardEmbedded, true)
            }
        } else {
            ForEach(run.sections) { section in
                historySectionContent(section.id).id(section.id)
            }
        }
    }

    private func activityFilterPicker(for sections: [HistorySection]) -> some View {
        let options = ActivityFilter.allCases.filter { filter in sections.contains { filter.shows($0.id) } }
        return UnderlineSegments(
            options: options.map { ($0, $0.title) },
            selection: Binding(
                get: { options.contains(activityFilter) ? activityFilter : .all },
                set: { activityFilter = $0 }
            ),
            accessibilityLabel: L10n.text("Activity type")
        )
    }

    @ViewBuilder
    private func historySectionContent(_ id: String) -> some View {
        switch id {
        case "overview":
            if HisingenTheme.layoutWidth >= 580 && !state.powertrain.hasCombustionEngine {
                awardHistoryOverview
            } else {
                overviewCard
            }
        case "activity": observedChangesCard
        case "month": monthComparisonCard
        case "air-cleaning": airCleaningCyclesCard
        case "emissions": emissionsCard
        case "driving-patterns": drivingPatternsCard
        case "distance": distanceChartCard
        case "monthly-mileage": monthlyMileageReportCard
        case "trips": tripListCard
        case "charging-sessions": chargingSessionsCard
        case "charging-curve":
            sessionDetail.transition(.opacity)
        case "monthly-charging": monthlyChargingCard
        case "charge-locations": locationBreakdownCard
        case "charging-history": chargingHistoryCard
        case "fuel-economy": fuelEconomyCard
        case "recent-fills": recentFillsCard
        case "efficiency": efficiencyChartCard
        case "consumption": combustionConsumptionCard
        case "odometer": odometerChartCard
        case "battery-health": batteryHealthCard
        case "tyre-pressure": tyrePressureCard
        case "warnings": warningTimelineCard
        case "air-quality": airQualityCard
        case "cabin-climate": cabinClimateCard
        case "automations": automationHistoryCard
        case "store-unreadable": storeUnreadableCard.transition(.opacity)
        case "empty": emptyCard.transition(.opacity)
        case "nothing-in-range": nothingInRangeCard.transition(.opacity)
        default: EmptyView()
        }
    }

    /// Jumps the shared scroller to a card. Info has had this for its 22 sections all along; the
    /// stack here is just as long and had nothing.
    func historyJumpMenu() -> some View {
        Menu {
            ForEach(visibleHistorySections) { section in
                Button(section.title) { requestHistoryJump(section.id) }
            }
        } label: {
            Image(systemName: "list.bullet")
                .hisType(.label, weight: .medium)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .help(L10n.text("Jump to section"))
        .accessibilityLabel(L10n.text("Jump to section"))
    }

    var showsHistoryExportHeader: Bool {
        draws(.historyPeriodPicker) || initialSection == "export"
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: HisingenTheme.sectionSpacing) {
                if draws(.historyPeriodPicker) {
                    periodPicker.id("history-export")
                } else if showsHistoryExportHeader {
                    HStack {
                        Spacer()
                        exportMenu
                    }
                    .padding(.horizontal, HisingenTheme.cardPadding)
                    .id("history-export")
                }

                if isLoading && !didInitialLoad {
                    loadingSkeleton
                        .transition(.opacity)
                } else {
                    dashboardContent
                        .transition(.opacity)
                }
            }
            .hisAnimation(Motion.entrance, value: didInitialLoad)
            .task(id: didInitialLoad) {
                guard didInitialLoad else { return }
                if let initialChargingSessionID, let session = chargingSessions.first(where: {
                    $0.id.caseInsensitiveCompare(initialChargingSessionID) == .orderedSame
                }) {
                    selectedSessionID = session.id
                    if draws(.historyChargingCurve) {
                        requestHistoryJump("charging-curve")
                        return
                    }
                }
                if let initialSection { openInitialSection(initialSection) }
            }
            .task(id: requestedSection) {
                guard let requestedSection else { return }
                await scrollHistory(to: requestedSection, with: proxy)
                if !Task.isCancelled, self.requestedSection == requestedSection { self.requestedSection = nil }
            }
        }

        .sheet(isPresented: $showFuelSheet) { fuelEntrySheet }
        .sheet(isPresented: $showChargingSessionSheet) { chargingSessionEntrySheet }
        .alert(L10n.text("Export failed"), isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button(L10n.text("OK"), role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .overlay(alignment: .bottom) { exportNoticeView }
        .hisAnimation(Motion.stateChange, value: exportNotice)
        .confirmationDialog(
            L10n.text("Delete this fill-up?"),
            isPresented: Binding(get: { fuelEntryPendingDeletion != nil },
                                 set: { if !$0 { fuelEntryPendingDeletion = nil } }),
            presenting: fuelEntryPendingDeletion
        ) { entry in
            Button(L10n.text("Delete"), role: .destructive) {
                history.deleteFuelEntry(id: entry.id)
                fuelEntryPendingDeletion = nil
                bumpRefresh()
            }
            Button(L10n.text("Cancel"), role: .cancel) { fuelEntryPendingDeletion = nil }
        } message: { entry in
            Text(L10n.format("%@ · %@",
                             Format.dateFormatter.string(from: entry.date),
                             Format.fuelVolume(liters: entry.liters, unit: preferences.fuelVolumeUnit)))
        }
        .task(id: periodLoadKey) { await loadDashboardData() }
        .task(id: tripPresentationKey) { await loadTripPresentation() }
        .task(id: sessionPresentationKey) { await loadSessionPresentation() }
        .task(id: sessionCurveLoadKey) { await loadSessionCurves() }
        .task(id: selectedSession?.id) { await loadSessionPrices() }
        .onChange(of: locale.identifier) { _, _ in refreshSearchLabels() }
        .onChange(of: state.dataTimestamp) { _, _ in bumpDataToken() }
        .onChange(of: selectedSessionID) { _, newValue in
            preferences.setSelectedHistorySession(newValue, for: state.identity.vin)
        }
        .onAppear {
            if selectedSessionID == nil && initialChargingSessionID == nil {
                selectedSessionID = preferences.selectedHistorySession(for: state.identity.vin)
            }
        }
    }

    private func openInitialSection(_ id: String) {
        if id == "export" {
            requestHistoryJump(id)
            return
        }
        let sections = visibleHistorySections
        let activityDestination = id == "activity" ? sections.first(where: { HistoryCollection.forSection($0.id) == .activity }) : nil
        if let destination = sections.first(where: { $0.id == id }) ?? activityDestination ?? sections.first {
            requestHistoryJump(destination.id)
        }
    }

    func requestHistoryJump(_ id: String) {
        if HistoryCollection.forSection(id) == .activity { activityFilter = .all }
        requestedSection = id
    }

    private func scrollHistory(to id: String, with proxy: ScrollViewProxy) async {
        if id == "export" {
            proxy.scrollTo("history-export", anchor: .top)
            return
        }
        guard let run = historyRuns.first(where: { $0.sections.contains { $0.id == id } })
                ?? (id == "charging-curve" && embedsChargingCurve
                    ? historyRuns.first(where: { $0.sections.first?.id == "charging-sessions" })
                    : nil) else { return }
        if run.sections.count > 1 || id == "charging-curve" {
            proxy.scrollTo(run.id, anchor: .top)
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(Motion.resolve(Motion.layout)) {
                proxy.scrollTo(id, anchor: .top)
            }
        } else {
            withAnimation(Motion.resolve(Motion.layout)) {
                proxy.scrollTo(run.id, anchor: .top)
            }
        }
    }

    @ViewBuilder
    private var exportNoticeView: some View {
        if let exportNotice {
            Label(exportNotice, systemImage: "checkmark.circle.fill")
                .hisType(.caption, weight: .semibold)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(HisingenTheme.chipFill, in: RoundedRectangle(cornerRadius: 0))
                .transition(.opacity)
                .padding(.bottom, 12)
                .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Loading

    /// Deliberately built from the *inputs* that define the window, not from `activeRange` –
    /// a day-based period's bounds derive from `Date()`, and folding that into the key would
    /// make `.task(id:)` re-fire on every render. "Now" only needs to move the window when the
    /// user refreshes or new telemetry arrives, both of which bump `refreshToken`.
    var periodLoadKey: String {
        let custom = period == .custom
            ? "\(customRangeStart.timeIntervalSince1970)_\(customRangeEnd.timeIntervalSince1970)"
            : ""
        return "\(state.identity.vin)_\(period.rawValue)_\(custom)_\(refreshToken)_\(dataToken)"
    }

    var lifetimeLoadKey: String { "\(state.identity.vin)_\(refreshToken)" }

    // MARK: - Data identities for chart animation

    /// Identity of the period-scoped snapshot: counts plus the newest row timestamps change
    /// exactly when a reload delivers different data, so charts animate when the data lands
    /// rather than on the load key (which flips before the async query returns).
    var periodDataKey: String {
        let air = snapshot.airQualityRecords
        return "t\(snapshot.trips.count).\(snapshot.trips.first?.endedAt.timeIntervalSince1970 ?? 0)" +
            "_s\(snapshot.chargingSessions.count).\(snapshot.chargingSessions.first?.startedAt.timeIntervalSince1970 ?? 0)" +
            "_r\(snapshot.telemetryRecords.count).\(snapshot.telemetryRecords.first?.timestamp.timeIntervalSince1970 ?? 0)" +
            "_a\(air.count).\(air.last?.timestamp.timeIntervalSince1970 ?? 0)" +
            "_y\(tyreRecords.count).\(tyreRecords.first?.timestamp.timeIntervalSince1970 ?? 0)" +
            "_w\(warningEvents.count).\(warningEvents.first?.clearedAt?.timeIntervalSince1970 ?? 0)"
    }

    /// Identity of the lifetime series (battery health, all-time odometer, fuel, cabin
    /// climate) that only reload on `lifetimeLoadKey`.
    var lifetimeDataKey: String {
        "b\(batteryHealthRecords.count).\(batteryHealthRecords.first?.timestamp.timeIntervalSince1970 ?? 0)" +
            "_o\(allTimeTelemetryRecords.count).\(allTimeTelemetryRecords.first?.timestamp.timeIntervalSince1970 ?? 0)" +
            "_f\(fuelEntries.count).\(fuelEntries.first?.date.timeIntervalSince1970 ?? 0)" +
            "_c\(cabinClimateRecords.count).\(cabinClimateRecords.last?.timestamp.timeIntervalSince1970 ?? 0)"
    }

    /// Identity of the selected session's loaded samples – covers both the session switch
    /// and the async sample load landing.
    var sessionCurveKey: String {
        "\(selectedSessionID ?? "")_\(selectedSessionSamples.count)" +
            "_\(selectedSessionSamples.first?.timestamp.timeIntervalSince1970 ?? 0)"
    }

    var tripPresentationKey: String {
        let hidden = preferences.hiddenTripIDs(for: state.identity.vin).subtracting(restoredTripIDs)
        return "\(periodDataKey)_\(locale.identifier)_\(tripSort.rawValue)_\(tripFilterText)_\(hidden.sorted().joined(separator: ","))"
    }

    var sessionPresentationKey: String {
        "\(periodDataKey)_\(locale.identifier)_\(sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines))_\(String(describing: sessionFilter))"
    }

    var sessionCurveLoadKey: String {
        "\(selectedSession?.id ?? "")_\(overlayPreviousSession)_\(periodDataKey)"
    }

    /// Full reload (manual refresh, fuel edits).
    func bumpRefresh() { refreshToken &+= 1 }

    /// Period-scoped reload only (fresh telemetry arrived).
    func bumpDataToken() { dataToken &+= 1 }

    /// Row cap for the period-scoped queries. "All" is generous but still bounded so a
    /// long-lived database can't stall the tab; the other periods rarely approach it. Trips
    /// are additionally capped inside `loadDashboardData`; trip derivation itself enforces a
    /// fixed telemetry-row ceiling.
    var rowCap: Int { period == .all ? 10_000 : 3_000 }

    var tripCap: Int { min(rowCap, 3_000) }

    func loadDashboardData() async {
        isLoading = true

        let lifetimeKey = lifetimeLoadKey
        let query = HistoryWorkspace.DashboardQuery(
            vin: state.identity.vin, range: activeRange,
            rowCap: rowCap, tripCap: tripCap,
            capacityKwh: history.usableCapacityKwh(vin: state.identity.vin, state: state),
            hasElectricRange: state.powertrain.hasElectricRange,
            hasCombustionEngine: state.powertrain.hasCombustionEngine)

        let loaded = await history.dashboard(matching: query,
                                             loadLifetime: loadedLifetimeKey != lifetimeKey,
                                             keeping: lifetime)

        // A load cancelled by a newer key must not clear the loading flag the replacement
        // already set, so the flags reset only on the success path.
        guard !Task.isCancelled else { return }
        if !didInitialLoad, let initialChargingSessionID, period != .all,
           !loaded.dashboard.storeUnreadable,
           !loaded.dashboard.chargingSessions.contains(where: {
               $0.id.caseInsensitiveCompare(initialChargingSessionID) == .orderedSame
           }) {
            period = .all
            return
        }
        isLoading = false
        didInitialLoad = true
        snapshot = loaded.dashboard
        lifetime = loaded.lifetime
        presentation = loaded.presentation
        if loadedLifetimeKey != lifetimeKey { loadedLifetimeKey = lifetimeKey }
        expandedTripIDs = []
        refreshSearchLabels()
        let hidden = preferences.hiddenTripIDs(for: query.vin).subtracting(restoredTripIDs)
        hiddenTripRows = loaded.dashboard.reportTrips.filter { hidden.contains($0.id) }
        sessionNotes = loaded.dashboard.sessionNotes
        // `selectedSession` resolves to nil on its own when the remembered id isn't in the
        // current range, so the curve card just hides; the saved preference is kept so the
        // curve reappears if the range later includes that session again.
    }

    private func refreshSearchLabels() {
        let formatter = Format.dateTimeFormatter
        tripDateStrings = Dictionary(snapshot.reportTrips.map { ($0.id, formatter.string(from: $0.endedAt)) },
                                     uniquingKeysWith: { first, _ in first })
        sessionLabelStrings = Dictionary(chargingSessions.map { ($0.id, sessionLabel($0)) },
                                         uniquingKeysWith: { first, _ in first })
    }

    func loadSessionCurves() async {
        let selection = selectedSession
        if selection?.id != loadedSessionCurveID {
            selectedSessionSamples = []
            selectedSessionChargerPower = []
            selectedSessionCurvePoints = []
            previousSessionCurve = []
            loadedSessionCurveID = nil
        }
        guard let session = selection else { return }
        let previous = overlayPreviousSession
            ? chargingSessions.drop(while: { $0.id != session.id }).dropFirst().first
            : nil
        let curves = await history.sessionCurves(for: session, overlaying: previous)
        guard !Task.isCancelled else { return }
        selectedSessionSamples = curves.samples
        selectedSessionChargerPower = curves.chargerPower
        selectedSessionCurvePoints = curves.current
        previousSessionCurve = curves.previous
        loadedSessionCurveID = session.id
    }

    /// Tibber's slots with the grid fee when Tibber is connected and still holds them (about a
    /// month back), otherwise the market price for the reader's zone from the local price cache.
    func loadSessionPrices() async {
        guard let session = selectedSession else {
            selectedSessionPrices = nil
            loadedSessionPricesID = nil
            return
        }
        if loadedSessionPricesID != session.id { selectedSessionPrices = nil }
        let start = session.wallbox?.startedAt ?? session.startedAt
        let end = session.wallbox?.endedAt ?? session.endedAt ?? Date()
        var series = await homeCharging?.sessionPriceSeries(from: start, to: end)
        if series == nil {
            let zone = preferences.electricityPriceZone
            let calendar = ElectricityPriceService.stockholmCalendar
            var points: [ElectricityPricePoint] = []
            var day = calendar.startOfDay(for: start)
            // A session spans a day or two, so this asks for at most a couple of day files.
            while day <= end {
                points = await ElectricityPriceService.shared.historicalPrices(zone: zone, day: day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            series = SessionPriceSeries.spot(points, policy: preferences.electricityRatePolicy, from: start, to: end)
        }
        guard !Task.isCancelled, selectedSession?.id == session.id else { return }
        selectedSessionPrices = series
        loadedSessionPricesID = session.id
    }

    func loadTripPresentation() async {
        if !tripFilterText.isEmpty {
            do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
        }
        let source = snapshot.trips
        let hidden = preferences.hiddenTripIDs(for: state.identity.vin).subtracting(restoredTripIDs)
        let search = tripFilterText
        let sort = tripSort
        let dates = tripDateStrings
        let loaded = await Task.detached(priority: .userInitiated) {
            HistoryTripPresentation.build(
                from: source, hidden: hidden, searchText: search,
                sort: sort, dateStrings: dates
            )
        }.value
        guard !Task.isCancelled else { return }
        tripPresentation = loaded
        hiddenTripRows = snapshot.reportTrips.filter { hidden.contains($0.id) }
    }

    func loadSessionPresentation() async {
        let search = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
        }
        let sessions = chargingSessions
        let labels = sessionLabelStrings
        let filter = sessionFilter
        let unknownLocation = L10n.text("Unknown location")
        let loaded = await Task.detached(priority: .userInitiated) {
            let matches = sessions.filter { session in
                (filter?.contains(session, unknownLocation: unknownLocation) ?? true)
                    && (search.isEmpty || (labels[session.id] ?? "").localizedCaseInsensitiveContains(search))
            }
            return filter == .peakPower ? matches.sorted { $0.peakPowerKw > $1.peakPowerKw } : matches
        }.value
        guard !Task.isCancelled else { return }
        filteredSessionRows = loaded
    }

    var loadingSkeleton: some View {
        VStack(spacing: HisingenTheme.sectionSpacing) {
            // The first skeleton card carries the label; the two below it are shapes. Three cards
            // each announcing "Loading history…" told a VoiceOver reader the same thing three times
            // and read as three separate loads.
            ForEach(0..<3, id: \.self) { index in
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        if index == 0 {
                            CardHeader(symbol: "chart.xyaxis.line", title: L10n.text("Loading history…"), color: HisingenTheme.chartInfo)
                        } else {
                            CardHeader(symbol: "chart.xyaxis.line", title: " ", color: HisingenTheme.chartInfo)
                                .accessibilityHidden(true)
                        }
                        RoundedRectangle(cornerRadius: 0).frame(height: chartHeight)
                        HStack { ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 0).frame(height: 34) } }
                    }
                }
                .redacted(reason: .placeholder)
            }
        }
        .accessibilityLabel(L10n.text("Loading history"))
    }

    func footnote(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: symbol).hisType(.nano)
            .hisCaptionLeading()
            Text(text).hisType(.micro).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }

    func sessionLabel(_ session: HistoricalChargingSession) -> String {
        var label = Format.dateTimeFormatter.string(from: session.startedAt)
        if let name = session.locationName, !name.isEmpty { label += " · " + name }
        if session.energyDeliveredKwh > 0 { label += " · " + Format.energyKwh(session.energyDeliveredKwh) }
        if session.endedAt == nil { label += " · " + L10n.text("Active") }
        return label
    }

    func curveStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // 27 call sites share this readout, and it was the one numeric display in the app
            // without a content transition: a value that changes in place snapped while every
            // sibling rolled. The tabular figures were already here.
            Text(value).hisType(.body, weight: .bold, design: .rounded).lineLimit(1)
            .minimumScaleFactor(0.8)
            .monospacedDigit()
            .hisTelemetryValue(value, reduceMotion: reduceMotion)
            Text(title).hisType(.caption).foregroundStyle(.secondary).lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }

    // MARK: - Charging summary

    /// The total, plus how many sessions had neither a saved cost nor a saved tariff.
    ///
    /// That count is the difference between what the tooltip claimed and what the arithmetic
    /// did: it said saved tariffs were used instead of recalculating with today's settings, while
    /// silently falling back to the current price for every session without one.
    func aggregateChargingCost() -> (amount: Double, currency: String, fallbackSessions: Int)? {
        guard let split = chargingCostSplit() else { return nil }
        return (split.totalAmount, split.currency, split.fallbackSessions)
    }

    /// The same calculation, kept as buckets so the trends card can show home and public
    /// charging as separate lines that add up to the total.
    func chargingCostSplit() -> ChargingCostSplit? {
        ChargingCostSplit.resolve(
            sessions: chargingSessions,
            policy: preferences.electricityRatePolicy,
            fallbackPricePerKwh: preferences.electricityPricePerKwh,
            defaultCurrency: preferences.currencySymbol
        )
    }

    /// The per-kWh price behind lifetime cost-per-distance. A fixed rate is used as typed; in
    /// automatic mode the rate is what the stored sessions actually cost on average, so the
    /// figure follows the market-priced totals instead of a stale typed-in number.
    func effectiveLifetimePricePerKwh() -> Double {
        let fixed = preferences.electricityPricePerKwh
        guard preferences.electricityRatePolicy.isAutomatic, let cost = aggregateChargingCost() else { return fixed }
        let energy = chargingSessions.reduce(0.0) { $0 + $1.energyDeliveredKwh }
        return energy > 0 ? cost.amount / energy : fixed
    }

    func dataConfidenceNote(for timestamps: [Date]) -> some View {
        let coverage = HistoryInsights.dataCoverage(timestamps: timestamps)
        return Group {
            if coverage.confidence == .low || coverage.confidence == .insufficient {
                Text(L10n.format("Limited data (%@ points): treat this trend as indicative, not conclusive.", "\(coverage.sampleCount)"))
                    .hisType(.caption)
                    .foregroundStyle(HisingenTheme.semanticWarning)
            }
        }
    }

    func gapSegmentIndex<T: Identifiable>(of points: [T], maxGap: TimeInterval = HistoryInsights.defaultChartGapThreshold,
                                                  timestamp: (T) -> Date) -> [T.ID: Int] {
        let runs = HistoryInsights.segments(of: points, maxGap: maxGap, timestamp: timestamp)
        var result: [T.ID: Int] = [:]
        for (index, run) in runs.enumerated() {
            for point in run { result[point.id] = index }
        }
        return result
    }

    // MARK: - Search field

    func searchField(_ prompt: String, text: Binding<String>, count: Int, total: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").hisType(.micro).foregroundStyle(.tertiary)
            TextField(prompt, text: text)
                .textFieldStyle(.plain).hisType(.micro)
            if !text.wrappedValue.isEmpty {
                Text("\(count)/\(total)").hisType(.nano).foregroundStyle(.secondary)
                Button { text.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill").hisType(.micro) }
                    .buttonStyle(.pressable).accessibilityLabel(L10n.text("Clear search"))
            }
        }
        .padding(5)
        .background(Color.primary.opacity(HisingenTheme.tintedWashOpacity(0.03, increasedContrast: contrast == .increased)), in: RoundedRectangle(cornerRadius: 0))
    }

    struct LabeledField: View {
        let title: String
        @Binding var text: String
        var reason: String? = nil
        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).hisType(.caption).foregroundStyle(.secondary)
                TextField("", text: $text)
                    .hisField()
                    .hisType(.body)
                if let reason {
                    Text(reason)
                        .hisType(.micro, weight: .semibold)
                        .foregroundStyle(HisingenTheme.semanticCritical)
                }
            }
        }
    }
}
