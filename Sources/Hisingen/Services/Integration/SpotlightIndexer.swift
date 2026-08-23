import CoreSpotlight
import Foundation
import OSLog
import UniformTypeIdentifiers

/// Publishes the active vehicle's snapshot to system Spotlight so searching the car's name
/// surfaces its state without opening Hisingen. Entirely local — the index lives on this Mac,
/// contains only what the dashboard already shows, and is wiped on sign-out.
@MainActor
enum SpotlightIndexer {
    // Logger is Sendable, so completion closures outside the actor may use it.
    private nonisolated static let logger = AppLog.logger("spotlight")
    private static let domainIdentifier = "io.kheirallah.hisingen.vehicle"

    /// Re-indexes (or replaces) the entry for this VIN.
    static func indexVehicle(_ state: VehicleState, nickname: String) {
        guard !state.vin.isEmpty, CSSearchableIndex.isIndexingAvailable() else { return }
        let item = CSSearchableItem(
            uniqueIdentifier: state.vin,
            domainIdentifier: domainIdentifier,
            attributeSet: attributeSet(for: state, nickname: nickname)
        )
        CSSearchableIndex.default().indexSearchableItems([item]) { error in
            if let error {
                let nsError = error as NSError
                if nsError.domain == CSIndexErrorDomain && nsError.code == -1000 {
                    logger.debug("Spotlight indexing unsupported on system: \(String(describing: error), privacy: .public)")
                } else {
                    logger.warning("Spotlight indexing failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Removes every Hisingen entry — used on sign-out so a signed-out vehicle never keeps
    /// surfacing stale telemetry in search.
    static func removeAll() {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { _ in }
    }

    /// True when an incoming user activity is one of ours; lets the app delegate decide to
    /// surface the window without duplicating identifier knowledge there.
    static func isHisingenActivity(_ activity: NSUserActivity) -> Bool {
        activity.activityType == CSSearchableItemActionType
    }

    private static func attributeSet(for state: VehicleState,
                                     nickname: String) -> CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        let title = nickname.isEmpty ? (state.modelName ?? L10n.text("Vehicle")) : nickname
        attributes.title = title
        attributes.domainIdentifier = domainIdentifier

        var summary: [String] = []
        if let battery = state.batteryPercentage {
            summary.append(String(format: "%.0f%%", battery))
        }
        if let range = state.primaryRangeKm {
            summary.append("\(range) km")
        }
        if state.isCharging {
            summary.append(L10n.text("charging"))
        }
        attributes.contentDescription = summary.joined(separator: " · ")
        attributes.keywords = [state.model.brand.displayName, title, "Hisingen",
                               state.modelName ?? "", "EV"].filter { !$0.isEmpty }
        // Display names are not identifiers: the VIN stays out of the index entirely.
        attributes.relatedUniqueIdentifier = nil
        return attributes
    }
}
