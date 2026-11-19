import SwiftUI

@MainActor
struct SettingsVehicleDataCard: View {
    let state: VehicleState?
    let binder: PreferenceBinder

    private var prefs: PreferencesStore { binder.preferences }

    private func row(_ feature: AppFeature, symbol: String, title: String, detail: String,
                     isSupported: Bool = true, badgeText: String? = nil) -> SettingsFeatureToggleRow {
        SettingsFeatureToggleRow(binder: binder, feature: feature, symbol: symbol, title: title,
                                 detail: detail, isSupported: isSupported, badgeText: badgeText)
    }

    private func subsectionHeader(_ title: String) -> some View {
        Text(L10n.text(title))
            .hisType(.caption, weight: .bold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.top, 6)
    }

    var body: some View {
        let brand = prefs.activeBrand
        let isVolvo = brand == .volvo
        let brandName = brand.displayName
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "list.bullet.rectangle", title: L10n.text("Vehicle Data"), color: HisingenTheme.semanticGood)

                subsectionHeader("Vehicle & Identity")
                VStack(spacing: 4) {
                    row(.vehicleIdentity, symbol: "car.side", title: "Vehicle Identity", detail: "Model, year, license plate & VIN")
                    row(.ownerGreeting, symbol: "person.text.rectangle", title: "Owner Greeting", detail: L10n.format("Show the %@ ID first name", brandName), isSupported: !isVolvo, badgeText: isVolvo ? "N/A on Volvo" : nil)
                    row(.vehicleImage, symbol: "photo.artframe", title: "Studio Vehicle Image", detail: L10n.format("Render high-resolution %@ visual", brandName))
                    row(.vehicleAvailability, symbol: "antenna.radiowaves.left.and.right", title: "Vehicle Availability", detail: "Show online state and command availability")
                }

                subsectionHeader("Charging & Energy")
                VStack(spacing: 4) {
                    row(.chargingDetails, symbol: "powerplug", title: "Charging Telemetry", detail: "Power, voltage, current & completion time")
                    row(.chargingSchedule, symbol: "calendar.badge.clock", title: "Charging Schedules", detail: "Show charging windows and departure times", isSupported: !isVolvo, badgeText: isVolvo ? "Deprecated in API v2" : nil)
                    row(.chargeLocations, symbol: "mappin.and.ellipse", title: "Saved Charge Locations", detail: "Places saved on the car, with their schedules and current limits", isSupported: !isVolvo, badgeText: isVolvo ? "N/A on Volvo" : nil)
                    row(.batteryDiagnostics, symbol: "batteryblock", title: "Battery Diagnostics", detail: "Battery state, module health & energy usage")
                }

                subsectionHeader("Status & Security")
                VStack(spacing: 4) {
                    row(.exteriorStatus, symbol: "door.left.hand.open", title: "Exterior Doors & Windows", detail: "Open doors, windows, trunk & lock alerts")
                    row(.tyreAndWarnings, symbol: "circle.grid.2x2", title: "Tyre Pressures & Warnings", detail: "Pressure monitoring and system alerts")
                    row(.vehicleHealth, symbol: "speedometer", title: "Odometer & Service", detail: "Mileage, service intervals & fluid levels")
                }

                subsectionHeader("Climate & Air")
                VStack(spacing: 4) {
                    row(.climateStatus, symbol: "thermometer.medium", title: "Climate Status & Timers", detail: "Live interior status and scheduled timers")
                    row(.airQuality, symbol: "wind", title: "Cabin Air Quality", detail: "AQI & particulate matter sensors", isSupported: !isVolvo, badgeText: isVolvo ? "In-Car Only" : nil)
                }

                subsectionHeader("Location & Weather")
                VStack(spacing: 4) {
                    row(.vehicleLocation, symbol: "location", title: "Vehicle Location & Maps", detail: "Parking GPS coordinates and Apple Maps")
                    row(.vehicleWeather, symbol: "cloud.sun", title: "Vehicle Weather", detail: "Ambient weather at vehicle GPS location. Sends vehicle coordinates to Open-Meteo")
                }

                subsectionHeader("Advanced Diagnostics")
                VStack(spacing: 4) {
                    row(.tripMeters, symbol: "chart.xyaxis.line", title: "Trip Meters", detail: "Manual and automatic trip computers")
                    row(.connectivityDiagnostics, symbol: "antenna.radiowaves.left.and.right", title: "Connectivity", detail: "Vehicle network & signal diagnostics", isSupported: !isVolvo, badgeText: isVolvo ? "Enterprise Only" : nil)
                    row(.softwareUpdates, symbol: "arrow.triangle.2.circlepath", title: "Vehicle Software & OTA", detail: L10n.format("%@ software version and update status", brandName))
                }

                subsectionHeader("App Integration")
                VStack(spacing: 4) {
                    row(.multipleVehicles, symbol: "car.2", title: "Vehicle Switcher", detail: "Show controls for moving between vehicles on the same account")
                    row(.realTimeUpdates, symbol: "dot.radiowaves.left.and.right", title: "Real-Time Updates", detail: "Use live server streaming when supported, with polling as fallback", isSupported: !isVolvo, badgeText: isVolvo ? "Polling Only" : nil)
                }
            }
        }
    }
}
