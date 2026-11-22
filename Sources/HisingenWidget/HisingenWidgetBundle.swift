import SwiftUI
import WidgetKit

/// The desktop widget: battery, range, charging state and the next departure, exactly as
/// the app's last completed refresh read them. The data area deep-links into the app on the
/// existing `hisingen://` routes. The action row's lock, unlock, climate and refresh buttons
/// are App Intents that open the app and run there; the extension itself sends no command.
struct VehicleWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "io.kheirallah.hisingen.vehicle", provider: VehicleTimelineProvider()) { entry in
            VehicleWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Vehicle status")
        .description("Battery, range, charging and the next departure, as the app last read them.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct HisingenWidgetBundle: WidgetBundle {
    var body: some Widget {
        VehicleWidget()
        if #available(macOS 26.0, *) {
            VehicleLockControl()
            VehicleClimateControl()
            VehicleUnlockControl()
            VehicleHonkControl()
            VehicleChargeNowControl()
            VehiclePreCleaningControl()
        }
    }
}
