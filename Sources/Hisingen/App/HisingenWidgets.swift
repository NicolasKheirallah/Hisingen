import SwiftUI
import WidgetKit

@available(macOS 13.0, *)
struct VehicleWidgetEntry: TimelineEntry {
    let date: Date
    let state: VehicleState?
    var isPlaceholder: Bool = false
}

@available(macOS 13.0, *)
struct VehicleTimelineProvider: TimelineProvider {
    typealias Entry = VehicleWidgetEntry

    func placeholder(in context: Context) -> VehicleWidgetEntry {
        VehicleWidgetEntry(date: Date(), state: sampleState, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (VehicleWidgetEntry) -> Void) {
        let (_, state) = MainActor.assumeIsolated { () -> (String, VehicleState?) in
            let v = Preferences.vin
            let s = VehicleStateStore().snapshot(for: v)
            return (v, s)
        }
        completion(VehicleWidgetEntry(date: Date(), state: state ?? sampleState, isPlaceholder: context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VehicleWidgetEntry>) -> Void) {
        let (_, state) = MainActor.assumeIsolated { () -> (String, VehicleState?) in
            let v = Preferences.vin
            let s = VehicleStateStore().snapshot(for: v)
            return (v, s)
        }
        let entry = VehicleWidgetEntry(date: Date(), state: state, isPlaceholder: false)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date().addingTimeInterval(300)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private var sampleState: VehicleState {
        VehicleState(
            batteryPercentage: 78,
            rangeKm: 340,
            chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil,
            chargeTargetPercentage: 90,
            chargingPowerWatts: nil,
            chargingCurrentAmps: nil,
            chargingVoltageVolts: nil,
            chargingType: .unknown,
            chargerConnection: .disconnected,
            availability: .available,
            modelName: "Polestar 2",
            modelYear: "2024",
            registrationNo: "HGN 2024",
            vin: "YSMSAMPLEVIN0001",
            ownerFirstName: nil,
            odometerKm: 12500,
            daysToService: 240,
            distanceToServiceKm: 17500,
            serviceWarning: false,
            fluidWarnings: [],
            exteriorStatus: ExteriorSnapshot(openings: [], isLocked: true, alarmTriggered: false),
            imageData: nil,
            fetchedAt: Date(),
            vehicleReportedAt: Date(),
            dataWarnings: []
        )
    }
}

@available(macOS 13.0, *)
struct HisingenWidgetSmallView: View {
    let entry: VehicleWidgetEntry

    var body: some View {
        if let state = entry.state {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: state.isCharging ? "bolt.fill" : "car.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(state.isCharging ? Color.green : HisingenTheme.accent)
                    Text(state.modelName ?? "Vehicle")
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    if let locked = state.exteriorStatus?.isLocked {
                        Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(locked ? Color.secondary : Color.orange)
                    }
                }

                Spacer()

                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(String(format: "%.0f", state.batteryPercentage ?? 0))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("%")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                if let range = state.primaryRangeKm {
                    Text(String(format: "%d %@", Preferences.distanceUnit.convert(km: range), Preferences.distanceUnit.suffix))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                if state.isCharging, let power = state.chargingPowerWatts, power > 0 {
                    Text(Format.kilowatts(watts: power))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.green)
                }
            }
            .padding(12)
        } else {
            VStack(spacing: 4) {
                Image(systemName: "car.side.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                Text(L10n.text("No Vehicle"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }
}

@available(macOS 13.0, *)
struct HisingenWidgetMediumView: View {
    let entry: VehicleWidgetEntry

    var body: some View {
        if let state = entry.state {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: state.isCharging ? "bolt.fill" : "car.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(state.isCharging ? Color.green : HisingenTheme.accent)
                        Text(state.modelName ?? "Vehicle")
                            .font(.system(size: 11, weight: .bold))
                            .lineLimit(1)
                    }

                    Spacer()

                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text(String(format: "%.0f", state.batteryPercentage ?? 0))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("%")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    if let range = state.primaryRangeKm {
                        Text(String(format: "%d %@", Preferences.distanceUnit.convert(km: range), Preferences.distanceUnit.suffix))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider().opacity(0.4)

                VStack(alignment: .leading, spacing: 5) {
                    if let locked = state.exteriorStatus?.isLocked {
                        HStack(spacing: 4) {
                            Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(locked ? Color.green : Color.orange)
                            Text(locked ? L10n.text("Locked") : L10n.text("Unlocked"))
                                .font(.system(size: 10.5, weight: .medium))
                        }
                    }

                    if let climate = state.climateStatus {
                        HStack(spacing: 4) {
                            Image(systemName: "fan.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(climate.activity == .idle ? Color.secondary : Color.orange)
                            Text(climate.activity.displayName)
                                .font(.system(size: 10.5, weight: .medium))
                        }
                    }

                    if state.isCharging {
                        if let power = state.chargingPowerWatts, power > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "bolt.badge.clock.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.green)
                                Text(Format.kilowatts(watts: power))
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.green)
                            }
                        }
                    } else if let odo = state.odometerKm {
                        HStack(spacing: 4) {
                            Image(systemName: "speedometer")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(Format.distance(km: odo, unit: Preferences.distanceUnit))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Text(Format.shortTime(date: state.fetchedAt))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
        } else {
            Text(L10n.text("No vehicle telemetry available."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(14)
        }
    }
}

@available(macOS 13.0, *)
struct HisingenWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: VehicleWidgetEntry

    var body: some View {
        switch family {
        case .systemSmall:
            HisingenWidgetSmallView(entry: entry)
        case .systemMedium:
            HisingenWidgetMediumView(entry: entry)
        default:
            HisingenWidgetSmallView(entry: entry)
        }
    }
}
