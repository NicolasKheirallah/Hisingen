import SwiftUI

enum HistoryPagination {
    static let tripsPerPage = 5

    static func pageCount(itemCount: Int, pageSize: Int = tripsPerPage) -> Int {
        guard itemCount > 0, pageSize > 0 else { return 0 }
        return (itemCount + pageSize - 1) / pageSize
    }

    static func page<Element>(of items: [Element], index: Int,
                              pageSize: Int = tripsPerPage) -> ArraySlice<Element> {
        guard !items.isEmpty, pageSize > 0 else { return [] }
        let safeIndex = min(max(0, index), max(0, pageCount(itemCount: items.count, pageSize: pageSize) - 1))
        let start = safeIndex * pageSize
        return items[start..<min(items.count, start + pageSize)]
    }
}

@MainActor
struct HistoryDashboardView: View {
    let state: VehicleState

    let database: VehicleDatabase

    @Environment(\.preferencesStore) var preferences

    @State var period: HistoryPeriod = .month

    @State var selectedSessionID: String?

    @State var sessionSearchText: String = ""

    @State var tripPage = 0

    @State var tripSearchText: String = ""

    @State var tripSort: TripSort = .newest

    @State var expandedTripIDs: Set<String> = []

    /// Bumped by the manual Refresh button and fuel edits — reloads everything.
    @State var refreshToken = 0

    /// Bumped when the vehicle reports fresh data — reloads only the period-scoped queries
    /// (new trips/sessions/telemetry rows); the lifetime series barely move minute to minute.
    @State var dataToken = 0

    @State var didInitialLoad = false

    // Starts true so the first paint shows the skeleton instead of a flash of empty cards;
    // the load task's `defer` always clears it.
    @State var isLoading = true

    @State var exportScope: ExportScope = .fullHistory

    @State var overlayPreviousSession = false

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

    enum TripSort: String, CaseIterable, Identifiable {
        case newest = "Newest"
        case distance = "Distance"
        case duration = "Duration"
        var id: String { rawValue }
    }

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

    @State var customRangeStart: Date = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()

    @State var customRangeEnd: Date = Date()

    @State var showCustomRangeEditor = false

    @State var fuelPage = 0

    struct MonthComparison: Sendable {
        let distanceKm: Double
        let energyKwh: Double
        let averageConsumption: Double?
    }

    struct HistoryDataSnapshot: Sendable {
        var trips: [TripHistoryEntry] = []
        var chargingSessions: [HistoricalChargingSession] = []
        var commands: [RemoteCommandAuditRecord] = []
        var airQualityRecords: [AirQualityRecord] = []
        var telemetryRecords: [HistoricalTelemetryRecord] = []
        var anomalousSessionIDs: Set<String> = []
        var thisMonth: MonthComparison = MonthComparison(distanceKm: 0, energyKwh: 0, averageConsumption: nil)
        var lastMonth: MonthComparison = MonthComparison(distanceKm: 0, energyKwh: 0, averageConsumption: nil)
        var thisYear: MonthComparison = MonthComparison(distanceKm: 0, energyKwh: 0, averageConsumption: nil)
        var lastYear: MonthComparison = MonthComparison(distanceKm: 0, energyKwh: 0, averageConsumption: nil)
        /// True when the database holds trips/sessions/commands/air-quality outside the
        /// selected range — lets the empty state say "nothing in this range" rather than
        /// "nothing recorded".
        var hasHistoryOutsideRange = false
        /// True when at least one query returned exactly its row cap, so a caption can warn
        /// that older rows are not shown.
        var truncated = false
    }

    /// Period-independent series (state of health, all-time odometer, fuel, cabin climate)
    /// loaded on their own cadence so changing the period selector doesn't re-run them.
    struct LifetimeSnapshot: Sendable {
        var batteryHealthRecords: [BatteryHealthRecord] = []
        var allTimeTelemetryRecords: [HistoricalTelemetryRecord] = []
        var fuelEntries: [VehicleDatabase.FuelEntry] = []
        var cabinClimateRecords: [VehicleDatabase.CabinClimateRecord] = []
        var lifetimeChargingEnergyKwh: Double = 0
        var lifetimeFuelCost: Double = 0
    }

    @State var snapshot = HistoryDataSnapshot()

    @State var lifetime = LifetimeSnapshot()

    @State var selectedSessionSamples: [HistoricalChargingSample] = []

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

    var trips: [TripHistoryEntry] {
        let hidden = preferences.hiddenTripIDs(for: state.vin)
        let base = hidden.isEmpty ? snapshot.trips : snapshot.trips.filter { !hidden.contains($0.id) }
        let searched = tripFilterText.isEmpty
            ? base
            : base.filter { Format.dateTimeFormatter.string(from: $0.endedAt).localizedCaseInsensitiveContains(tripFilterText) }
        switch tripSort {
        case .newest: return searched
        case .distance: return searched.sorted { $0.distanceKm > $1.distanceKm }
        case .duration: return searched.sorted { $0.duration > $1.duration }
        }
    }

    var tripFilterText: String { tripSearchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var tripPageCount: Int { HistoryPagination.pageCount(itemCount: trips.count) }

    var visibleTrips: ArraySlice<TripHistoryEntry> { HistoryPagination.page(of: trips, index: tripPage) }

    var chargingSessions: [HistoricalChargingSession] { snapshot.chargingSessions }

    var commands: [RemoteCommandAuditRecord] { snapshot.commands }

    var batteryHealthRecords: [BatteryHealthRecord] { lifetime.batteryHealthRecords }

    var airQualityRecords: [AirQualityRecord] { snapshot.airQualityRecords }

    var telemetryRecords: [HistoricalTelemetryRecord] { snapshot.telemetryRecords }

    var allTimeTelemetryRecords: [HistoricalTelemetryRecord] { lifetime.allTimeTelemetryRecords }

    var fuelEntries: [VehicleDatabase.FuelEntry] { lifetime.fuelEntries }

    var cabinClimateRecords: [VehicleDatabase.CabinClimateRecord] { lifetime.cabinClimateRecords }

    var efficiencyPoints: [HistoryInsights.EfficiencyPoint] {
        guard state.powertrain.hasElectricRange else { return [] }
        return HistoryInsights.efficiencyTrend(from: telemetryRecords)
    }

    var combustionConsumptionPoints: [HistoryInsights.EfficiencyPoint] {
        guard state.powertrain.hasCombustionEngine else { return [] }
        return HistoryInsights.combustionConsumptionTrend(from: telemetryRecords)
    }

    var odometerPoints: [HistoryInsights.OdometerPoint] {
        HistoryInsights.odometerTrend(from: telemetryRecords)
    }

    var allTimeOdometerPoints: [HistoryInsights.OdometerPoint] {
        HistoryInsights.odometerTrend(from: allTimeTelemetryRecords)
    }

    var selectedSession: HistoricalChargingSession? {
        guard let selectedSessionID else { return nil }
        return chargingSessions.first { $0.id == selectedSessionID }
    }

    var selectedSessionCurve: [HistoryInsights.ChargingCurvePoint] {
        HistoryInsights.chargingCurve(from: selectedSessionSamples)
    }

    var filteredSessionsForPicker: [HistoricalChargingSession] {
        let trimmed = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(chargingSessions.prefix(500)) }
        return chargingSessions.filter { sessionLabel($0).localizedCaseInsensitiveContains(trimmed) }
    }

    var commandStatistics: HistoryInsights.CommandStatistics {
        HistoryInsights.commandStatistics(from: commands)
    }

    var hasAnyDataInRange: Bool {
        !trips.isEmpty || !chargingSessions.isEmpty || !commands.isEmpty
            || airQualityRecords.count >= 2 || odometerPoints.count >= 3
            || efficiencyPoints.count >= 3 || combustionConsumptionPoints.count >= 3
    }

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

    var body: some View {
        VStack(spacing: HisingenTheme.sectionSpacing) {
            periodPicker

            if isLoading && !didInitialLoad {
                loadingSkeleton
            } else {
                overviewCard
                monthComparisonCard
                emissionsCard
                if !trips.isEmpty {
                    drivingPatternsCard
                    distanceChartCard
                    tripListCard
                }
                if !chargingSessions.isEmpty {
                    chargingSessionsCard
                    if selectedSession != nil && !selectedSessionCurve.isEmpty { chargingCurveCard }
                    monthlyChargingCard
                    locationBreakdownCard
                    chargingHistoryCard
                }
                if !fuelEntries.isEmpty {
                    fuelEconomyCard
                    recentFillsCard
                }
                if efficiencyPoints.count >= 3 { efficiencyChartCard }
                if combustionConsumptionPoints.count >= 3 { combustionConsumptionCard }
                if odometerPoints.count >= 3 { odometerChartCard }
                if !batteryHealthRecords.isEmpty { batteryHealthCard }
                if airQualityRecords.count >= 2 { airQualityCard }
                if cabinClimateRecords.count >= 2 { cabinClimateCard }
                if !commands.isEmpty { automationHistoryCard }
                if !hasAnyDataAtAll {
                    emptyCard
                } else if !hasAnyDataInRange {
                    nothingInRangeCard
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .sheet(isPresented: $showFuelSheet) { fuelEntrySheet }
        .alert(L10n.text("Export failed"), isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button(L10n.text("OK"), role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
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
        .task(id: periodLoadKey) { await loadPeriodScopedData() }
        .task(id: lifetimeLoadKey) { await loadLifetimeData() }
        .task(id: selectedSession?.id) { await loadSelectedSessionSamples() }
        .task(id: "\(selectedSession?.id ?? "")_\(overlayPreviousSession)") { await loadPreviousSessionCurve() }
        .onChange(of: state.dataTimestamp) { _, _ in bumpDataToken() }
        .onChange(of: selectedSessionID) { _, newValue in
            preferences.setSelectedHistorySession(newValue, for: state.vin)
        }
        .onAppear {
            if selectedSessionID == nil {
                selectedSessionID = preferences.selectedHistorySession(for: state.vin)
            }
        }
    }

    // MARK: - Loading

    /// Deliberately built from the *inputs* that define the window, not from `activeRange` —
    /// a day-based period's bounds derive from `Date()`, and folding that into the key would
    /// make `.task(id:)` re-fire on every render. "Now" only needs to move the window when the
    /// user refreshes or new telemetry arrives, both of which bump `refreshToken`.
    var periodLoadKey: String {
        let custom = period == .custom
            ? "\(customRangeStart.timeIntervalSince1970)_\(customRangeEnd.timeIntervalSince1970)"
            : ""
        return "\(state.vin)_\(period.rawValue)_\(custom)_\(refreshToken)_\(dataToken)"
    }

    var lifetimeLoadKey: String { "\(state.vin)_\(refreshToken)" }

    /// Full reload (manual refresh, fuel edits).
    func bumpRefresh() { refreshToken &+= 1 }

    /// Period-scoped reload only (fresh telemetry arrived).
    func bumpDataToken() { dataToken &+= 1 }

    /// Row cap for the period-scoped queries. "All" is generous but still bounded so a
    /// long-lived database can't stall the tab; the other periods rarely approach it. Trips
    /// are additionally capped inside `loadPeriodScopedData` because `derivedTrips` fans each
    /// unit out to ~20 telemetry rows.
    var rowCap: Int { period == .all ? 10_000 : 3_000 }

    var tripCap: Int { min(rowCap, 3_000) }

    func loadPeriodScopedData() async {
        isLoading = true
        defer { isLoading = false; didInitialLoad = true }

        let vin = state.vin
        let db = database
        let range = activeRange
        let cap = rowCap
        let tripLimit = tripCap
        let telemetryLimit = min(cap, 10_000)
        let chargingCapacity = preferences.vehicleSpecificationOverride(for: vin)?.usableBatteryCapacityKwh
            ?? state.configuredUsableBatteryCapacityKwh

        let loaded = await Task.detached(priority: .userInitiated) { () -> HistoryDataSnapshot in
            var snap = HistoryDataSnapshot()
            func inRange(_ date: Date) -> Bool { range.map { $0.contains(date) } ?? true }

            let rawTrips = db.derivedTrips(for: vin, limit: tripLimit)
            snap.trips = rawTrips.filter { inRange($0.endedAt) }

            let rawSessions = db.recentChargingSessions(for: vin, limit: cap)
            let reconciledSessions = rawSessions.map {
                $0.reconciled(database: db, usableCapacityKwh: chargingCapacity)
            }
            snap.chargingSessions = reconciledSessions.filter { inRange($0.startedAt) }
            snap.anomalousSessionIDs = HistoryInsights.sessionPeakAnomalies(in: snap.chargingSessions)

            let rawCommands = db.recentCommandAudits(for: vin, limit: min(cap, 2_000))
            snap.commands = rawCommands.filter { inRange($0.executedAt) }

            let rawAir = db.recentAirQuality(for: vin, limit: min(cap, 5_000))
            snap.airQualityRecords = rawAir.filter { inRange($0.timestamp) }

            let rawTelemetry = db.recentTelemetry(for: vin, limit: telemetryLimit)
            snap.telemetryRecords = rawTelemetry.filter { inRange($0.timestamp) }

            snap.truncated = rawTrips.count >= tripLimit || rawSessions.count >= cap
                || rawTelemetry.count >= telemetryLimit

            snap.hasHistoryOutsideRange = rawTrips.count > snap.trips.count
                || reconciledSessions.count > snap.chargingSessions.count
                || rawCommands.count > snap.commands.count
                || rawAir.count > snap.airQualityRecords.count

            let calendar = Calendar.current
            if let month = HistoryInsights.monthToDateWindows(calendar: calendar) {
                snap.thisMonth = Self.comparison(trips: rawTrips, sessions: reconciledSessions, in: month.current)
                snap.lastMonth = Self.comparison(trips: rawTrips, sessions: reconciledSessions, in: month.previous)
            }
            if let year = HistoryInsights.yearToDateWindows(calendar: calendar) {
                snap.thisYear = Self.comparison(trips: rawTrips, sessions: reconciledSessions, in: year.current)
                snap.lastYear = Self.comparison(trips: rawTrips, sessions: reconciledSessions, in: year.previous)
            }
            return snap
        }.value

        guard !Task.isCancelled else { return }
        snapshot = loaded
        tripPage = 0
        expandedTripIDs = []
        // `selectedSession` resolves to nil on its own when the remembered id isn't in the
        // current range, so the curve card just hides; the saved preference is kept so the
        // curve reappears if the range later includes that session again.
    }

    nonisolated static func comparison(trips: [TripHistoryEntry], sessions: [HistoricalChargingSession],
                                               in interval: DateInterval) -> MonthComparison {
        let windowTrips = trips.filter { interval.contains($0.endedAt) }
        let windowSessions = sessions.filter { interval.contains($0.startedAt) }
        let consumption = windowTrips.compactMap { trip -> Double? in
            guard let value = trip.averageConsumption, HistoryInsights.efficiencyBounds.contains(value) else { return nil }
            return value
        }
        return MonthComparison(
            distanceKm: windowTrips.reduce(0) { $0 + $1.distanceKm },
            energyKwh: windowSessions.reduce(0) { $0 + $1.energyDeliveredKwh },
            averageConsumption: consumption.isEmpty ? nil : consumption.reduce(0, +) / Double(consumption.count)
        )
    }

    func loadLifetimeData() async {
        let vin = state.vin
        let db = database
        let hasCombustion = state.powertrain.hasCombustionEngine
        let loaded = await Task.detached(priority: .userInitiated) { () -> LifetimeSnapshot in
            var snap = LifetimeSnapshot()
            snap.batteryHealthRecords = db.batteryHealthHistory(for: vin, limit: 500)
            snap.allTimeTelemetryRecords = db.recentTelemetry(for: vin, limit: 10_000)
            snap.fuelEntries = hasCombustion ? db.recentFuelEntries(for: vin, limit: 500) : []
            snap.cabinClimateRecords = db.recentCabinClimate(for: vin, limit: 2_000)
            snap.lifetimeChargingEnergyKwh = db.lifetimeChargingEnergyKwh(for: vin)
            snap.lifetimeFuelCost = db.lifetimeFuelCost(for: vin)
            return snap
        }.value
        guard !Task.isCancelled else { return }
        lifetime = loaded
    }

    func loadSelectedSessionSamples() async {
        guard let session = selectedSession else {
            selectedSessionSamples = []
            return
        }
        let db = database
        let samples = await Task.detached(priority: .userInitiated) { session.reconciledSamples(database: db) }.value
        guard !Task.isCancelled else { return }
        selectedSessionSamples = samples
    }

    func loadPreviousSessionCurve() async {
        guard overlayPreviousSession, let session = selectedSession,
              let index = chargingSessions.firstIndex(where: { $0.id == session.id }),
              index + 1 < chargingSessions.count else {
            previousSessionCurve = []
            return
        }
        let previous = chargingSessions[index + 1]
        let db = database
        let curve = await Task.detached(priority: .userInitiated) {
            HistoryInsights.chargingCurve(from: previous.reconciledSamples(database: db))
        }.value
        guard !Task.isCancelled else { return }
        previousSessionCurve = curve
    }

    var loadingSkeleton: some View {
        VStack(spacing: HisingenTheme.sectionSpacing) {
            ForEach(0..<3, id: \.self) { _ in
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        CardHeader(symbol: "chart.xyaxis.line", title: L10n.text("Loading history…"), color: .indigo)
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
            Image(systemName: symbol).font(.system(size: 8.5))
            Text(text).font(.system(size: 9)).fixedSize(horizontal: false, vertical: true)
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
            Text(value).font(.system(size: 11, weight: .bold, design: .rounded)).lineLimit(1)
            Text(title).font(.system(size: 8.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }

    // MARK: - Charging summary

    func aggregateChargingCost() -> (amount: Double, currency: String)? {
        let currencies = Set(chargingSessions.map {
            let saved = $0.currencySymbol?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (saved?.isEmpty == false ? saved : nil) ?? preferences.currencySymbol
        })
        guard currencies.count <= 1 else { return nil }
        let currency = currencies.first ?? preferences.currencySymbol
        let total = chargingSessions.reduce(0.0) { total, session in
            if let stored = session.estimatedCost { return total + stored }
            let dayRate = session.tariffPricePerKwh ?? preferences.electricityPricePerKwh
            return total + session.energyDeliveredKwh * dayRate
        }
        return (total, currency)
    }

    func dataConfidenceNote(for timestamps: [Date]) -> some View {
        let coverage = HistoryInsights.dataCoverage(timestamps: timestamps)
        return Group {
            if coverage.confidence == .low || coverage.confidence == .insufficient {
                Text(L10n.format("Limited data (%@ points) — treat this trend as indicative, not conclusive.", "\(coverage.sampleCount)"))
                    .font(.system(size: 8.5))
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
            Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundStyle(.tertiary)
            TextField(prompt, text: text)
                .textFieldStyle(.plain).font(.system(size: 9.5))
            if !text.wrappedValue.isEmpty {
                Text("\(count)/\(total)").font(.system(size: 8.5)).foregroundStyle(.tertiary)
                Button { text.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 9)) }
                    .buttonStyle(.borderless).accessibilityLabel(L10n.text("Clear search"))
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
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
        }
    }
}
