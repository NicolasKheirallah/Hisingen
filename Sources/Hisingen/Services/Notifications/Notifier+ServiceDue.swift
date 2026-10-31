import AppKit

extension Notifier {
    /// Shared with the daily summary so both report the same threshold.
    nonisolated static func serviceDueSoon(_ service: ServiceSnapshot) -> Bool {
        service.serviceWarning
            || (service.daysToService.map { $0 <= 30 } ?? false)
            || (service.distanceToServiceKm.map { $0 <= 1_000 } ?? false)
    }

    func checkServiceDue(current: VehicleState) {
        guard preferences.notifyServiceDue, current.hasFreshReading(.health) else { return }
        let due = Self.serviceDueSoon(current.maintenance.service)
        // The was-due flag persists across launches: without it, staying due re-fired
        // the banner on every relaunch because the in-memory previous state was empty.
        let wasDue = serviceDueByVIN[current.identity.vin] ?? false
        if serviceDueByVIN[current.identity.vin] != due {
            serviceDueByVIN[current.identity.vin] = due
            defaults.set(serviceDueByVIN, forKey: "notifier_service_due_v1")
        }
        guard due, !wasDue else { return }
        var details: [String] = []
        if let days = current.maintenance.service.daysToService { details.append(L10n.format("%d days", days)) }
        if let km = current.maintenance.service.distanceToServiceKm { details.append(Format.distance(km: km, unit: preferences.distanceUnit)) }
        postNotice(identifier: "hisingen.\(current.identity.vin).service-due", thread: "hisingen.service.\(current.identity.vin)",
                   title: L10n.text("Vehicle service due soon"),
                   body: privateBody(details.isEmpty ? L10n.text("Open Hisingen for details.") : details.joined(separator: " · ")),
                   subtitle: displayName(for: current), vin: current.identity.vin,
                   urgency: .background, category: Self.vehicleAlertCategoryID)
    }
}
