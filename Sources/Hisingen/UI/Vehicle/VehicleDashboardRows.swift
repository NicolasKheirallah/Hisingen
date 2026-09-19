import SwiftUI

/// The dashboard's status rows: icon, value, label, one line, no surface.
///
/// The Wi-Fi-menu grammar. Tiles were tried here and read as cards, because a filled rounded
/// rectangle is a card whatever it contains; a row is only typography on the panel glass. The
/// hierarchy is carried by weight and alignment — the tinted icon leads, the value is ink at
/// body weight, the label trails muted — and rows stack on whitespace alone. Every pair sits
/// on the panel (canvas), the exact surface the contrast gate proves ink, inkMuted and the
/// semantic tints against. The hero owns the battery figure, so no row repeats it.
@MainActor
struct DashboardRow: View {
    let symbol: String
    let value: String
    let label: String
    var tint: Color = HisingenTheme.ink

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .hisType(.subhead, weight: .semibold)
                .foregroundStyle(tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(value)
                .hisType(.subhead, weight: .semibold)
                .foregroundStyle(HisingenTheme.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .hisTelemetryValue(value, reduceMotion: reduceMotion)
            Spacer()
            Text(label)
                .hisType(.caption, weight: .semibold)
                .foregroundStyle(HisingenTheme.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// The dashboard row builders. Every string is one the card it replaced already shipped, so no
/// new localization keys enter with the grammar.
@MainActor
enum VehicleDashboardRows {

    /// Doors and locks as one row. An open panel makes the count the value with the warning
    /// tint; otherwise the lock state is.
    static func doors(state: VehicleState) -> AnyView? {
        guard let ext = state.exteriorStatus else { return nil }
        let openCount = ext.itemsNeedingAttention.count
        let row: DashboardRow
        if openCount > 0 {
            row = DashboardRow(
                symbol: "lock.open.fill",
                value: L10n.format("%d Open", openCount),
                label: L10n.text("Doors & Openings"),
                tint: HisingenTheme.semanticWarning
            )
        } else if let locked = ext.isLocked {
            row = DashboardRow(
                symbol: locked ? "lock.fill" : "lock.open.fill",
                value: locked ? L10n.text("Locked") : L10n.text("Unlocked"),
                label: L10n.text("Doors & Openings"),
                tint: locked ? HisingenTheme.semanticGood : HisingenTheme.inkMuted
            )
        } else {
            return nil
        }
        return AnyView(row)
    }

    /// Fuel and engine as one row: the level with the distance to empty when the car burns
    /// fuel, otherwise the engine state.
    static func fuel(state: VehicleState, distanceUnit: DistanceUnit) -> AnyView? {
        let level = state.fuelSystem.levelPercent
        let running = state.fuelSystem.isEngineRunning
        guard level != nil || running != nil else { return nil }

        let symbol: String
        let value: String
        let tint: Color
        if let level {
            symbol = "fuelpump.fill"
            // The fuel card warned below 12 %; the row keeps exactly that threshold.
            tint = level <= 12 ? HisingenTheme.semanticWarning : HisingenTheme.ink
            if let range = state.fuelSystem.rangeKm {
                value = "\(String(format: "%.0f%%", level)) · \(Format.distance(km: range, unit: distanceUnit))"
            } else {
                value = String(format: "%.0f%%", level)
            }
        } else if let running {
            symbol = "engine.combustion.fill"
            value = running ? L10n.text("Running") : L10n.text("Stopped")
            tint = HisingenTheme.ink
        } else {
            return nil
        }
        return AnyView(DashboardRow(symbol: symbol, value: value, label: L10n.text("Fuel & Engine"), tint: tint))
    }

    /// The departure checker, one disclosure: collapsed it is a single quiet line, and the
    /// feature the readiness card carried survives without a titled section.
    static func departureCheck(state: VehicleState) -> AnyView? {
        guard state.powertrain.hasElectricRange else { return nil }
        return AnyView(DepartureCheckDisclosure(state: state))
    }
}

/// The collapsed-by-default charging-before-departure checker.
private struct DepartureCheckDisclosure: View {
    let state: VehicleState
    @State private var departure = Date().addingTimeInterval(3600)
    @State private var expanded = false

    init(state: VehicleState) {
        self.state = state
    }

    /// The date picker refuses any earlier date, so a panel left open past the chosen departure
    /// would keep computing a verdict for a time that has already passed.
    private var departureIsPast: Bool { departure < Date() }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                DatePicker(L10n.text("Departure"), selection: $departure, in: Date()...,
                           displayedComponents: .hourAndMinute)
                    .datePickerStyle(.compact)
                Text(departureIsPast
                     ? L10n.text("That departure time has passed. Pick a new one to check readiness.")
                     : VehicleReadiness.chargingByDeparture(state, departure: departure))
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Text(state.chargingEstimateDestination).font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 6)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.clock")
                    .hisType(.subhead, weight: .semibold)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(L10n.text("Check charging before departure"))
                    .hisType(.subhead, weight: .semibold)
                    .foregroundStyle(HisingenTheme.ink)
                Spacer()
            }
        }
        .disclosureGroupStyle(WholeRowDisclosureStyle())
        .padding(.vertical, 3)
    }
}
