import SwiftUI

@MainActor
struct NowInstrument: View {
    let state: VehicleState
    let imageCache: CarImageCache
    let commandGate: ControlsCommandGate
    var feedback: RemoteCommandFeedback? = nil
    var onAuthorizeRemoteCommands: (() -> Void)? = nil
    var showsDepartureCheck = false
    var showsWeather = false

    @Environment(\.preferencesStore) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var cardsShown = false

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
        return state.activeVerdict
    }

    private var modelName: String { state.identity.modelName ?? state.model.displayName }

    private var ageLine: String {
        L10n.format("Checked %@", Format.relativeAge(since: state.fetchedAt))
    }

    static func readingAge(_ reading: VehicleReading, in state: VehicleState, now: Date = Date()) -> String? {
        guard let reportedAt = state.reportedDate(for: reading) else {
            return L10n.text("Reading time unknown")
        }
        let age = now.timeIntervalSince(reportedAt)
        guard age >= -60 else { return L10n.text("Reading time unknown") }
        guard state.freshness.isCached || age > 600 || state.fetchedAt.timeIntervalSince(reportedAt) > 120 else {
            return nil
        }
        return L10n.format("Reported %@", Format.relativeAge(since: reportedAt, now: now))
    }

    /// The one reading age every figure and control shares, when they agree. Said once beside
    /// the freshness line instead of under each value; a reading that differs keeps its own line.
    private var sharedReadingAge: String? {
        var readings: [VehicleReading] = [.locks, .climateStatus]
        if state.powertrain.hasElectricRange { readings += [.battery, .charging] }
        readings.append(.range)
        let ages = Set(readings.map { Self.readingAge($0, in: state) ?? "" })
        guard ages.count == 1, let only = ages.first, !only.isEmpty else { return nil }
        return only
    }

    private func ownAge(_ reading: VehicleReading) -> String? {
        let age = Self.readingAge(reading, in: state)
        return age == sharedReadingAge ? nil : age
    }

    static func quickCommand(_ identifier: String) -> Bool {
        ["lock", "unlock", "start-climate", "stop-climate", "start-charge-override", "stop-charge-override",
         "set-charge-target", "set-amp-limit"]
            .contains(identifier)
    }

    private var inlineFeedback: RemoteCommandFeedback? {
        guard let feedback, let identifier = feedback.commandIdentifier, Self.quickCommand(identifier),
              feedback.targetVIN?.caseInsensitiveCompare(state.identity.vin) == .orderedSame else { return nil }
        return feedback
    }

    private var attentionMessage: VehicleStateSummary? {
        let summary = state.stateSummary
        guard summary.severity == .critical || summary.severity == .warning else { return nil }
        // The lock control already shows the warning and offers the recovery.
        guard summary.message != L10n.text("Unlocked"), summary.message != status else { return nil }
        return summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if typeSize.isAccessibilitySize {
                readings(alignment: .leading, spread: false)
            } else {
                energyBlock
            }
            if state.powertrain.hasElectricRange { chargeLine }
            quickStatusStrip
            if let inlineFeedback {
                ControlsBanners(state: state, feedback: inlineFeedback, features: [],
                                isBrandVolvo: state.model.brand == .volvo, showRestrictedNotice: false,
                                showsVehicleOffline: false,
                                onAuthorizeRemoteCommands: onAuthorizeRemoteCommands,
                                onFollowUp: commandGate.send)
            }
            if showsDepartureCheck, state.powertrain.hasElectricRange {
                PanelRule()
                DepartureCheckDisclosure(state: state)
            }
            if typeSize.isAccessibilitySize { profile(height: 116) }
        }
        .padding(.horizontal, inset)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        return layout {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .hisType(.display)
                    .foregroundStyle(HisingenTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if title.range(of: modelName, options: .caseInsensitive) == nil {
                    Text(modelName)
                        .hisType(.subhead)
                        .foregroundStyle(HisingenTheme.inkMuted)
                }
                freshnessLabel
                if let status {
                    Text(status)
                        .hisType(.subhead)
                        .foregroundStyle(showsLastReading ? HisingenTheme.semanticWarning : HisingenTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(reduceMotion ? .identity : .opacity)
                }
                if let attentionMessage {
                    Label(attentionMessage.message, systemImage: attentionSymbol(for: attentionMessage))
                        .hisType(.subhead)
                        .foregroundStyle(attentionMessage.severity == .critical
                                         ? HisingenTheme.semanticCritical : HisingenTheme.semanticWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsWeather, preferences.features.contains(.vehicleWeather) {
                NowWeatherButton(state: state)
            }
        }
    }

    private func attentionSymbol(for summary: VehicleStateSummary) -> String {
        if summary.severity == .critical { return "exclamationmark.octagon.fill" }
        if state.exteriorStatus?.itemsNeedingAttention == [.tailgate] { return "car.side.rear.open" }
        return "exclamationmark.triangle.fill"
    }

    /// The car on Polestar's studio stage: one flat #EFEFEF field, no frame, no shadow.
    private func profile(height: CGFloat) -> some View {
        // Straight on the canvas: the render's own shadow grounds the car.
        InstrumentVehicleProfile(state: state, imageCache: imageCache, height: height, fillsWidth: true)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
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
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))

        return layout {
            ForEach(order, id: \.self) { part in
                switch part {
                case .readings:
                    readings(alignment: alignment, spread: stacked && !typeSize.isAccessibilitySize)
                        .layoutPriority(1)
                case .profile:
                    profile(height: condensed ? 128 : min(196, HisingenTheme.layoutWidth * 0.30))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func readings(alignment: HorizontalAlignment, spread: Bool) -> some View {
        let showsBattery = state.powertrain.hasElectricRange
        let first = preferences.nowFirstReading
        let battery = figure(batteryText, unit: "%", size: condensed ? 44 : 54,
                             label: L10n.text("Battery"), reading: .battery, alignment: alignment)
            .frame(maxWidth: spread ? .infinity : nil, alignment: .leading)
        let range = figure(rangeParts.value, unit: rangeParts.unit,
                           size: spread || !showsBattery ? (condensed ? 44 : 54) : 32,
                           label: L10n.text("Estimated Range"), reading: .range, alignment: alignment)
            .frame(maxWidth: spread ? .infinity : nil, alignment: .leading)
        let layout = spread
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            : AnyLayout(VStackLayout(alignment: alignment, spacing: 8))

        return layout {
            if showsBattery && first == .battery { battery }
            range
            if showsBattery && first == .range { battery }
        }
    }

    private func figure(_ value: String, unit: String, size: CGFloat, label: String, reading: VehicleReading,
                        alignment: HorizontalAlignment) -> some View {
        let age = value == "–" ? nil : ownAge(reading)
        return VStack(alignment: alignment, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .hisType(size: size, relativeTo: .largeTitle)
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .opacity : .numericText())
                    .animation(reduceMotion ? nil : Motion.telemetry, value: value)
                if value != "–" {
                    Text(unit)
                        .hisType(size: max(14, size * 0.40), relativeTo: .title3)
                        .foregroundStyle(HisingenTheme.inkMuted)
                }
            }
            .foregroundStyle(HisingenTheme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Text(label)
                .hisType(.subhead)
                .foregroundStyle(HisingenTheme.inkMuted)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let age {
                Text(age)
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue([value == "–" ? L10n.text("Unavailable") : "\(value) \(unit)", age].compactMap { $0 }.joined(separator: ", "))
    }

    private var chargeLine: some View {
        EnergyLine(level: state.energy.batteryPercentage, target: state.energy.targetPercentage.map(Double.init),
                   isCharging: state.isCharging && state.hasFreshReading(.charging),
                   isHistorical: showsLastReading || !state.hasFreshReading(.battery))
    }

    /// The reader's chosen controls that this car and their feature switches can actually use.
    private var visibleQuickControls: [NowQuickControl] {
        NowQuickControl.applicable(
            preferences.nowQuickControls,
            features: preferences.features.enabled,
            hasElectricRange: state.powertrain.hasElectricRange,
            profile: state.capabilityProfile,
            supportsTrunkControl: state.otaCapabilities?.supportsTrunkControl == true
        )
    }

    @ViewBuilder
    private func quickControlCard(_ control: NowQuickControl) -> some View {
        switch control {
        case .locks: doorsControl
        case .climate: climateControl
        case .charging: chargingControl
        case .chargeLimit: chargeLimitControl
        case .currentLimit: currentLimitControl
        case .airCleaning: airCleaningControl
        case .windows: windowsControl
        case .locate: locateControl
        case .tailgate: tailgateControl
        }
    }

    private var quickStatusStrip: some View {
        let controls = visibleQuickControls
        // Three across at most; four sit two by two so no card is left alone on a row.
        let columns = typeSize.isAccessibilitySize ? 1 : (controls.count == 4 ? 2 : max(1, min(3, controls.count)))
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: columns),
            alignment: .leading, spacing: 8
        ) {
            ForEach(Array(controls.enumerated()), id: \.element) { index, control in
                quickControlCard(control)
                    .opacity(cardsShown ? 1 : 0)
                    // A short stagger so the cards arrive in reading order. Capped, so a long
                    // selection does not keep the last card waiting.
                    .animation(
                        Motion.resolveCrossfade(Motion.entrance.delay(Double(min(index, 5)) * 0.04)),
                        value: cardsShown
                    )
                    .transition(.opacity)
            }
        }
        .onAppear { cardsShown = true }
        .hisAnimation(Motion.cardChange, value: controls)
    }

    private var airCleaningControl: some View {
        let cleaning = state.airQuality?.cleaningState
        let command: RemoteCommand = cleaning == .on ? .stopPreCleaning : .startPreCleaning
        return quickControl(
            symbol: "aqi.medium",
            name: L10n.text("Air Cleaning"),
            value: cleaning.map { $0 == .on ? L10n.text("On") : L10n.text("Off") } ?? L10n.text("Unavailable"),
            reading: .airQuality, hasReading: cleaning != nil,
            activity: cleaning == .on && state.hasFreshReading(.airQuality) ? .running : nil,
            action: command.title(temperatureUnit: preferences.temperatureUnit),
            command: command
        )
    }

    private var windowsControl: some View {
        let states = state.exteriorStatus?.windowStates ?? []
        let open = states.filter { $0 == .open || $0 == .ajar }.count
        let value: String = {
            if states.isEmpty { return L10n.text("Unavailable") }
            if open == 0 { return L10n.text("Windows Closed") }
            if open == states.count { return L10n.text("Windows Open") }
            return L10n.format("%1$d of %2$d windows open", open, states.count)
        }()
        return quickControl(
            symbol: "car.window.left",
            name: L10n.text("Windows"),
            value: value,
            reading: .openings, hasReading: !states.isEmpty,
            valueIsWarning: open > 0 && state.hasFreshReading(.openings),
            action: RemoteCommand.closeWindows.title(temperatureUnit: preferences.temperatureUnit),
            command: .closeWindows
        )
    }

    private var locateControl: some View {
        let mode = state.otaCapabilities?.honkFlashMode
        let command: RemoteCommand = (mode?.permits(.honkAndFlash) ?? true) ? .honkAndFlash : .flashLights
        return quickControl(
            symbol: "light.beacon.max",
            name: L10n.text("Honk & Flash"),
            value: "",
            reading: .location, hasReading: false,
            action: command.title(temperatureUnit: preferences.temperatureUnit),
            command: command
        )
    }

    private var tailgateControl: some View {
        let isOpen = state.exteriorStatus?.isTailgateOpen
        let command: RemoteCommand = isOpen == true ? .closeTailgate : .openTailgate
        return quickControl(
            symbol: "car.side.rear.open",
            name: L10n.text("Tailgate"),
            value: isOpen.map { $0 ? L10n.text("Open") : L10n.text("Closed") } ?? L10n.text("Unavailable"),
            reading: .openings, hasReading: isOpen != nil,
            valueIsWarning: isOpen == true && state.hasFreshReading(.openings),
            action: command.title(temperatureUnit: preferences.temperatureUnit),
            command: command
        )
    }

    private var freshnessLabel: some View {
        let lines = [ageLine, sharedReadingAge].compactMap { $0 }
        return Text(lines.joined(separator: " · "))
            .hisType(.label)
            .monospacedDigit()
            .foregroundStyle(HisingenTheme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(lines.joined(separator: ", "))
    }

    private var doorsControl: some View {
        let locked = state.exteriorStatus?.isLocked
        return quickControl(
            symbol: locked == false ? "lock.open" : "lock",
            name: L10n.text("Locks"),
            value: locked.map { $0 ? L10n.text("Locked") : L10n.text("Unlocked") } ?? L10n.text("Unavailable"),
            reading: .locks, hasReading: locked != nil,
            valueIsWarning: locked == false && state.hasFreshReading(.locks),
            action: locked == true ? L10n.text("Unlock") : L10n.text("Lock"),
            command: locked == true ? .unlock : .lock
        )
    }

    private var rearSeatsSet: Bool {
        preferences.remoteRearLeftSeatHeating != .unspecified || preferences.remoteRearRightSeatHeating != .unspecified
    }

    private var climateRunning: Bool { state.isClimateActive && state.hasFreshReading(.climateStatus) }

    /// The car's own remaining time with the moment it said so, which the card counts down from.
    private var climateCountdown: CardCountdownSource? {
        guard climateRunning, let minutes = state.climateStatus?.timeRemainingMinutes, minutes > 0,
              let reportedAt = state.reportedDate(for: .climateStatus) else { return nil }
        return CardCountdownSource(minutes: minutes, reportedAt: reportedAt)
    }

    private var climateControl: some View {
        let command: RemoteCommand = state.isClimateActive
            ? .stopClimate
            // The same command Plan's climate settings describe: the saved temperature, seats and
            // wheel, with rear seats only when one was set. Plan no longer has its own start.
            : .startClimate(
                temperatureCelsius: Float(preferences.remoteClimateTemperature),
                frontLeftSeat: preferences.remoteDriverSeatHeating,
                frontRightSeat: preferences.remoteFrontRightSeatHeating,
                rearLeftSeat: rearSeatsSet ? preferences.remoteRearLeftSeatHeating : .unspecified,
                rearRightSeat: rearSeatsSet ? preferences.remoteRearRightSeatHeating : .unspecified,
                steeringWheel: preferences.remoteSteeringWheelHeating
            )
        return quickControl(
            symbol: "fan",
            name: L10n.text("Climate"),
            value: state.climateStatus?.activity.displayName ?? L10n.text("Unavailable"),
            reading: .climateStatus, hasReading: state.climateStatus != nil,
            activity: climateRunning ? .running : nil,
            symbolMotion: climateRunning ? .spin : .still,
            countdown: climateCountdown,
            action: state.isClimateActive ? L10n.text("Stop Climate") : L10n.text("Start Climate"),
            command: command
        )
    }

    private var chargingControl: some View {
        let overriding = state.energy.chargeNowActive == true
        // There is no plain "stop charging" command, only the schedule override. A car that is
        // already charging on its own schedule has nothing to offer here; one charging because of
        // an override offers to hand control back to the schedule.
        // Nor can a car without a cable start charging: Charge Now waits for a plug. Judged on the
        // same reported cable state the card writes, so the verb never contradicts the value.
        let unplugged = state.energy.connection == .disconnected
        let hasAction = overriding
            || (state.energy.chargingState != .complete && !unplugged
                && !(state.isCharging && state.hasFreshReading(.charging)))
        let status = state.energy.connection == .disconnected && state.energy.chargingState == .idle
            ? L10n.text("Cable disconnected")
            : state.energy.chargingState.displayName
        return quickControl(
            symbol: "bolt",
            name: L10n.text("Charging"),
            value: status,
            reading: .charging, hasReading: state.energy.connection != .unknown || state.energy.chargingState.isRecognised,
            activity: state.isCharging && state.hasFreshReading(.charging) ? .live : nil,
            symbolMotion: state.isCharging && state.hasFreshReading(.charging) ? .breathe : .still,
            action: hasAction ? (overriding ? L10n.text("Resume Schedule") : L10n.text("Charge Now")) : nil,
            command: overriding ? .stopChargingOverride : .startChargingOverride
        )
    }

    private var chargeBounds: VehicleChargeBounds { VehicleChargeBounds(capabilities: state.otaCapabilities) }

    private var chargeLimitControl: some View {
        let current = state.energy.targetPercentage.flatMap { $0 > 0 ? $0 : nil }
        return limitControl(
            symbol: "battery.75percent",
            name: L10n.text("Charge Limit"),
            unit: "%", range: chargeBounds.targetRange, current: current,
            queued: state.energy.diagnostics?.unappliedTargetPercentage(current: current),
            format: { Format.percent(Double($0)) },
            command: { .setChargeTarget($0) }
        )
    }

    private var currentLimitControl: some View {
        let current = state.energy.currentLimitAmps.flatMap { $0 > 0 ? $0 : nil }
        return limitControl(
            symbol: "gauge.with.dots.needle.bottom.100percent",
            name: L10n.text("Current Limit"),
            unit: "A", range: chargeBounds.amperageRange, current: current,
            queued: state.energy.diagnostics?.unappliedLimitAmps(current: current),
            format: Format.amps,
            command: { .setAmpLimit($0) }
        )
    }

    private func limitControl(
        symbol: String,
        name: String,
        unit: String,
        range: ClosedRange<Int>,
        current: Int?,
        queued: Int?,
        format: (Int) -> String,
        command: @escaping (Int) -> RemoteCommand
    ) -> some View {
        // Step from the queued value so repeated presses advance before the car applies them.
        let base = queued ?? current
        let press = base.map { LimitStepping.pressed($0, within: range, step: preferences.nowLimitStep) }
        let note = queued.map { L10n.format("%@ queued · applies when the car wakes", format($0)) }
            ?? (base.map { $0 >= range.upperBound } == true ? L10n.text("Maximum") : nil)
        let action = press.map {
            $0.restarts
                ? L10n.format("Lower to %@", format($0.value))
                : L10n.format("Raise to %@", format($0.value))
        }
        return quickControl(
            symbol: symbol,
            name: name,
            value: current.map(format) ?? L10n.text("Unavailable"),
            reading: .charging, hasReading: current != nil,
            note: note,
            entry: current.map {
                LimitEntry(title: name, unit: unit, range: range, current: $0,
                           rangeText: L10n.format("From %1$@ to %2$@", format(range.lowerBound), format(range.upperBound)),
                           command: command)
            },
            action: action,
            command: command(press?.value ?? base ?? range.upperBound)
        )
    }

    @ViewBuilder
    private func quickControl(
        symbol: String,
        name: String,
        value: String,
        reading: VehicleReading,
        hasReading: Bool,
        activity: CardActivity? = nil,
        symbolMotion: CardSymbol.Kind = .still,
        countdown: CardCountdownSource? = nil,
        note: String? = nil,
        entry: LimitEntry? = nil,
        valueIsWarning: Bool = false,
        action: String?,
        command: RemoteCommand
    ) -> some View {
        let valueColor = valueIsWarning && activity == nil ? HisingenTheme.semanticWarning : (activity?.foreground ?? HisingenTheme.ink)
        let age = hasReading ? ownAge(reading) : nil
        let awaiting = state.commandState.receipts.contains {
            $0.status.isAwaiting && $0.command?.descriptor.proofReading == reading
        }
        let detail = awaiting ? L10n.text("Command sent: waiting for the vehicle") : (note ?? age)
        let remainingNow = countdown.flatMap {
            ClimateCountdown.minutesRemaining(reported: $0.minutes, at: $0.reportedAt, now: Date())
        }
        let spoken = [value, remainingNow.map { L10n.format("%d min remaining", $0) }, age].compactMap { $0 }.joined(separator: ", ")
        if let action {
            let availability = commandGate.availability(command)
            let sending = commandGate.isSending(command)
            let commandTitle = command.title(temperatureUnit: preferences.temperatureUnit)
            let visibleAction = sending ? L10n.text("Sending…") : action
            Button {
                commandGate.send(command)
            } label: {
                quickControlLabel(
                    symbol: symbol, name: name, value: value, valueColor: valueColor,
                    detail: detail, action: visibleAction,
                    actionColor: activity.map { availability.isAvailable ? $0.foreground : $0.secondary }
                        ?? (availability.isAvailable ? HisingenTheme.ink : HisingenTheme.inkMuted),
                    sending: sending, activity: activity,
                    symbolMotion: symbolMotion, waiting: awaiting, countdown: countdown
                )
            }
            .buttonStyle(.pressable)
            .focusEffectDisabled()
            .disabled(!availability.isAvailable)
            .help(availability.shortReason ?? commandTitle)
            .accessibilityLabel(sending ? visibleAction : commandTitle)
            .accessibilityValue([spoken, awaiting ? detail : nil].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint(availability.shortReason ?? "")
            .overlay(alignment: .bottomTrailing) {
                if let entry {
                    LimitEntryButton(
                        entry: entry, isAvailable: availability.isAvailable,
                        color: activity?.secondary ?? HisingenTheme.inkMuted, send: commandGate.send
                    )
                    .padding(6)
                }
            }
        } else {
            quickControlLabel(symbol: symbol, name: name, value: value, valueColor: valueColor, detail: detail,
                              activity: activity, symbolMotion: symbolMotion, waiting: awaiting,
                              countdown: countdown)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(name)
                .accessibilityValue([spoken, awaiting ? detail : nil].compactMap { $0 }.joined(separator: ", "))
        }
    }

    /// A control card: the subject and its symbol, the state, then the verb with an arrow at the
    /// foot. Square and flat on the studio fill, so the cards read as part of the same stage as
    /// the car above them. The whole card is the control.
    private func quickControlLabel(
        symbol: String, name: String, value: String, valueColor: Color,
        detail: String? = nil, action: String? = nil, actionColor: Color = HisingenTheme.inkMuted, sending: Bool = false,
        activity: CardActivity? = nil,
        symbolMotion: CardSymbol.Kind = .still,
        waiting: Bool = false,
        countdown: CardCountdownSource? = nil
    ) -> some View {
        let secondary = activity?.secondary ?? HisingenTheme.inkMuted
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 4) {
                Text(name)
                    .hisType(.label)
                    .foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 2)
                if sending {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(secondary)
                        .accessibilityHidden(true)
                } else {
                    CardSymbol(name: symbol, kind: symbolMotion, waiting: waiting, color: secondary)
                }
            }
            if !value.isEmpty {
                Text(value)
                    .hisType(.title)
                    .foregroundStyle(valueColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .hisAnimation(Motion.stateChange, value: value)
            }
            if let countdown {
                CardCountdown(minutes: countdown.minutes, reportedAt: countdown.reportedAt, color: secondary)
            }
            if let detail {
                Text(detail)
                    .hisType(.label)
                    .foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let action {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(action)
                        .hisType(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    if !sending {
                        Image(systemName: "arrow.right")
                            .hisSymbolSize(10)
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(actionColor)
                .padding(.top, 6)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 56 : 96, maxHeight: .infinity,
               alignment: .topLeading)
        .background(activity?.fill ?? HisingenTheme.palette.studioFill)
        .hisAnimation(Motion.stateChange, value: activity)
        .contentShape(Rectangle())
    }
}

/// The car's reported time remaining and when it reported it, so a card can count down.
struct CardCountdownSource: Equatable {
    let minutes: Int
    let reportedAt: Date
}

/// A control card's live state: a running climate or air-cleaning session, or a charge. Every
/// kind fills with the theme's ``Palette/activeFill`` and writes on it in ``Palette/activeOn``, so
/// active controls follow the reader's theme. The state is always written on the card as well.
enum CardActivity: Equatable {
    case running
    case live

    @MainActor var fill: Color { HisingenTheme.palette.activeFill }
    @MainActor var foreground: Color { HisingenTheme.palette.activeOn }
    @MainActor var secondary: Color { foreground.opacity(0.78) }
}

@MainActor
struct InstrumentVehicleProfile: View {
    let state: VehicleState
    let imageCache: CarImageCache
    let height: CGFloat
    var fillsWidth = false

    @Environment(\.preferencesStore) private var preferences

    var body: some View {
        let vin = state.identity.vin
        let angle = preferences.carRenderAngle.rawValue
        let data = state.identity.imageData ?? imageCache.image(for: vin, angle: angle) ?? imageCache.image(for: vin)

        Group {
            if let data {
                VehiclePresentationView(identity: .init(vin: vin, angle: angle), imageData: data,
                                        fitHeight: height, fillsInstrumentWidth: fillsWidth)
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
