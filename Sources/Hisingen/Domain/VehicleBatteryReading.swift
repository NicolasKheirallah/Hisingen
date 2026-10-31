import Foundation

struct VehicleBatteryReading: Codable, Equatable, Sendable {
    let reportedAt: Date?
    let batteryPercentage: Double?
    let rangeKm: Int?
    let estimatedChargingTimeToFullMinutes: Int?
    let chargingState: ChargingState?
    let chargerConnection: ChargerConnection
    let chargingType: ChargingType
    let chargingPowerWatts: Int?
    let chargingCurrentAmps: Int?
    let chargingVoltageVolts: Int?
    let diagnostics: BatteryDiagnostics
    let reportedBatteryCapacityKwh: Double?
    let unknownFields: [VehicleRawWireField]
}
