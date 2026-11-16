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
                symbol: "lock.open",
                value: L10n.format("%d Open", openCount),
                label: L10n.text("Doors & Openings"),
                tint: HisingenTheme.semanticWarning
            )
        } else if let locked = ext.isLocked {
            row = DashboardRow(
                symbol: locked ? "lock" : "lock.open",
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
            symbol = "fuelpump"
            // The fuel card warned below 12 %; the row keeps exactly that threshold.
            tint = level <= 12 ? HisingenTheme.semanticWarning : HisingenTheme.ink
            if let range = state.fuelSystem.rangeKm {
                value = "\(String(format: "%.0f%%", locale: L10n.displayLocale, level)) · \(Format.distance(km: range, unit: distanceUnit))"
            } else {
                value = String(format: "%.0f%%", locale: L10n.displayLocale, level)
            }
        } else if let running {
            symbol = "engine.combustion"
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
struct DepartureCheckDisclosure: View {
    let state: VehicleState
    @State private var selectedDeparture: Date?
    @State private var expanded = false

    init(state: VehicleState) {
        self.state = state
    }

    private var scheduledDeparture: Date? {
        PlanTimeline.entries(for: state).first { $0.schedule.kind == .departure }?.next
    }

    private var departure: Binding<Date> {
        Binding(get: { selectedDeparture ?? scheduledDeparture ?? Date().addingTimeInterval(3600) },
                set: { selectedDeparture = $0 })
    }

    var body: some View {
        let assessment = VehicleReadiness.assessDeparture(state, departure: departure.wrappedValue)
        let showSummary = scheduledDeparture != nil || selectedDeparture != nil
            || (state.energy.connection == .disconnected && state.hasFreshReading(.charging))
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                DatePicker(L10n.text("Departure"), selection: departure, in: Date()...,
                           displayedComponents: .hourAndMinute)
                    .datePickerStyle(.compact)
                if let target = state.energy.targetPercentage {
                    Text(L10n.format("Target %d%%", target)).hisType(.label)
                }
                if let destination = assessment.estimateDestination {
                    Text(destination).hisType(.label).foregroundStyle(.secondary)
                }
                Text(assessment.message)
                    .hisType(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.top, 6)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.clock")
                    .hisType(.subhead, weight: .semibold)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Check charging before departure"))
                        .hisType(.subhead, weight: .semibold)
                        .foregroundStyle(HisingenTheme.ink)
                    if showSummary && !expanded {
                        Text(assessment.message)
                            .hisType(.label)
                            .foregroundStyle(HisingenTheme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
        }
        .disclosureGroupStyle(WholeRowDisclosureStyle())
        .padding(.vertical, 3)
    }
}
