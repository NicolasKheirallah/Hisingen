import SwiftUI

@MainActor
struct NowInstrument: View {
    let state: VehicleState
    let imageCache: CarImageCache
    let commandGate: ControlsCommandGate
    var feedback: RemoteCommandFeedback? = nil
    var onAuthorizeRemoteCommands: (() -> Void)? = nil
    var showsAttention = true
    var showsCommandReceipts = false
    var showsWeatherIcon = false
    var usesCompactOverview = false
    var carSectionAction: ((TabItemID) -> (() -> Void)?)? = nil
    var dismissedSoftwareEventIdentifier: String? = nil

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
        if usesCompactOverview, state.isCharging,
           visibleQuickControls.contains(.charging), state.hasFreshReading(.charging) { return nil }
        return state.activeVerdict
    }

    private var modelName: String { state.identity.modelName ?? state.model.displayName }

    private var ageLine: String {
        // The panel used to report only when Hisingen fetched. On a car whose cloud data is hours
        // old that read "Checked just now" above an odometer from the previous day, which is the
        // one line a reader trusts to judge everything below it. When the vehicle's own report is
        // materially behind the fetch, say so and give its time instead.
        guard let reportedAt = state.vehicleReportedAt,
              state.fetchedAt.timeIntervalSince(reportedAt) > Self.reportLagThreshold else {
            return L10n.format("Checked %@", Format.relativeAge(since: state.fetchedAt))
        }
        return L10n.format("Reported %@", Format.relativeAge(since: reportedAt))
    }

    /// How far the vehicle's own report may trail the fetch before the header quotes it instead
    /// of quoting the fetch. Ten minutes covers ordinary delivery lag without alarming on it.
    static let reportLagThreshold: TimeInterval = 600

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
        // Odometer, location and health are on the panel too, and providers refresh them far less
        // often than the doors. Leaving them out meant the shared line could agree on "3 hr ago"
        // while the odometer beside it was a day old.
        readings += [.range, .odometer, .location, .health]
        // A reading with no report time is not a disagreement: it has nothing to say about age.
        let ages = Set(readings.filter { state.reportedDate(for: $0) != nil }
            .map { Self.readingAge($0, in: state) ?? "" })
        guard ages.count == 1, let only = ages.first, !only.isEmpty else { return nil }
        return only
    }

    private func ownAge(_ reading: VehicleReading) -> String? {
        let age = Self.readingAge(reading, in: state)
        return age == sharedReadingAge ? nil : age
    }

    static func quickCommand(_ identifier: String) -> Bool {
        ["lock", "unlock", "start-climate", "stop-climate", "start-charge-override", "stop-charge-override",
         "set-charge-target", "set-amp-limit", "start-precleaning", "stop-precleaning", "open-windows",
         "close-windows", "honk-flash", "open-tailgate", "close-tailgate", "unlock-trunk"]
            .contains(identifier)
    }

    private var inlineFeedback: RemoteCommandFeedback? {
        guard let feedback, let identifier = feedback.commandIdentifier, Self.quickCommand(identifier),
              feedback.targetVIN?.caseInsensitiveCompare(state.identity.vin) == .orderedSame else { return nil }
        return feedback
    }

    private var attentionMessage: VehicleStateSummary? {
        let summary = state.stateSummary
        if summary.message == L10n.text("Software update failed"),
           let software = state.softwareInfo, dismissedSoftwareEventIdentifier == software.eventIdentifier { return nil }
        guard showsAttention || [L10n.text("Low battery"), L10n.text("Low fuel"), L10n.text("Charging fault")].contains(summary.message) else { return nil }
        guard summary.severity == .critical || summary.severity == .warning else { return nil }
        // The lock control already shows the warning and offers the recovery.
        guard summary.message != L10n.text("Unlocked"), summary.message != status else { return nil }
        return summary
    }

    private var featuredWarning: (title: String, detail: String?, tint: Color, destination: TabItemID?)? {
        let summary = state.stateSummary
        let tyreWarningTitle = L10n.text("Tyre pressure warning")
        let concernsTyres = [tyreWarningTitle, VehicleWarning.tyrePressure.displayName].contains(summary.message)
        if showsAttention, preferences.features.contains(.tyreAndWarnings),
           summary.severity != .critical,
           attentionMessage == nil || concernsTyres {
            let tyres = state.maintenance.details?.tyres.filter { $0.warning.needsAttention } ?? []
            if !tyres.isEmpty {
                let detail = tyres.map { "\($0.position.displayName) · \($0.warning.displayName)" }
                    .joined(separator: ", ")
                return (tyreWarningTitle, detail, HisingenTheme.semanticWarning, .infoTyres)
            }
        }
        guard let summary = attentionMessage else { return nil }
        let destination: TabItemID?
        if summary.severity == .warning, state.exteriorStatus?.itemsNeedingAttention.isEmpty == false {
            destination = .infoDoors
        } else {
            destination = nil
        }
        return (summary.message, nil, summary.severity == .critical
                ? HisingenTheme.semanticCritical : HisingenTheme.semanticWarning, destination)
    }

    @ViewBuilder
    private var warningNotice: some View {
        if let warning = featuredWarning {
            Group {
                if let destination = warning.destination, let action = carSectionAction?(destination) {
                    NavigationRow(title: warning.title, detail: warning.detail,
                                  destination: BuiltInTab.info.title, action: action)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(warning.title)
                            .hisType(.body, weight: .medium)
                            .foregroundStyle(HisingenTheme.ink)
                        if let detail = warning.detail {
                            Text(detail)
                                .hisType(.label)
                                .foregroundStyle(HisingenTheme.inkMuted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .hisNotice(warning.tint)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: usesCompactOverview ? 12 : 16) {
            header
            if usesCompactOverview { warningNotice }
            energyBlock
            if state.powertrain.hasElectricRange { chargeLine }
            quickStatusStrip
            if let inlineFeedback {
                ControlsBanners(state: state, feedback: inlineFeedback, features: [],
                                isBrandVolvo: state.model.brand == .volvo, showRestrictedNotice: false,
                                showsVehicleOffline: false,
                                showsCommandReceipts: showsCommandReceipts,
                                onAuthorizeRemoteCommands: onAuthorizeRemoteCommands,
                                onFollowUp: commandGate.send)
            }
        }
        .padding(.horizontal, inset)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            headerReadings
            if showsWeatherIcon, preferences.features.contains(.vehicleWeather),
               let weather = state.weather, weather.hasCurrentConditions {
                NowWeatherButton(state: state, weather: weather)
            }
        }
    }

    private var headerReadings: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    headerTitle
                    inlineIdentity
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 4) {
                    headerTitle
                    inlineIdentity
                }
            }
            if preferences.vehicleModelBadgePosition == .subheadline, let modelBadge {
                identityLabel(modelBadge)
            }
            let registration = preferences.registrationBadgePosition
            if registration == .belowGreeting || registration == .platePill {
                plateBadge
            }
            if preferences.features.contains(.ownerGreeting), !preferences.privacyRedactionEnabled,
               let name = state.identity.ownerFirstName, !name.isEmpty {
                Text(Format.greeting(name))
                    .hisType(.label)
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
            if !usesCompactOverview, let attentionMessage {
                Label(attentionMessage.message, systemImage: attentionSymbol(for: attentionMessage))
                    .hisType(.subhead)
                    .foregroundStyle(attentionMessage.severity == .critical
                                     ? HisingenTheme.semanticCritical : HisingenTheme.semanticWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerTitle: some View {
        Text(title)
            .hisType(.display)
            .foregroundStyle(HisingenTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private var modelBadge: String? {
        guard preferences.features.contains(.vehicleIdentity),
              title.range(of: modelName, options: .caseInsensitive) == nil else { return nil }
        return [modelName, state.identity.modelYear].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var inlineIdentity: some View {
        if preferences.vehicleModelBadgePosition == .inlineHeader, let modelBadge {
            identityLabel(modelBadge)
        }
        if preferences.registrationBadgePosition == .inlineHeader { plateBadge }
    }

    private func identityLabel(_ model: String) -> some View {
        Text(model)
            .hisType(.label)
            .foregroundStyle(HisingenTheme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var plateBadge: some View {
        if preferences.features.contains(.vehicleIdentity), !preferences.privacyRedactionEnabled,
           let plate = state.identity.registrationNo, !plate.isEmpty,
           title.range(of: plate, options: .caseInsensitive) == nil {
            LicensePlateBadge(plate: plate, style: preferences.registrationBadgePosition,
                              showsSwedishFlag: state.identity.accountMarket?.uppercased() == "SE")
        }
    }

    @ViewBuilder
    private func overlayIdentity(leading: Bool) -> some View {
        let modelPosition: VehicleModelBadgePosition = leading ? .topLeftOverlay : .topRightOverlay
        let platePosition: RegistrationNumberBadgePosition = leading ? .topLeftOverlay : .topRightOverlay
        VStack(alignment: leading ? .leading : .trailing, spacing: 4) {
            if preferences.vehicleModelBadgePosition == modelPosition, let modelBadge {
                identityLabel(modelBadge)
                    .padding(5)
                    .background(HisingenTheme.canvas)
            }
            if preferences.registrationBadgePosition == platePosition { plateBadge }
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
            .padding(.vertical, usesCompactOverview ? 0 : 6)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) { overlayIdentity(leading: true) }
            .overlay(alignment: .topTrailing) { overlayIdentity(leading: false) }
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
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: usesCompactOverview ? 10 : 16))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))

        return layout {
            ForEach(order, id: \.self) { part in
                switch part {
                case .readings:
                    readings(alignment: alignment, spread: stacked && !typeSize.isAccessibilitySize)
                        .layoutPriority(1)
                case .profile:
                    profile(height: usesCompactOverview
                            ? (condensed ? 80 : min(104, HisingenTheme.layoutWidth * 0.18))
                            : (condensed ? 128 : min(196, HisingenTheme.layoutWidth * 0.30)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func readings(alignment: HorizontalAlignment, spread: Bool) -> some View {
        let showsBattery = state.powertrain.hasElectricRange
        let first = preferences.nowFirstReading
        // Side by side, the second figure takes the trailing edge so it ends where the charge
        // line's target label ends, instead of starting at the midpoint.
        let batteryTrails = spread && showsBattery && first == .range
        let rangeTrails = spread && showsBattery && first == .battery
        let battery = figure(batteryText, unit: "%", size: condensed ? 44 : 54,
                             label: L10n.text("Battery"), reading: .battery,
                             alignment: batteryTrails ? .trailing : alignment)
            .frame(maxWidth: spread ? .infinity : nil, alignment: batteryTrails ? .trailing : .leading)
        let range = figure(rangeParts.value, unit: rangeParts.unit,
                           size: spread || !showsBattery ? (condensed ? 44 : 54) : 32,
                           label: L10n.text("Estimated Range"), reading: .range,
                           alignment: rangeTrails ? .trailing : alignment)
            .frame(maxWidth: spread ? .infinity : nil, alignment: rangeTrails ? .trailing : .leading)
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

    /// A provider with no climate-status resource has no freshness to check, so the receipt-backed
    /// activity is enough to spin the fan; the countdown below still requires a real reading.
    private var climateRunning: Bool {
        guard state.isClimateActive else { return false }
        return state.climateStatus == nil || state.hasFreshReading(.climateStatus)
    }

    /// The car's own activity word when it reports one. "Unavailable" used to stand in for
    /// "this provider cannot report climate status", which read as a missing feature while the
    /// command itself worked.
    private var climateValue: String {
        if let name = state.climateStatus?.activity.displayName { return name }
        if state.isClimateActive { return L10n.text("Running") }
        return state.capabilityProfile.permits(.climateStartStop)
            ? L10n.text("Not reported")
            : L10n.text("Unavailable")
    }

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
            value: climateValue,
            reading: .climateStatus,
            hasReading: state.climateStatus != nil || state.receiptClimateIsRunning,
            activity: climateRunning ? .running : nil,
            symbolMotion: climateRunning ? .spin : .still,
            countdown: climateCountdown,
            action: state.isClimateActive ? L10n.text("Stop Climate") : L10n.text("Start Climate"),
            command: command
        )
    }

    private var chargingControl: some View {
        let overriding = state.energy.chargeNowActive == true
        let isLive = state.isCharging && state.hasFreshReading(.charging)
        // There is no plain "stop charging" command, only the schedule override. A car that is
        // already charging on its own schedule has nothing to offer here; one charging because of
        // an override offers to hand control back to the schedule.
        // Nor can a car without a cable start charging: Charge Now waits for a plug. Judged on the
        // same reported cable state the card writes, so the verb never contradicts the value.
        let unplugged = state.energy.connection == .disconnected
        let hasAction = overriding
            || (state.energy.chargingState != .complete && !unplugged
                && !isLive)
        let status = state.energy.connection == .disconnected && state.energy.chargingState == .idle
            ? L10n.text("Cable disconnected")
            : state.energy.chargingState.displayName
        let draw = state.liveChargingDraw()
        let completion = isLive && usesCompactOverview && !state.freshness.retainedDataCategories.contains(.chargingDetails)
            ? state.estimatedChargingCompletion : nil
        let ready = completion.map { "\(L10n.text("Ready at")) \(Format.shortTime(date: $0))" }
        return quickControl(
            symbol: "bolt",
            name: L10n.text("Charging"),
            value: usesCompactOverview && isLive ? (draw ?? status) : status,
            reading: .charging, hasReading: state.energy.connection != .unknown || state.energy.chargingState.isRecognised,
            activity: isLive ? .live : nil,
            symbolMotion: isLive ? .breathe : .still,
            readout: usesCompactOverview && isLive ? nil : draw,
            note: ready,
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
            changedAt: state.energy.targetPercentageReportedAt,
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
            changedAt: state.energy.currentLimitReportedAt,
            format: Format.amps,
            command: { .setAmpLimit($0) }
        )
    }

    /// The note line under a limit stepper's value. A queued change says what is coming, the
    /// top of the range says why the verb reads "Lower", and otherwise a setting the car has
    /// not touched for over a month says when it was last set, with the same wording the
    /// charging card's rows carry. Static so tests can pin the choice without rendering.
    static func limitControlNote(
        queued: Int?, base: Int?, upperBound: Int, changedAt: Date?,
        format: (Int) -> String, now: Date = Date()
    ) -> String? {
        if let queued { return L10n.format("%@ queued · applies when the car wakes", format(queued)) }
        if base.map({ $0 >= upperBound }) == true { return L10n.text("Maximum") }
        return VehicleChargingCard.staleSettingNote(reportedAt: changedAt, now: now)
    }

    private func limitControl(
        symbol: String,
        name: String,
        unit: String,
        range: ClosedRange<Int>,
        current: Int?,
        queued: Int?,
        changedAt: Date? = nil,
        format: (Int) -> String,
        command: @escaping (Int) -> RemoteCommand
    ) -> some View {
        // Step from the queued value so repeated presses advance before the car applies them.
        let base = queued ?? current
        let press = base.map { LimitStepping.pressed($0, within: range, step: preferences.nowLimitStep) }
        let note = Self.limitControlNote(
            queued: queued, base: base, upperBound: range.upperBound,
            changedAt: changedAt, format: format
        )
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
            // One VoiceOver adjustment gesture: increment matches the card's press (a step up,
            // or the restart value at the ceiling); decrement is the same step downwards, which
            // the pointer never needed because the card only climbs.
            adjustment: { direction in
                guard let base else { return nil }
                let limitDirection: LimitStepping.Direction?
                switch direction {
                case .increment: limitDirection = .up
                case .decrement: limitDirection = .down
                @unknown default: limitDirection = nil
                }
                guard let limitDirection else { return nil }
                return LimitStepping.adjusted(base, within: range,
                                              step: preferences.nowLimitStep,
                                              direction: limitDirection)
                    .map(command)
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
        readout: String? = nil,
        countdown: CardCountdownSource? = nil,
        note: String? = nil,
        entry: LimitEntry? = nil,
        valueIsWarning: Bool = false,
        adjustment: ((AccessibilityAdjustmentDirection) -> RemoteCommand?)? = nil,
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
        let spoken = [value, readout, remainingNow.map { L10n.format("%d min remaining", $0) }, detail, note == nil ? nil : age]
            .compactMap { $0 }.joined(separator: ", ")
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
                    symbolMotion: symbolMotion, waiting: awaiting, readout: readout, countdown: countdown
                )
            }
            .buttonStyle(.pressable)
            .focusEffectDisabled()
            .disabled(!availability.isAvailable)
            .help(availability.shortReason ?? commandTitle)
            .accessibilityLabel(sending ? visibleAction : commandTitle)
            .accessibilityValue(spoken)
            .accessibilityHint(availability.shortReason ?? "")
            .accessibilityAdjustableActionIf(adjustment != nil) { direction in
                guard let next = adjustment?(direction),
                      commandGate.availability(next).isAvailable else { return }
                commandGate.send(next)
            }
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
                              readout: readout, countdown: countdown)
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
        readout: String? = nil,
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
            if let readout {
                Text(readout)
                    .hisType(.body)
                    .foregroundStyle(valueColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .hisTelemetryValue(readout, reduceMotion: reduceMotion)
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
            if preferences.features.contains(.vehicleImage), let data {
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
