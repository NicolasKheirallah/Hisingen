import Foundation

/// Battery fields 20–30 of the digital-twin battery message. Each decoder accepts only the wire
/// type, tags and enum numbers the app schema defines and returns nil for anything else, so
/// that occurrence stays in the raw disclosure. Tags and enum numbers come from the `Battery`
/// classes of Polestar Explore 5.14.0; see docs/research/polestar-protobuf-field-decode.md.
extension PolestarGRPC {
    /// Fields this file decodes. Each occurrence is checked with `decodesRemainingBatteryField`.
    static let remainingBatteryFields: Set<Int> = [20, 21, 22, 23, 24, 25, 27, 29, 30]

    /// `ManualPreconditioningStatus` 1…5. Unspecified (0) is handled separately as "no status".
    private static let manualPreconditioningStatusByWire: [UInt64: String] = [
        1: "MANUAL_PRECONDITIONING_STATUS_OFF",
        2: "MANUAL_PRECONDITIONING_STATUS_PRECONDITIONING_FINISHED",
        3: "MANUAL_PRECONDITIONING_STATUS_ON",
        4: "MANUAL_PRECONDITIONING_STATUS_BATTERY_TEMPERATURE_OPTIMAL",
        5: "MANUAL_PRECONDITIONING_STATUS_UNAVAILABLE"
    ]

    /// `ColdBatteryStatus` 1…5. Unspecified (0) is handled separately as "not reported".
    private static let coldBatteryByWire: [UInt64: ColdBatteryStatus] = [
        1: .normal, 2: .coldPredicted, 3: .coldAndLowSOCPredicted, 4: .cold, 5: .coldAndLowSOC
    ]

    struct ManualPreconditioningReading: Equatable, Sendable {
        /// The `MANUAL_PRECONDITIONING_STATUS_*` token, nil when the car sent unspecified.
        let status: String?
        let endsAt: Date?
    }

    /// Whether this occurrence of a field in `remainingBatteryFields` decodes.
    static func decodesRemainingBatteryField(_ field: Protobuf.Field) -> Bool {
        switch field.number {
        case 20...25: return energyCategories(field) != nil
        case 27: return dischargeInfo(field) != nil
        case 29: return manualPreconditioning(field) != nil
        case 30: return coldBatteryWire(field) != nil
        default: return false
        }
    }

    /// Energy use per trip period. Fields 20–22 carry Wh and 23–25 carry percentages for the
    /// manual trip, the automatic trip and the period since charge. The last valid occurrence
    /// of each field wins, as for proto3 scalars.
    static func energyByPeriod(_ fields: [Protobuf.Field]) -> EnergyBreakdownByPeriod? {
        func period(wh: Int, percentage: Int) -> EnergyBreakdownSnapshot? {
            breakdown(wattHours: lastDecoded(fields, wh, energyCategories),
                      percentages: lastDecoded(fields, percentage, energyCategories))
        }
        let result = EnergyBreakdownByPeriod(
            manualTrip: period(wh: 20, percentage: 23),
            automaticTrip: period(wh: 21, percentage: 24),
            sinceCharge: period(wh: 22, percentage: 25)
        )
        return result.hasData ? result : nil
    }

    /// Discharge values keyed by tag: 1 energy available (kWh), 2 the increase once conditioning
    /// completes, 3 the power limit (kW).
    static func dischargeValues(_ fields: [Protobuf.Field]) -> [Int: Double]? {
        lastDecoded(fields, 27, dischargeInfo)
    }

    static func manualPreconditioningReading(_ fields: [Protobuf.Field]) -> ManualPreconditioningReading? {
        lastDecoded(fields, 29, manualPreconditioning)
    }

    static func coldBatteryStatus(_ fields: [Protobuf.Field]) -> ColdBatteryStatus? {
        lastDecoded(fields, 30, coldBatteryWire).flatMap { coldBatteryByWire[$0] }
    }

    // MARK: - Field decoders

    /// `EnergyConsumptionWh` and `EnergyConsumptionPercentage`: four `int32` categories at tags
    /// 1 other, 2 driving, 3 climate, 4 battery. An empty message carries nothing and stays raw.
    private static func energyCategories(_ field: Protobuf.Field) -> [Int: Double]? {
        guard let inner = innerFields(field) else { return nil }
        var values: [Int: Double] = [:]
        for item in inner {
            guard item.wire == 0, (1...4).contains(item.number),
                  item.varint <= UInt64(Int32.max) else { return nil }
            values[item.number] = Double(item.varint)
        }
        return values
    }

    /// `DischargeInfo`: three `float` values at tags 1, 2 and 3 (fixed32, wire type 5).
    private static func dischargeInfo(_ field: Protobuf.Field) -> [Int: Double]? {
        guard let inner = innerFields(field) else { return nil }
        var values: [Int: Double] = [:]
        for item in inner {
            guard item.wire == 5, (1...3).contains(item.number),
                  let value = Protobuf.float(from: item.data), value.isFinite, value >= 0 else { return nil }
            values[item.number] = Double(value)
        }
        return values
    }

    /// `ManualPreconditioning`: status at tag 1 and ending time at tag 3. The unavailable reason
    /// (2) and start time (4) are not decoded, so a message carrying them stays raw.
    private static func manualPreconditioning(_ field: Protobuf.Field) -> ManualPreconditioningReading? {
        guard let inner = innerFields(field) else { return nil }
        var statusWire: UInt64?
        var endsAt: Date?
        for item in inner {
            switch item.number {
            case 1:
                guard item.wire == 0, item.varint == 0 || manualPreconditioningStatusByWire[item.varint] != nil else {
                    return nil
                }
                statusWire = item.varint
            case 3:
                guard item.wire == 2, let timestamp = try? ProtoMessage(item.data),
                      timestamp.fields.allSatisfy({ $0.number == 1 && $0.wire == 0 }) else { return nil }
                endsAt = timestamp.uint(1).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
            default:
                return nil
            }
        }
        let status = statusWire.flatMap { $0 == 0 ? nil : manualPreconditioningStatusByWire[$0] }
        return ManualPreconditioningReading(status: status, endsAt: endsAt)
    }

    /// The wire value of `ColdBatteryStatus` when it is 0 (unspecified) or a defined 1…5.
    private static func coldBatteryWire(_ field: Protobuf.Field) -> UInt64? {
        guard field.wire == 0, field.varint == 0 || coldBatteryByWire[field.varint] != nil else { return nil }
        return field.varint
    }

    // MARK: - Helpers

    /// The sub-fields of a length-delimited message, or nil when the field is not one or is
    /// empty or malformed.
    private static func innerFields(_ field: Protobuf.Field) -> [Protobuf.Field]? {
        guard field.wire == 2, let inner = try? Protobuf.decode(field.data), !inner.isEmpty else { return nil }
        return inner
    }

    private static func lastDecoded<T>(_ fields: [Protobuf.Field], _ number: Int,
                                       _ decode: (Protobuf.Field) -> T?) -> T? {
        var result: T?
        for field in fields where field.number == number {
            if let value = decode(field) { result = value }
        }
        return result
    }

    private static func breakdown(wattHours: [Int: Double]?, percentages: [Int: Double]?) -> EnergyBreakdownSnapshot? {
        func item(_ tag: Int) -> EnergyBreakdownItem? {
            let wh = wattHours?[tag]
            let percentage = percentages?[tag]
            guard wh != nil || percentage != nil else { return nil }
            return EnergyBreakdownItem(wattHours: wh, percentage: percentage)
        }
        let snapshot = EnergyBreakdownSnapshot(driving: item(2), climate: item(3), battery: item(4), other: item(1))
        return snapshot.hasData ? snapshot : nil
    }
}
