import Foundation

extension PreferencesStore {
    /// Which window the recurring report covers. Off until the reader asks for it: a periodic
    /// banner is a commitment, not a default.
    static let recurringReportCadenceKey = "recurring_report_cadence_v1"
    /// The last window each vehicle was reported for: VIN → `ReportPeriod.key`.
    static let recurringReportLastPeriodKey = "recurring_report_last_period_v1"

    var recurringReportEnabled: Bool {
        get { d.bool(forKey: "recurring_report_enabled") }
        set { d.set(newValue, forKey: "recurring_report_enabled") }
    }

    var recurringReportCadence: ReportCadence {
        get {
            guard let raw = d.string(forKey: Self.recurringReportCadenceKey),
                  let cadence = ReportCadence(rawValue: raw) else { return .monthly }
            return cadence
        }
        set { d.set(newValue.rawValue, forKey: Self.recurringReportCadenceKey) }
    }

    /// The window key already reported for this vehicle, so a relaunch cannot repeat it.
    func recurringReportLastPeriod(for vin: String) -> String? {
        let key = vin.normalizedVIN
        guard !key.isEmpty,
              let all = d.dictionary(forKey: Self.recurringReportLastPeriodKey) as? [String: String] else {
            return nil
        }
        return all[key]
    }

    func setRecurringReportLastPeriod(_ periodKey: String?, for vin: String) {
        let key = vin.normalizedVIN
        guard !key.isEmpty else { return }
        var all = d.dictionary(forKey: Self.recurringReportLastPeriodKey) as? [String: String] ?? [:]
        if let periodKey { all[key] = periodKey } else { all.removeValue(forKey: key) }
        d.set(all, forKey: Self.recurringReportLastPeriodKey)
    }
}
