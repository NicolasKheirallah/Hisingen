import Foundation

extension Notifier: PriceAlertNotifying {
    /// One banner per crossing. The identifier carries the zone and the slot the crossing opened,
    /// so a repeat of the same crossing replaces the banner already on screen while a later
    /// crossing can still arrive.
    func notifyPriceAlert(title: String, body: String, zone: ElspotZone, slotStart: Date) {
        let stamp = Int(slotStart.timeIntervalSince1970)
        postNotice(
            identifier: "hisingen.price-alert.\(zone.rawValue).\(stamp)",
            thread: "hisingen.price-alerts",
            title: title,
            body: body,
            urgency: .info
        )
    }
}
