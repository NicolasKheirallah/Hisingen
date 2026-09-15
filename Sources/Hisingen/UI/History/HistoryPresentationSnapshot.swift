import Foundation

enum HistoryTripSort: String, CaseIterable, Identifiable, Sendable {
    case newest = "Newest"
    case distance = "Distance"
    case duration = "Duration"
    var id: String { rawValue }
}

/// Expensive chart and report transforms built once when a database snapshot lands, rather
/// than once per computed-property access during SwiftUI body evaluation.
struct HistoryPresentationSnapshot: Sendable {
    var efficiencyPoints: [HistoryInsights.EfficiencyPoint] = []
    var combustionConsumptionPoints: [HistoryInsights.EfficiencyPoint] = []
    var odometerPoints: [HistoryInsights.OdometerPoint] = []
    var allTimeOdometerPoints: [HistoryInsights.OdometerPoint] = []
    var commandStatistics = HistoryInsights.CommandStatistics(
        totalCount: 0, successCount: 0, successRatePct: nil, mostUsedCommand: nil
    )
    var mileageReports: [MonthlyMileageReport] = []

    static func build(
        dashboard: VehicleHistoryLedger.DashboardSnapshot,
        lifetime: VehicleHistoryLedger.LifetimeSnapshot,
        hasElectricRange: Bool,
        hasCombustionEngine: Bool
    ) -> HistoryPresentationSnapshot {
        HistoryPresentationSnapshot(
            efficiencyPoints: hasElectricRange
                ? HistoryInsights.efficiencyTrend(from: dashboard.telemetryRecords) : [],
            combustionConsumptionPoints: hasCombustionEngine
                ? HistoryInsights.combustionConsumptionTrend(from: dashboard.telemetryRecords) : [],
            odometerPoints: HistoryInsights.odometerTrend(from: dashboard.telemetryRecords),
            allTimeOdometerPoints: HistoryInsights.odometerTrend(from: lifetime.allTimeTelemetryRecords),
            commandStatistics: HistoryInsights.commandStatistics(from: dashboard.commands),
            mileageReports: MonthlyMileageReport.build(
                from: dashboard.reportTrips, purposes: dashboard.tripPurposes
            )
        )
    }
}

struct HistoryDashboardLoadResult: Sendable {
    let dashboard: VehicleHistoryLedger.DashboardSnapshot
    let lifetime: VehicleHistoryLedger.LifetimeSnapshot
    let presentation: HistoryPresentationSnapshot
}

struct HistoryTripPresentation: Sendable {
    var trips: [TripHistoryEntry] = []
    /// The same period, with hidden trips excluded but the search box ignored.
    ///
    /// The search field is a filter on the trip *list*; it sits inside that card and is
    /// labelled for it. Letting it reach the summary totals above meant typing a date quietly
    /// restated the period's distance and trip count, and left two adjacent cards disagreeing
    /// about the same number. Hiding a trip is a deliberate, persisted decision, so it does
    /// apply here.
    var aggregateTrips: [TripHistoryEntry] = []
    var hours: [HistoryInsights.HourBucket] = []
    var weekdayWeekend = HistoryInsights.WeekdayWeekendSplit(
        weekdayKm: 0, weekendKm: 0, weekdayTripCount: 0, weekendTripCount: 0
    )

    static func build(
        from source: [TripHistoryEntry], hidden: Set<String>, searchText: String,
        sort: HistoryTripSort, dateStrings: [String: String]
    ) -> HistoryTripPresentation {
        let base = hidden.isEmpty ? source : source.filter { !hidden.contains($0.id) }
        let searched = searchText.isEmpty ? base : base.filter {
            (dateStrings[$0.id] ?? "").localizedCaseInsensitiveContains(searchText)
        }
        let trips: [TripHistoryEntry]
        switch sort {
        case .newest: trips = searched
        case .distance: trips = searched.sorted { $0.distanceKm > $1.distanceKm }
        case .duration: trips = searched.sorted { $0.duration > $1.duration }
        }
        return HistoryTripPresentation(
            trips: trips,
            aggregateTrips: base,
            hours: HistoryInsights.tripsByHourOfDay(from: base),
            weekdayWeekend: HistoryInsights.weekdayWeekendDistance(from: base)
        )
    }
}
