import Foundation

/// Reads the `get_sessions` response of the durable capture component that Hisingen ships for
/// Home Assistant (`hisingen_home_charging`).
///
/// The component records each completed session when it ends, with the charger's own energy
/// readings per interval, so sessions finished while Hisingen was closed, or older than the
/// recorder's retention, are still there to import.
enum HomeCaptureSessions {
    static func candidates(from response: HAJSONValue, chargerID: String) -> [HomeChargingSessionCandidate] {
        let entries = response.objectValue?["sessions"]?.arrayValue ?? []
        return entries.compactMap { entry in
            guard let object = entry.objectValue,
                  let id = object["id"]?.stringValue, !id.isEmpty,
                  let start = object["started_at"]?.stringValue.flatMap(HATimestamp.parse),
                  let end = object["ended_at"]?.stringValue.flatMap(HATimestamp.parse), end > start,
                  let energy = object["energy_kwh"]?.doubleValue, energy > 0 else { return nil }
            // A rise recorded across a long gap is a total, not a profile: its intervals are not trusted.
            let coarse = object["coarse"]?.boolValue ?? false
            let intervals: [HomeEnergyInterval] = coarse ? [] : (object["intervals"]?.arrayValue ?? []).compactMap { item in
                guard let interval = item.objectValue,
                      let s = interval["start"]?.stringValue.flatMap(HATimestamp.parse),
                      let e = interval["end"]?.stringValue.flatMap(HATimestamp.parse),
                      let kwh = interval["kwh"]?.doubleValue, e > s, kwh >= 0 else { return nil }
                return HomeEnergyInterval(start: s, end: e, kwh: kwh)
            }
            return HomeChargingSessionCandidate(
                key: HomeChargingSessionCandidate.captureKey(chargerID: chargerID, captureID: id),
                keyKind: .captureID, chargerID: chargerID, startedAt: start, endedAt: end,
                energyKwh: energy, energySource: "ha_durable_capture", measuredAt: end, intervals: intervals,
                peakPowerKw: object["peak_power_kw"]?.doubleValue,
                vehicleStartPercent: object["vehicle_start_percent"]?.doubleValue,
                vehicleEndPercent: object["vehicle_end_percent"]?.doubleValue
            )
        }
    }
}
