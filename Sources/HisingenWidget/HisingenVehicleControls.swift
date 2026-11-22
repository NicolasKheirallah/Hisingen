import AppIntents
import HisingenIntents
import SwiftUI
import WidgetKit

/// The Control Center controls. The template builder accepts one template per control, so each
/// command is a separate control the reader adds independently.
///
/// Lock and climate remain the original URL launchers: they open Hisingen through
/// `OpenURLIntent` on the existing `hisingen://` routes, and the app then asks for confirmation
/// exactly as any other deep link does. Unlock, honk, charge-now and pre-cleaning are real App
/// Intents from the shared `HisingenIntents` module. They run with `openAppWhenRun`, so the app
/// performs them through the same capability gate, confirmation and audit path as the Controls
/// tab; the extension never reaches a vehicle backend itself.
///
/// The vehicle comes from the same App Group snapshot the timeline reads, so a control always
/// names the car the app last refreshed; with no snapshot the link or intent carries no VIN and
/// the app targets its active car.
private struct SelectedVehicleControlValue: Codable, Sendable {
    var vin: String

    init(vin: String) { self.vin = vin }

    init() { self.init(vin: "") }

    var lockURL: URL {
        Self.commandURL("hisingen://lock", vin: vin)
    }

    var climateURL: URL {
        Self.commandURL("hisingen://climate/start", vin: vin)
    }

    private static func commandURL(_ base: String, vin: String) -> URL {
        let encoded = vin.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? vin
        return URL(string: encoded.isEmpty ? base : "\(base)?vin=\(encoded)")
            ?? URL(string: base)!
    }
}

private struct SelectedVehicleProvider: ControlValueProvider {
    var previewValue: SelectedVehicleControlValue { SelectedVehicleControlValue() }

    func currentValue() async throws -> SelectedVehicleControlValue {
        SelectedVehicleControlValue(vin: WidgetSnapshotStore.load()?.vin ?? "")
    }
}

/// The Control Center actions that dispatch a real command and the shared command each names.
/// Keeping the mapping in one enum gives the tests a single place to pin it, and keeps each
/// control's kind stable as the UI changes.
enum VehicleControlAction: String, CaseIterable, Sendable {
    case unlock
    case honk
    case chargeNow
    case preCleaning

    var command: VehicleWidgetCommand {
        switch self {
        case .unlock: return .unlock
        case .honk: return .honkAndFlash
        case .chargeNow: return .startChargingOverride
        case .preCleaning: return .startPreCleaning
        }
    }

    var kind: String {
        switch self {
        case .unlock: return "io.kheirallah.hisingen.control.unlock"
        case .honk: return "io.kheirallah.hisingen.control.honk"
        case .chargeNow: return "io.kheirallah.hisingen.control.charge-now"
        case .preCleaning: return "io.kheirallah.hisingen.control.precleaning"
        }
    }
}

@available(macOS 26.0, *)
struct VehicleLockControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.kheirallah.hisingen.control.lock", provider: SelectedVehicleProvider()) { value in
            ControlWidgetButton(action: OpenURLIntent(value.lockURL)) {
                Label("Lock", systemImage: "lock")
            }
        }
        .displayName("Lock car")
        .description("Opens Hisingen with the lock command ready to confirm.")
    }
}

@available(macOS 26.0, *)
struct VehicleClimateControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.kheirallah.hisingen.control.climate", provider: SelectedVehicleProvider()) { value in
            ControlWidgetButton(action: OpenURLIntent(value.climateURL)) {
                Label("Start Climate", systemImage: "fan")
            }
        }
        .displayName("Start climate")
        .description("Opens Hisingen with the climate command ready to confirm.")
    }
}

@available(macOS 26.0, *)
struct VehicleUnlockControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: VehicleControlAction.unlock.kind, provider: SelectedVehicleProvider()) { value in
            ControlWidgetButton(action: WidgetUnlockVehicleIntent(vehicle: value.vin)) {
                Label("Unlock Vehicle", systemImage: "lock.open")
            }
        }
        .displayName("Unlock Vehicle")
    }
}

@available(macOS 26.0, *)
struct VehicleHonkControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: VehicleControlAction.honk.kind, provider: SelectedVehicleProvider()) { value in
            ControlWidgetButton(action: WidgetHonkVehicleIntent(vehicle: value.vin)) {
                Label("Honk and Flash Vehicle", systemImage: "horn")
            }
        }
        .displayName("Honk and Flash Vehicle")
    }
}

@available(macOS 26.0, *)
struct VehicleChargeNowControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: VehicleControlAction.chargeNow.kind, provider: SelectedVehicleProvider()) { value in
            ControlWidgetButton(action: WidgetChargeNowIntent(vehicle: value.vin)) {
                Label("Charge Now", systemImage: "bolt")
            }
        }
        .displayName("Charge Now")
    }
}

@available(macOS 26.0, *)
struct VehiclePreCleaningControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: VehicleControlAction.preCleaning.kind, provider: SelectedVehicleProvider()) { value in
            ControlWidgetButton(action: WidgetStartPreCleaningIntent(vehicle: value.vin)) {
                Label("Start Cabin Pre-Cleaning", systemImage: "wind")
            }
        }
        .displayName("Start Cabin Pre-Cleaning")
    }
}
