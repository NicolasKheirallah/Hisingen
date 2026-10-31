import AppKit

extension Notifier {
    /// How long the car may stay in convenience mode before the alert fires. Shorter stops are
    /// normal; past this point the 12 V battery is being drained by systems left on.
    static let convenienceModeAlertDuration: TimeInterval = 30 * 60

    /// True only while the availability frame says the car is in convenience mode. Polestar
    /// sends the bare token ("CONVENIENCE") and the portal sends the enum name, so both are
    /// accepted. Volvo reports no usage mode, so it never satisfies this.
    ///
    /// The frame may arrive less often than telemetry, so it is accepted for up to an hour
    /// rather than the ten-minute window the other vehicle readings use.
    nonisolated static func convenienceModeCondition(_ state: VehicleState?) -> Bool {
        guard let state, state.hasFreshReading(.availability, maximumAge: 3_600),
              let raw = state.identity.usageMode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        else { return false }
        let prefix = "USAGE_MODE_"
        let token = raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
        return token == "CONVENIENCE"
    }

    /// Opt-in. Only the usage-mode token is read here; location is never consulted.
    func checkUsageMode(current: VehicleState) {
        let vin = current.identity.vin
        trackSustained(condition: Self.convenienceModeCondition(current),
                       key: "\(vin).usage-convenience",
                       duration: Self.convenienceModeAlertDuration,
                       enabled: preferences.notifyUsageModeConvenience) {
            self.postNotice(identifier: "hisingen.\(vin).usage-convenience",
                            thread: "hisingen.usage.\(vin)",
                            title: L10n.text("Left in convenience mode"),
                            body: L10n.text("Convenience mode keeps systems on and can drain the 12 V battery."),
                            subtitle: self.displayName(for: current), vin: vin,
                            urgency: .attention,
                            category: Self.vehicleAlertCategoryID)
        }
    }
}
