import SwiftUI

@MainActor
struct HistoryDashboardView: View {
    let state: VehicleState

    let database: VehicleDatabase

    /// A deep link from Info can target the observed activity after the initial database load.
    let initialSection: String?

    @Environment(\.preferencesStore) var preferences

    @Environment(\.accessibilityReduceMotion) var reduceMotion

    /// The system setting for readers who cannot separate the chart series by hue. The two series
    /// that share axes carry a dash pattern on the second one when this is on.
    @Environment(\.accessibilityDifferentiateWithoutColor) var differentiateWithoutColor

    @State var period: HistoryPeriod = .month

    @State var selectedSessionID: String?

    @State var sessionSearchText: String = ""

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

    @State var exportScope: ExportScope = .fullHistory

    @State var overlayPreviousSession = false

    /// Drives the selected-session curve card's live dot (same treatment as the live
    /// curve in ChargingCurveView).
    @State var curveLivePulse = false

    // Chart scrub cursors (one per interactive time-series chart).
    @State var scrubDistance: Date?

    @State var scrubEfficiency: Date?

    @State var scrubOdometer: Date?

    @State var scrubSoH: Date?

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

    enum ExportScope: String, CaseIterable, Identifiable {
        case fullHistory = "Full history"
        case selectedPeriod = "Selected period"
        var id: String { rawValue }
    }

    @State var fuelLitersText: String = ""

    @State var fuelPriceText: String = ""

    @State var fuelOdometerText: String = ""

    @State var showFuelSheet = false

    @State var fuelEntryPendingDeletion: VehicleDatabase.FuelEntry?

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

    /// Per-entry search strings, rebuilt once per snapshot so the trip/session filters never
    /// re-format a date per row on every keystroke or scrub.
    @State var tripDateStrings: [String: String] = [:]

    @State var sessionLabelStrings: [String: String] = [:]

    @State var selectedSessionSamples: [HistoricalChargingSample] = []

    @State var presentation = HistoryPresentationSnapshot()

    @State var tripPresentation = HistoryTripPresentation()

    @State var filteredSessionRows: [HistoricalChargingSession] = []

    @State var selectedSessionCurvePoints: [HistoryInsights.ChargingCurvePoint] = []

    @State var loadedLifetimeKey: String?

    @State var previousSessionCurve: [HistoryInsights.ChargingCurvePoint] = []

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

    var fuelEntries: [VehicleDatabase.FuelEntry] { lifetime.fuelEntries }

    var cabinClimateRecords: [VehicleDatabase.CabinClimateRecord] { lifetime.cabinClimateRecords }

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
        return chargingSessions.first { $0.id == selectedSessionID }
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
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "clock.arrow.circlepath", title: L10n.text("Observed Changes"), color: .indigo)
                PaginatedSection(items: snapshot.activities, pageSize: 15, resetKeys: [periodLoadKey],
                                 emptyMessage: L10n.text("No activity was recorded in this period.")) { visible, footer in
                    VehicleActivityList(events: Array(visible))
                    footer
                }
            }
        }
    }

    /// The post-skeleton card stack. The stack keys on `periodDataKey` so a refresh or
    /// period change animates the cards when the loaded snapshot lands, not when the load
    /// One card in the History stack, with the name the jump menu calls it by.
    ///
    /// The stack grew to as many as 23 cards in one scroll with no indicator, no position cue and
    /// no way to reach a card except by scrolling past every one before it, while Info solved the
    /// identical problem with its own jump menu. The list is the single source for both the cards
    /// and the menu, so a card cannot be reachable from one and invisible to the other.
    struct HistorySection: Identifiable {
        let id: String
        let title: String
        let isVisible: Bool
        let content: AnyView
    }

    var historySections: [HistorySection] {
        [
            HistorySection(id: "overview", title: L10n.text("Overview"), isVisible: true,
                           content: AnyView(overviewCard)),
            HistorySection(id: "activity", title: L10n.text("Activity"), isVisible: !snapshot.activities.isEmpty,
                           content: AnyView(observedChangesCard)),
            HistorySection(id: "month", title: L10n.text("Month Comparison"), isVisible: true,
                           content: AnyView(monthComparisonCard)),
            HistorySection(id: "air-cleaning", title: L10n.text("Air Cleaning"),
                           isVisible: snapshot.activities.contains(where: { $0.kind == .airCleaning }),
                           content: AnyView(airCleaningCyclesCard)),
            HistorySection(id: "emissions", title: L10n.text("Emissions"), isVisible: true,
                           content: AnyView(emissionsCard)),
            HistorySection(id: "driving-patterns", title: L10n.text("Driving Patterns"), isVisible: !trips.isEmpty,
                           content: AnyView(drivingPatternsCard)),
            HistorySection(id: "distance", title: L10n.text("Distance"), isVisible: !trips.isEmpty,
                           content: AnyView(distanceChartCard)),
            HistorySection(id: "monthly-mileage", title: L10n.text("Monthly Mileage"), isVisible: !trips.isEmpty,
                           content: AnyView(monthlyMileageReportCard)),
            HistorySection(id: "trips", title: L10n.text("Trips"), isVisible: !trips.isEmpty,
                           content: AnyView(tripListCard)),
            HistorySection(id: "charging-sessions", title: L10n.text("Charging Sessions"),
                           isVisible: !chargingSessions.isEmpty,
                           content: AnyView(chargingSessionsCard)),
            HistorySection(id: "charging-curve", title: L10n.text("Charging Curve"),
                           isVisible: !chargingSessions.isEmpty && selectedSession != nil && !selectedSessionCurve.isEmpty,
                           content: AnyView(chargingCurveCard.transition(.opacity.combined(with: .move(edge: .top))))),
            HistorySection(id: "monthly-charging", title: L10n.text("Charging by Month"),
                           isVisible: !chargingSessions.isEmpty,
                           content: AnyView(monthlyChargingCard)),
            HistorySection(id: "charge-locations", title: L10n.text("Charge Locations"),
                           isVisible: !chargingSessions.isEmpty,
                           content: AnyView(locationBreakdownCard)),
            HistorySection(id: "charging-history", title: L10n.text("Charging History"),
                           isVisible: !chargingSessions.isEmpty,
                           content: AnyView(chargingHistoryCard)),
            HistorySection(id: "fuel-economy", title: L10n.text("Fuel Economy"), isVisible: !fuelEntries.isEmpty,
                           content: AnyView(fuelEconomyCard)),
            HistorySection(id: "recent-fills", title: L10n.text("Recent Fill-ups"), isVisible: !fuelEntries.isEmpty,
                           content: AnyView(recentFillsCard)),
            HistorySection(id: "efficiency", title: L10n.text("Efficiency"),
                           isVisible: efficiencyPoints.count >= 3,
                           content: AnyView(efficiencyChartCard)),
            HistorySection(id: "consumption", title: L10n.text("Consumption"),
                           isVisible: combustionConsumptionPoints.count >= 3,
                           content: AnyView(combustionConsumptionCard)),
            HistorySection(id: "odometer", title: L10n.text("Odometer"),
                           isVisible: odometerPoints.count >= 3,
                           content: AnyView(odometerChartCard)),
            HistorySection(id: "battery-health", title: L10n.text("Battery Health"),
                           isVisible: !batteryHealthRecords.isEmpty,
                           content: AnyView(batteryHealthCard)),
            HistorySection(id: "air-quality", title: L10n.text("Air Quality"),
                           isVisible: airQualityRecords.count >= 2,
                           content: AnyView(airQualityCard)),
            HistorySection(id: "cabin-climate", title: L10n.text("Cabin Climate"),
                           isVisible: cabinClimateRecords.count >= 2,
                           content: AnyView(cabinClimateCard)),
            HistorySection(id: "automations", title: L10n.text("Automations"), isVisible: !commands.isEmpty,
                           content: AnyView(automationHistoryCard)),
            // The terminal states, first because every other state is a claim about the data and
            // this one says the data could not be reached at all.
            HistorySection(id: "store-unreadable", title: L10n.text("History could not be read"),
                           isVisible: storeUnreadable,
                           content: AnyView(storeUnreadableCard.transition(.opacity))),
            HistorySection(id: "empty", title: L10n.text("No history yet"),
                           isVisible: !storeUnreadable && hasAnyDataAtAll == false,
                           content: AnyView(emptyCard.transition(.opacity))),
            HistorySection(id: "nothing-in-range", title: L10n.text("Nothing in this period"),
                           isVisible: !storeUnreadable && hasAnyDataAtAll && !hasAnyDataInRange,
                           content: AnyView(nothingInRangeCard.transition(.opacity)))
        ]
    }

    var visibleHistorySections: [HistorySection] {
        historySections.filter(\.isVisible)
    }

    /// key flips (that precedes the async query).
    var dashboardContent: some View {
        VStack(spacing: HisingenTheme.sectionSpacing) {
            ForEach(visibleHistorySections) { section in
                section.content.id(section.id)
            }
        }
        .hisAnimation(Motion.cardChange, value: periodDataKey)
        .hisAnimation(Motion.layout, value: sessionCurveKey)
    }

    /// Jumps the shared scroller to a card. Info has had this for its 22 sections all along; the
    /// stack here is just as long and had nothing.
    func historyJumpMenu(proxy: ScrollViewProxy) -> some View {
        Menu {
            ForEach(visibleHistorySections) { section in
                Button(section.title) {
                    withAnimation(Motion.resolve(Motion.layout)) {
                        proxy.scrollTo(section.id, anchor: .top)
                    }
                }
            }
        } label: {
            Image(systemName: "list.bullet")
                .hisType(.label, weight: .medium)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .help(L10n.text("Jump to a section"))
        .accessibilityLabel(L10n.text("Jump to a section"))
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: HisingenTheme.sectionSpacing) {
                periodPicker(proxy: proxy)

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
                guard didInitialLoad, let initialSection else { return }
                await Task.yield()
                let destination = historySections.first {
                    $0.id == initialSection && $0.isVisible
                }?.id ?? "overview"
                proxy.scrollTo(destination, anchor: .top)
            }
        }

        .sheet(isPresented: $showFuelSheet) { fuelEntrySheet }
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
                database.deleteFuelEntry(id: entry.id)
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
        .onChange(of: state.dataTimestamp) { _, _ in bumpDataToken() }
        .onChange(of: selectedSessionID) { _, newValue in
            preferences.setSelectedHistorySession(newValue, for: state.identity.vin)
        }
        .onAppear {
            if selectedSessionID == nil {
                selectedSessionID = preferences.selectedHistorySession(for: state.identity.vin)
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
                .background(HisingenTheme.chipFill, in: Capsule())
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
            "_a\(air.count).\(air.last?.timestamp.timeIntervalSince1970 ?? 0)"
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

    /// Folds the hidden ids (minus session restores) into the task key so hiding/restoring a
    /// trip reloads the hidden-trip cache, while typing or scrubbing never does.
    var hiddenTripsLoadKey: String {
        let hidden = preferences.hiddenTripIDs(for: state.identity.vin).subtracting(restoredTripIDs)
        return "\(state.identity.vin)_\(refreshToken)_\(hidden.sorted().joined(separator: ","))"
    }

    var tripPresentationKey: String {
        let hidden = preferences.hiddenTripIDs(for: state.identity.vin).subtracting(restoredTripIDs)
        return "\(periodDataKey)_\(tripSort.rawValue)_\(tripFilterText)_\(hidden.sorted().joined(separator: ","))"
    }

    var sessionPresentationKey: String {
        "\(periodDataKey)_\(sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines))"
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

        let vin = state.identity.vin
        let db = database
        let range = activeRange
        let cap = rowCap
        let tripLimit = tripCap
        let chargingCapacity = state.configuredCapacityReference(
            specification: preferences.vehicleSpecificationOverride(for: vin)).kwh
        let lifetimeKey = lifetimeLoadKey
        let shouldLoadLifetime = loadedLifetimeKey != lifetimeKey
        let existingLifetime = lifetime
        let hasElectricRange = state.powertrain.hasElectricRange
        let hasCombustion = state.powertrain.hasCombustionEngine

        let loaded = await Task.detached(priority: .userInitiated) {
            let dashboard = db.history.dashboard(
                vin: vin, range: range, rowCap: cap,
                tripLimit: tripLimit, chargingCapacity: chargingCapacity
            )
            guard !Task.isCancelled else { return Optional<HistoryDashboardLoadResult>.none }
            let lifetime = shouldLoadLifetime
                ? db.history.lifetime(vin: vin, hasCombustionEngine: hasCombustion)
                : existingLifetime
            guard !Task.isCancelled else { return Optional<HistoryDashboardLoadResult>.none }
            return HistoryDashboardLoadResult(
                dashboard: dashboard,
                lifetime: lifetime,
                presentation: HistoryPresentationSnapshot.build(
                    dashboard: dashboard, lifetime: lifetime,
                    hasElectricRange: hasElectricRange,
                    hasCombustionEngine: hasCombustion
                )
            )
        }.value

        // A load cancelled by a newer key must not clear the loading flag the replacement
        // already set, so the flags reset only on the success path.
        guard !Task.isCancelled, let loaded else { return }
        isLoading = false
        didInitialLoad = true
        snapshot = loaded.dashboard
        lifetime = loaded.lifetime
        presentation = loaded.presentation
        if shouldLoadLifetime { loadedLifetimeKey = lifetimeKey }
        expandedTripIDs = []
        tripDateStrings = Dictionary(
            loaded.dashboard.reportTrips.map { ($0.id, Format.dateTimeFormatter.string(from: $0.endedAt)) },
            uniquingKeysWith: { first, _ in first })
        sessionLabelStrings = Dictionary(
            loaded.dashboard.chargingSessions.map { ($0.id, sessionLabel($0)) },
            uniquingKeysWith: { first, _ in first })
        let hidden = preferences.hiddenTripIDs(for: vin).subtracting(restoredTripIDs)
        hiddenTripRows = loaded.dashboard.reportTrips.filter { hidden.contains($0.id) }
        // `selectedSession` resolves to nil on its own when the remembered id isn't in the
        // current range, so the curve card just hides; the saved preference is kept so the
        // curve reappears if the range later includes that session again.
    }

    func loadSessionCurves() async {
        guard let session = selectedSession else {
            selectedSessionSamples = []
            selectedSessionCurvePoints = []
            previousSessionCurve = []
            return
        }
        let db = database
        let previous = overlayPreviousSession
            ? chargingSessions.drop(while: { $0.id != session.id }).dropFirst().first
            : nil
        let curves = await Task.detached(priority: .userInitiated) {
            let samples = db.charging.reconciledSamples(for: session)
            let current = HistoryInsights.chargingCurve(from: samples)
            let previousCurve = previous.map {
                HistoryInsights.chargingCurve(from: db.charging.reconciledSamples(for: $0))
            } ?? []
            return (samples, current, previousCurve)
        }.value
        guard !Task.isCancelled else { return }
        selectedSessionSamples = curves.0
        selectedSessionCurvePoints = curves.1
        previousSessionCurve = curves.2
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
        let loaded = await Task.detached(priority: .userInitiated) {
            guard !search.isEmpty else { return sessions }
            return sessions.filter {
                (labels[$0.id] ?? "").localizedCaseInsensitiveContains(search)
            }
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
                            CardHeader(symbol: "chart.xyaxis.line", title: L10n.text("Loading history…"), color: .indigo)
                        } else {
                            CardHeader(symbol: "chart.xyaxis.line", title: " ", color: .indigo)
                                .accessibilityHidden(true)
                        }
                        RoundedRectangle(cornerRadius: 6).frame(height: chartHeight)
                        HStack { ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 6).frame(height: 34) } }
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
        .foregroundStyle(.tertiary)
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
            Text(value).hisType(.label, weight: .bold, design: .rounded).lineLimit(1)
            .minimumScaleFactor(0.9)
            .monospacedDigit()
            .hisTelemetryValue(value, reduceMotion: reduceMotion)
            Text(title).hisType(.nano).foregroundStyle(.secondary).lineLimit(1)
            .minimumScaleFactor(0.9)
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
        let currencies = Set(chargingSessions.map {
            let saved = $0.currencySymbol?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (saved?.isEmpty == false ? saved : nil) ?? preferences.currencySymbol
        })
        guard currencies.count <= 1 else { return nil }
        let currency = currencies.first ?? preferences.currencySymbol
        var fallbackSessions = 0
        let total = chargingSessions.reduce(0.0) { total, session in
            if let stored = session.estimatedCost { return total + stored }
            if session.tariffPricePerKwh == nil { fallbackSessions += 1 }
            let dayRate = session.tariffPricePerKwh ?? preferences.electricityPricePerKwh
            return total + session.energyDeliveredKwh * dayRate
        }
        return (total, currency, fallbackSessions)
    }

    func dataConfidenceNote(for timestamps: [Date]) -> some View {
        let coverage = HistoryInsights.dataCoverage(timestamps: timestamps)
        return Group {
            if coverage.confidence == .low || coverage.confidence == .insufficient {
                Text(L10n.format("Limited data (%@ points): treat this trend as indicative, not conclusive.", "\(coverage.sampleCount)"))
                    .hisType(.nano)
                    .foregroundStyle(HisingenTheme.semanticWarning.opacity(0.85))
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
                Text("\(count)/\(total)").hisType(.nano).foregroundStyle(.tertiary)
                Button { text.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill").hisType(.micro) }
                    .buttonStyle(.pressable).accessibilityLabel(L10n.text("Clear search"))
            }
        }
        .padding(5)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 5))
    }

    struct LabeledField: View {
        let title: String
        @Binding var text: String
        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).hisType(.caption).foregroundStyle(.secondary)
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .hisType(.body)
            }
        }
    }
}
