import AppIntents
import SwiftUI
import WidgetKit

/// The Control Center controls. The template builder accepts one template per control, so
/// lock and climate are two separate controls the reader adds independently.
///
/// Neither control sends a command: each opens the app through `OpenURLIntent` on the
/// existing `hisingen://` routes, and the app then asks for confirmation exactly as any
/// other deep link does. The vehicle comes from the same App Group snapshot the timeline
/// reads, so a control always names the car the app last refreshed; with no snapshot the
/// link carries no VIN and the app targets its active car.
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
