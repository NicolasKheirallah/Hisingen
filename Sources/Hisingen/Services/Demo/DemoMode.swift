import Foundation

/// The local sample vehicle used when the reader turns on demo mode. Every value is invented
/// for the demo and never presented as a real car: the VIN is obviously synthetic, the title
/// says Demo, and the session controller serves this snapshot without starting a provider.
enum DemoMode {
    static let vin = "YSDEMO00000000001"
    static let title = "Demo Polestar 2"

    static var carSummary: CarSummary {
        CarSummary(vin: vin, title: title)
    }

    static func state(now: Date = Date()) -> VehicleState {
        VehicleState(
            energy: EnergyAndChargingSnapshot(
                batteryPercentage: 72,
                rangeKm: 318,
                chargingState: .charging,
                estimatedTimeToFullMinutes: 84,
                targetPercentage: 80,
                powerWatts: 11_000,
                currentAmps: 16,
                voltageVolts: 230,
                type: .ac,
                connection: .connected,
                currentLimitAmps: 16,
                reportedBatteryCapacityKwh: 78),
            identity: VehicleIdentitySnapshot(
                availability: .available,
                availabilityReportedAt: now,
                modelName: "Polestar 2",
                modelYear: "2024",
                registrationNo: "DEMO 001",
                vin: vin,
                ownerFirstName: "Demo driver",
                externalColour: "Midnight",
                driveType: "AWD",
                numberOfSeats: 5,
                hasPremiumSubscription: true),
            maintenance: MaintenanceAndHealthSnapshot(odometerKm: 18_420),
            freshness: SnapshotFreshness(
                fetchedAt: now,
                vehicleReportedAt: now,
                dataWarnings: []))
    }
}
