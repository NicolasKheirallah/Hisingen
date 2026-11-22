import Foundation
import OSLog

/// The banner a recurring report posts. `Notifier` conforms in its own file; tests supply a fake.
@MainActor
protocol RecurringReportNotifying {
    func notifyReport(title: String, body: String)
}

/// Posts the weekly or monthly report the reader asked for, once per completed window.
///
/// It is deliberately a *scheduler*, not a second history reader: the report itself comes from
/// `HistoryWorkspace.periodReport`, the same loader the History card uses, so a notification and a
/// printed report can never disagree about the window they describe. Nothing fires for the window
/// the reader is living in – a report is about a period that finished.
@MainActor
final class RecurringReportController {
    private let logger = AppLog.logger("reports")
    private let preferences: PreferencesStore
    private let notifier: any RecurringReportNotifying
    /// The active vehicle and the name to print for it. Reports follow the reader's selection, the
    /// same rule the calendar preconditioning card follows.
    private let activeVehicle: () -> (vin: String, name: String)?
    private let loadReport: @MainActor (ReportPeriod, String) async -> PeriodReportInput?
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let scheduler: AsyncTimerLoop
    private var evaluationInProgress = false

    /// How often the window check runs. The work is one calendar subtraction per tick, and a
    /// reader who leaves the Mac asleep over midnight still gets the report the next morning.
    static let tickInterval: TimeInterval = 3 * 3_600

    init(preferences: PreferencesStore,
         notifier: any RecurringReportNotifying,
         activeVehicle: @escaping () -> (vin: String, name: String)?,
         loadReport: @escaping @MainActor (ReportPeriod, String) async -> PeriodReportInput?,
         now: @escaping @Sendable () -> Date = { Date() },
         calendar: Calendar = .current,
         wait: @escaping AsyncTimerLoop.Wait = AsyncTimerLoop.realWait) {
        self.preferences = preferences
        self.notifier = notifier
        self.activeVehicle = activeVehicle
        self.loadReport = loadReport
        self.now = now
        self.calendar = calendar
        self.scheduler = AsyncTimerLoop(wait: wait)
    }

    var isArmed: Bool { scheduler.isArmed }

    func start() {
        guard !scheduler.isArmed else { return }
        scheduler.scheduleRepeating(after: Self.tickInterval) { [weak self] in
            await self?.evaluate()
        }
        Task { @MainActor [weak self] in
            await self?.evaluate()
        }
    }

    func stop() {
        scheduler.cancel()
    }

    /// Re-reads the setting. Called at launch and when the reader changes the cadence in Settings.
    func reload() {
        guard preferences.recurringReportEnabled else {
            scheduler.cancel()
            return
        }
        if !scheduler.isArmed { start() } else {
            Task { @MainActor [weak self] in await self?.evaluate() }
        }
    }

    /// The window a report is due for right now: the one that just finished. Nil when the feature
    /// is off, no vehicle is selected, or that window was already reported.
    func duePeriod(now moment: Date? = nil) -> (period: ReportPeriod, vin: String, name: String)? {
        guard preferences.recurringReportEnabled, let vehicle = activeVehicle(),
              !vehicle.vin.isEmpty else { return nil }
        let reference = moment ?? now()
        let period = preferences.recurringReportCadence
            .completedPeriod(endingAt: reference, calendar: calendar)
        guard preferences.recurringReportLastPeriod(for: vehicle.vin) != period.key else { return nil }
        return (period, vehicle.vin, vehicle.name)
    }

    func evaluate(now moment: Date? = nil) async {
        guard !evaluationInProgress else { return }
        evaluationInProgress = true
        defer { evaluationInProgress = false }

        guard let due = duePeriod(now: moment) else { return }
        guard let report = await loadReport(due.period, due.name) else {
            // The load failed rather than the window being empty; retry on the next tick instead of
            // recording a report nobody saw.
            logger.error("Recurring report load failed; it will retry on the next tick")
            return
        }
        // Recorded before posting: a banner that fails to appear must not make the next tick
        // post the same window again.
        preferences.setRecurringReportLastPeriod(due.period.key, for: due.vin)
        guard !report.isEmpty else {
            logger.info("No readings in the completed report window; nothing to send")
            return
        }
        let title = L10n.format("%@ report · %@", report.period.cadence.title, report.period.titleText())
        notifier.notifyReport(title: title, body: VehiclePeriodReport.summaryText(report))
        logger.info("Posted recurring report for \(report.period.key, privacy: .public)")
    }
}
