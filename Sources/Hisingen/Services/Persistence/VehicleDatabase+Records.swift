import Foundation

extension VehicleDatabase {
    /// What makes a battery-health row a *milestone* rather than a duplicate.
    ///
    /// `VehicleStateStore.save(_:)` runs on every refresh – minutes apart – but state of
    /// health moves over months. Recording unconditionally produced ~15 rows/hour that
    /// shared 3 distinct SoH values, and nothing prunes this table, so it grew without
    /// bound. A row is now written only when it carries new information.
    enum BatteryHealthMilestone {
        /// Heartbeat, so a stationary vehicle still leaves a periodic trend point.
        static let minimumInterval: TimeInterval = 7 * 24 * 60 * 60
        /// Real SoH movement. Below this is measurement noise, not degradation.
        static let sohDeltaPct: Double = 0.5
        /// Degradation tracks mileage, so meaningful distance also earns a row.
        static let odometerDeltaKm: Double = 500
    }

    struct ConnectivityRecord: Codable, Equatable, Identifiable, Sendable {
        let id: Int64
        let vin: String
        let timestamp: Date
        let networkType: String?
        let signalBars: Int?
        let wakeReason: String?
    }

    struct CabinClimateRecord: Codable, Equatable, Identifiable, Sendable {
        let id: Int64
        let vin: String
        let timestamp: Date
        let interiorCelsius: Double?
        let requestedCelsius: Double?
    }

    /// One tyre's numeric reading as the domain reports it, before it is stored.
    struct TyrePressureReading: Equatable, Sendable {
        let position: TyrePosition
        let kilopascals: Double
        let referenceKilopascals: Double?
    }

    /// One numeric tyre-pressure reading. Warning levels without a pressure value are never
    /// stored here: a row only exists when the vehicle reported kilopascals.
    struct TyrePressureRecord: Codable, Equatable, Identifiable, Sendable {
        let id: Int64
        let vin: String
        let timestamp: Date
        let position: TyrePosition
        let kilopascals: Double
        let referenceKilopascals: Double?
    }

    struct WarningEventRecord: Codable, Equatable, Identifiable, Sendable {
        let id: Int64
        let vin: String
        let warning: VehicleWarning
        let firstSeen: Date
        /// `nil` while the warning is still reported as active.
        let clearedAt: Date?
    }

    struct FuelEntry: Codable, Equatable, Identifiable, Sendable {
        let id: Int64
        let vin: String
        let date: Date
        let liters: Double
        let pricePerLiter: Double
        let odometerKm: Double?
    }
}
