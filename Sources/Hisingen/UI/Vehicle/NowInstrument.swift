import SwiftUI

@MainActor
struct NowInstrument: View {
    let state: VehicleState
    let imageCache: CarImageCache
    let commandGate: ControlsCommandGate

    @Environment(\.preferencesStore) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.layoutDirection) private var layoutDirection

    private var condensed: Bool { HisingenTheme.layoutWidth < 540 }
    private var inset: CGFloat { HisingenTheme.cardPadding }
    private var showsLastReading: Bool {
        state.freshness.isCached || state.hasOldData() || !state.freshness.retainedDataCategories.isEmpty
    }

    private var title: String {
        if preferences.privacyRedactionEnabled {
            return state.identity.modelName ?? state.model.displayName
        }
        return preferences.formattedVehicleTitle(
            vin: state.identity.vin,
            modelName: state.identity.modelName,
            modelYear: state.identity.modelYear,
            registrationNo: state.identity.registrationNo,
            fallbackBrand: state.model.brand
        )
    }

    private var batteryText: String {
        state.energy.batteryPercentage.map { String(format: "%.0f", locale: L10n.displayLocale, $0) } ?? "–"
    }

    private var rangeParts: Format.DistanceParts {
        state.primaryRangeKm.map { Format.distanceParts(km: $0, unit: preferences.distanceUnit) }
            ?? Format.DistanceParts(value: "–", unit: preferences.distanceUnit.suffix)
    }

    private var status: String? {
        if state.freshness.isCached { return L10n.text("Showing an offline copy") }
        if showsLastReading { return L10n.text("Last known readings") }
        if case .unavailable = state.identity.availability { return state.identity.availability.displayName }
        return state.activeVerdict ?? state.identity.usageModeDisplayName
    }

    private var ageLine: String {
        let updated = L10n.format("Updated %@", Format.relativeAge(since: state.dataTimestamp))
        guard showsLastReading, state.vehicleReportedAt != nil else { return updated }
        return L10n.format("%@ · Checked %@", updated, Format.relativeAge(since: state.fetchedAt))
    }

    private var attentionMessage: VehicleStateSummary? {
        let summary = state.stateSummary
        guard summary.severity == .critical || summary.severity == .warning else { return nil }
        // The lock control already shows the warning and offers the recovery.
        guard summary.message != L10n.text("Unlocked"), summary.message != status else { return nil }
        return summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 12)

            energyBlock

            if state.powertrain.hasElectricRange {
                chargeLine
                    .padding(.top, 10)
            }

            quickStatusStrip
                .padding(.top, 18)
        }
        .padding(.horizontal, inset)
        .padding(.top, 10)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .hisType(.displaySmall, weight: .semibold)
                .foregroundStyle(HisingenTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            if let status {
                Text(status)
                    .hisType(.body, weight: .semibold)
                    .foregroundStyle(showsLastReading ? HisingenTheme.semanticWarning : HisingenTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(reduceMotion ? .identity : .opacity)
            }

            if let attentionMessage {
                Label(attentionMessage.message, systemImage: attentionSymbol(for: attentionMessage))
                    .hisType(.body, weight: .semibold)
                    .foregroundStyle(attentionMessage.severity == .critical
                                     ? HisingenTheme.semanticCritical : HisingenTheme.semanticWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func attentionSymbol(for summary: VehicleStateSummary) -> String {
        if summary.severity == .critical { return "exclamationmark.octagon.fill" }
        if state.exteriorStatus?.itemsNeedingAttention == [.tailgate] { return "car.side.rear.open.fill" }
        return "exclamationmark.triangle.fill"
    }

    private var profile: some View {
        InstrumentVehicleProfile(state: state, imageCache: imageCache,
                                 height: condensed ? 144 : 194)
    }

    private enum EnergyBlockPart: Hashable {
        case readings, profile
    }

    private var energyBlock: some View {
        let position = preferences.nowReadingsPosition
        let stacked = typeSize.isAccessibilitySize || position == .above || position == .below
        let reverseSides = !stacked && layoutDirection == .rightToLeft
        let readingsFirst = (position == .left || position == .above) != reverseSides
        let order: [EnergyBlockPart] = readingsFirst ? [.readings, .profile] : [.profile, .readings]
        let alignment: HorizontalAlignment = stacked || readingsFirst ? .leading : .trailing
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))

        return layout {
            ForEach(order, id: \.self) { part in
                switch part {
                case .readings:
                    readings(alignment: alignment).layoutPriority(1)
                case .profile:
                    profile
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func readings(alignment: HorizontalAlignment) -> some View {
        let showsBattery = state.powertrain.hasElectricRange
        let first = preferences.nowFirstReading
        let battery = figure(batteryText, unit: "%", size: condensed ? 48 : 58,
                             label: L10n.text("Battery"), alignment: alignment)

        return VStack(alignment: alignment, spacing: 8) {
            if showsBattery && first == .battery { battery }
            figure(rangeParts.value, unit: rangeParts.unit,
                   size: showsBattery ? (condensed ? 24 : 29) : 42,
                   label: L10n.text("Estimated Range"), alignment: alignment)
            if showsBattery && first == .range { battery }
        }
    }

    private func figure(_ value: String, unit: String, size: CGFloat, label: String,
                        alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .hisType(size: size, relativeTo: .largeTitle, weight: .light)
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .opacity : .numericText())
                    .animation(reduceMotion ? nil : Motion.telemetry, value: value)
                if value != "–" {
                    Text(unit)
                        .hisType(size: max(13, size * 0.34), relativeTo: .title3)
                        .foregroundStyle(HisingenTheme.inkMuted)
                }
            }
            .foregroundStyle(HisingenTheme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            Text(label)
                .hisType(.label)
                .foregroundStyle(HisingenTheme.inkMuted)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value == "–" ? L10n.text("Unavailable") : "\(value) \(unit)")
    }

    private var chargeLine: some View {
        VStack(alignment: .trailing, spacing: 4) {
            EnergyLine(level: state.energy.batteryPercentage, target: state.energy.targetPercentage.map(Double.init),
                       isCharging: state.isCharging && !showsLastReading, isHistorical: showsLastReading)

            if let target = state.energy.targetPercentage {
                Text(L10n.format("Target %d%%", target))
                    .hisType(.label, weight: .medium)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }
        }
    }

    private var quickStatusStrip: some View {
        let hasCharging = state.powertrain.hasElectricRange
        let count = hasCharging ? 4 : 3
        let columns = condensed || typeSize.isAccessibilitySize ? 2 : count
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 0, alignment: .top), count: columns),
            spacing: 10
        ) {
            stripCell(index: 0, count: count, columns: columns) { doorsControl }
            stripCell(index: 1, count: count, columns: columns) { climateControl }
            if hasCharging {
                stripCell(index: 2, count: count, columns: columns) { chargingControl }
            }
            stripCell(index: count - 1, count: count, columns: columns) { freshnessCell }
        }
    }

    private func stripCell<Content: View>(
        index: Int, count: Int, columns: Int, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .top)
            .overlay(alignment: .trailing) {
                if index < count - 1 && (index + 1) % columns != 0 {
                    Rectangle()
                        .fill(HisingenTheme.hairline)
                        .frame(width: 1)
                        .padding(.vertical, 4)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
    }

    private var freshnessCell: some View {
        VStack(spacing: 5) {
            stripGlyph("clock.arrow.circlepath")
            Text(ageLine)
                .hisType(.label, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(HisingenTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 5)
        .help(ageLine)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Last Updated"))
        .accessibilityValue(ageLine)
    }

    private var doorsControl: some View {
        let locked = state.exteriorStatus?.isLocked
        return quickControl(
            symbol: locked == false ? "lock.open.fill" : "lock.fill",
            name: L10n.text("Locks"),
            value: locked.map { $0 ? L10n.text("Locked") : L10n.text("Unlocked") } ?? L10n.text("Unavailable"),
            valueIsWarning: locked == false && !showsLastReading,
            action: locked == true ? L10n.text("Unlock") : L10n.text("Lock"),
            command: locked == true ? .unlock : .lock
        )
    }

    private var climateControl: some View {
        let command: RemoteCommand = state.isClimateActive
            ? .stopClimate
            : .startClimate(
                temperatureCelsius: Float(preferences.remoteClimateTemperature),
                frontLeftSeat: .off, frontRightSeat: .off,
                rearLeftSeat: .off, rearRightSeat: .off,
                steeringWheel: .off
            )
        return quickControl(
            symbol: "fan.fill",
            name: L10n.text("Climate"),
            value: state.climateStatus?.activity.displayName ?? L10n.text("Unavailable"),
            action: state.isClimateActive ? L10n.text("Stop Climate") : L10n.text("Start Climate"),
            command: command
        )
    }

    private var chargingControl: some View {
        let overriding = state.energy.chargeNowActive == true
        let hasAction = overriding || state.energy.chargingState != .complete
        return quickControl(
            symbol: "bolt.fill",
            name: L10n.text("Charging"),
            value: state.energy.chargingState.displayName,
            action: hasAction ? (overriding ? L10n.text("Resume Schedule") : L10n.text("Charge Now")) : nil,
            command: overriding ? .stopChargingOverride : .startChargingOverride
        )
    }

    @ViewBuilder
    private func quickControl(
        symbol: String,
        name: String,
        value: String,
        valueIsWarning: Bool = false,
        action: String?,
        command: RemoteCommand
    ) -> some View {
        let valueColor = valueIsWarning ? HisingenTheme.semanticWarning : HisingenTheme.ink
        if let action {
            let availability = commandGate.availability(command)
            let sending = commandGate.isSending(command)
            let commandTitle = command.title(temperatureUnit: preferences.temperatureUnit)
            Button {
                commandGate.send(command)
            } label: {
                quickControlLabel(
                    symbol: symbol, value: value, valueColor: valueColor,
                    action: sending ? L10n.text("Sending…") : action,
                    actionColor: availability.isAvailable ? HisingenTheme.accent : HisingenTheme.inkMuted,
                    sending: sending
                )
            }
            .buttonStyle(.pressable)
            .focusEffectDisabled()
            .disabled(!availability.isAvailable)
            .help(availability.shortReason ?? commandTitle)
            .accessibilityLabel(sending ? L10n.text("Sending…") : commandTitle)
            .accessibilityValue(value)
            .accessibilityHint(availability.shortReason ?? "")
        } else {
            quickControlLabel(symbol: symbol, value: value, valueColor: valueColor)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(name)
                .accessibilityValue(value)
        }
    }

    private func quickControlLabel(
        symbol: String, value: String, valueColor: Color,
        action: String? = nil, actionColor: Color = HisingenTheme.inkMuted, sending: Bool = false
    ) -> some View {
        VStack(spacing: 5) {
            if sending {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            } else {
                stripGlyph(symbol)
            }
            Text(value)
                .hisType(.label, weight: .semibold)
                .foregroundStyle(valueColor)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Text(action)
                    .hisType(.caption, weight: .semibold)
                    .foregroundStyle(actionColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .top)
        .contentShape(Rectangle())
    }

    private func stripGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .hisSymbolSize(17, weight: .semibold)
            .foregroundStyle(HisingenTheme.ink)
            .accessibilityHidden(true)
    }
}

@MainActor
struct InstrumentVehicleProfile: View {
    let state: VehicleState
    let imageCache: CarImageCache
    let height: CGFloat

    @Environment(\.preferencesStore) private var preferences

    var body: some View {
        let vin = state.identity.vin
        let angle = preferences.carRenderAngle.rawValue
        let data = state.identity.imageData ?? imageCache.image(for: vin, angle: angle) ?? imageCache.image(for: vin)

        Group {
            if let data {
                VehiclePresentationView(identity: .init(vin: vin, angle: angle), imageData: data,
                                        fitHeight: height)
                    .accessibilityHidden(true)
            } else {
                VehicleSideProfileDoorsView(openings: state.exteriorStatus?.openings ?? [],
                                            model: state.model, brand: state.model.brand,
                                            profileHeight: height, instrumentAppearance: true)
                    .accessibilityLabel(L10n.format("%@ vehicle profile", state.model.displayName))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
    }
}
