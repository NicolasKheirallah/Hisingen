import SwiftUI

@MainActor
struct ControlsTabView: View {
    let state: VehicleState
    let remoteCommandInProgress: Bool
    let onRemoteCommand: (RemoteCommand) -> Void

    @State private var targetTemperature: Double = Double(Preferences.remoteClimateTemperature)
    @State private var driverSeat: HeatingLevel = Preferences.remoteDriverSeatHeating
    @State private var passengerSeat: HeatingLevel = Preferences.remoteFrontRightSeatHeating
    @State private var steeringHeating: HeatingLevel = Preferences.remoteSteeringWheelHeating
    @State private var chargeTarget: Int = 80
    @State private var ampLimit: Int = 16
    @State private var showScheduleEditor = false
    @State private var isInitialized = false

    private var isBrandVolvo: Bool { Preferences.activeBrand == .volvo }
    private var profile: VehicleCapabilityProfile { state.capabilityProfile }
    private var features: Set<AppFeature> { Preferences.features.enabled }

    /// A control is live only when all three layers agree: this app implements the command for
    /// the active brand, the vehicle's capability profile permits it, and nothing else is
    /// already in flight. Previously each button hardcoded a brand check, which meant the
    /// capability system and the actual affordance could drift apart silently.
    private func isDisabled(_ command: RemoteCommand) -> Bool {
        guard command.isImplemented(by: Preferences.activeBrand),
              profile.permits(command.requiredCapability) else { return true }
        return remoteCommandInProgress
    }

    /// Dims a whole card whose commands are unavailable on this vehicle, so "shown but inert"
    /// reads as deliberate rather than broken. Keyed off the card's representative command
    /// rather than the brand, for the same reason as `isDisabled`.
    private func cardOpacity(_ representative: RemoteCommand) -> Double {
        representative.isImplemented(by: Preferences.activeBrand)
            && profile.permits(representative.requiredCapability) ? 1.0 : 0.65
    }

    /// Stands in for the real `.startClimate` when only its gating matters — neither
    /// `isImplemented(by:)` nor `requiredCapability` looks at the associated values, and
    /// building the live one here would duplicate the picker state the button already reads.
    private static let climateProbe = RemoteCommand.startClimate(
        temperatureCelsius: 0, frontLeftSeat: .unspecified, frontRightSeat: .unspecified,
        rearLeftSeat: .unspecified, rearRightSeat: .unspecified, steeringWheel: .unspecified
    )
    private var climateActive: Bool {
        guard let status = state.climateStatus else { return false }
        return status.activity == .active || status.activity == .heating
            || status.activity == .cooling || status.activity == .ventilating
    }

    private var hasAnyVisibleChargingControls: Bool {
        guard state.powertrain.hasElectricRange else { return false }
        return (profile.permits(.chargeTarget) && features.contains(.remoteCharging)) ||
        (profile.permits(.chargingCurrentLimit) && features.contains(.remoteCharging)) ||
        (profile.permits(.chargingScheduleOverride) && (features.contains(.remoteCharging) || features.contains(.remoteSchedules)))
    }

    private var hasAnyVisibleControlCards: Bool {
        features.contains(.remoteClimate) ||
        (features.contains(.remotePreCleaning) && profile.permits(.preCleaning)) ||
        hasAnyVisibleChargingControls ||
        (state.powertrain.hasCombustionEngine && isBrandVolvo) ||
        features.contains(.remoteLocks) ||
        (features.contains(.remoteWindows) && profile.permits(.windows)) ||
        features.contains(.remoteHonkFlash) ||
        (features.contains(.remoteOTA) && profile.permits(.softwareInstallControl))
    }

    var body: some View {
        VStack(spacing: HisingenTheme.sectionSpacing) {
            restrictedNoticeBanner
            if hasAnyVisibleControlCards {
                if features.contains(.remoteClimate) || (features.contains(.remotePreCleaning) && profile.permits(.preCleaning)) {
                    climateControlCard
                }
                if state.powertrain.hasCombustionEngine && isBrandVolvo {
                    engineStartControlCard
                }
                if hasAnyVisibleChargingControls {
                    chargingControlCard
                }
                if features.contains(.remoteLocks) {
                    accessControlCard
                }
                if (features.contains(.remoteWindows) && profile.permits(.windows)) || features.contains(.remoteHonkFlash) {
                    windowsLocateCard
                }
                if features.contains(.remoteOTA) && profile.permits(.softwareInstallControl) {
                    otaControlCard
                }
            } else {
                noControlsEnabledCard
            }
        }
        .sheet(isPresented: $showScheduleEditor) {
            ScheduleEditorSheet(state: state, onRemoteCommand: onRemoteCommand)
        }
        .onAppear {
            if let currentTarget = state.chargeTargetPercentage {
                chargeTarget = currentTarget
            }
            if let currentAmps = state.chargingCurrentAmps, currentAmps > 0 {
                ampLimit = currentAmps
            }
            DispatchQueue.main.async {
                isInitialized = true
            }
        }
    }

    private var restrictedNoticeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 16))
                .foregroundStyle(HisingenTheme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(isBrandVolvo ? L10n.text("Volvo Connected Vehicle API") : L10n.text("Polestar Remote Commands"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(isBrandVolvo
                     ? L10n.text("Remote Lock, Unlock, Climate Preconditioning, and Flash/Honk commands are active.")
                     : L10n.text("Climate, locks, windows and software installation are active. Charging commands are not yet verified."))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(HisingenTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(HisingenTheme.accent.opacity(0.3), lineWidth: 0.5)
        )
    }

    private var climateControlCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    HStack(spacing: 7) {
                        SpinningFanView(isSpinning: climateActive, size: 14, color: climateActive ? .orange : HisingenTheme.inkMuted)
                        Text(L10n.text("Climate & Conditioning"))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(HisingenTheme.ink)
                    }
                    Spacer()
                    if climateActive {
                        Pill(
                            text: state.climateStatus?.activity.displayName ?? L10n.text("Active"),
                            color: .orange,
                            symbol: "fan.fill"
                        )
                    } else if let status = state.climateStatus, status.activity != .unknown && status.activity != .idle {
                        Pill(
                            text: status.activity.displayName,
                            color: .secondary,
                            symbol: nil
                        )
                    }
                }

                if features.contains(.remoteClimate) {
                    if profile.hasSelectableClimateTemperature {
                        VStack(spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(L10n.text("Target Cabin Temperature"))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    if let remaining = state.climateStatus?.timeRemainingMinutes, climateActive {
                                        Text(L10n.format("%d min remaining", remaining))
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(HisingenTheme.polestarAmber)
                                    }
                                }
                                Spacer()
                                Text(String(format: "%.1f °C", targetTemperature))
                                    .font(.system(size: 22, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(HisingenTheme.temperatureColor(celsius: targetTemperature))
                            }

                            HStack(spacing: 8) {
                                Button {
                                    if targetTemperature > 16.0 {
                                        targetTemperature = max(16.0, targetTemperature - 0.5)
                                        Preferences.remoteClimateTemperature = targetTemperature
                                    }
                                } label: {
                                    Image(systemName: "minus")
                                        .font(.system(size: 12, weight: .bold))
                                        .frame(width: 28, height: 24)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isDisabled(.stopClimate))

                                HStack(spacing: 4) {
                                    ForEach([19, 20, 21, 22, 23], id: \.self) { temp in
                                        let isSelected = abs(targetTemperature - Double(temp)) < 0.25
                                        Button {
                                            targetTemperature = Double(temp)
                                            Preferences.remoteClimateTemperature = Double(temp)
                                        } label: {
                                            Text("\(temp)°")
                                                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(isSelected ? Color.orange : nil)
                                        .controlSize(.small)
                                        .disabled(isDisabled(.stopClimate))
                                    }
                                }

                                Button {
                                    if targetTemperature < 30.0 {
                                        targetTemperature = min(30.0, targetTemperature + 0.5)
                                        Preferences.remoteClimateTemperature = targetTemperature
                                    }
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 12, weight: .bold))
                                        .frame(width: 28, height: 24)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isDisabled(.stopClimate))
                            }
                        }
                    } else {
                        if climateActive {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L10n.text("Cabin Preconditioning Running"))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(HisingenTheme.ink)
                                    if let remaining = state.climateStatus?.timeRemainingMinutes {
                                        Text(L10n.format("%d min remaining", remaining))
                                            .font(.system(size: 10.5, weight: .medium))
                                            .foregroundStyle(.orange)
                                    } else {
                                        Text(L10n.text("Preconditions vehicle using in-car comfort settings."))
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if let interior = state.climateStatus?.interiorTemperatureCelsius {
                                    VStack(alignment: .trailing, spacing: 1) {
                                        Text(L10n.text("Interior"))
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.secondary)
                                        Text(String(format: "%.1f °C", interior))
                                            .font(.system(size: 16, weight: .bold))
                                            .monospacedDigit()
                                            .foregroundStyle(HisingenTheme.temperatureColor(celsius: interior))
                                    }
                                }
                            }
                            .padding(9)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            HStack {
                                Text(L10n.text("Preconditions the cabin to comfortable temperature using in-car climate settings."))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if let interior = state.climateStatus?.interiorTemperatureCelsius {
                                    Text(String(format: "%.1f °C", interior))
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if profile.hasSelectableSeatHeating || profile.hasSelectableSteeringWheelHeating {
                        HStack(spacing: 8) {
                            if profile.hasSelectableSeatHeating {
                                SeatHeatingControl(
                                    title: L10n.text("Driver"),
                                    level: $driverSeat
                                ) { newLevel in
                                    Preferences.remoteDriverSeatHeating = newLevel
                                }
                                .disabled(isDisabled(.stopClimate))

                                SeatHeatingControl(
                                    title: L10n.text("Passenger"),
                                    level: $passengerSeat
                                ) { newLevel in
                                    Preferences.remoteFrontRightSeatHeating = newLevel
                                }
                                .disabled(isDisabled(.stopClimate))
                            }

                            if profile.hasSelectableSteeringWheelHeating {
                                SteeringHeatingControl(level: $steeringHeating) { newLevel in
                                    Preferences.remoteSteeringWheelHeating = newLevel
                                }
                                .disabled(isDisabled(.stopClimate))
                            }
                        }
                    }

                    Divider().opacity(0.5)

                    HStack(spacing: 8) {
                        if climateActive {
                            Button {
                                onRemoteCommand(.stopClimate)
                            } label: {
                                HStack(spacing: 6) {
                                    SpinningFanView(isSpinning: true, size: 13, color: .white)
                                    Text(L10n.text("Stop Climate"))
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .frame(maxWidth: .infinity, minHeight: 34)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.red)
                            .disabled(isDisabled(.stopClimate))
                        } else {
                            Button {
                                onRemoteCommand(.startClimate(
                                    temperatureCelsius: Float(targetTemperature),
                                    frontLeftSeat: driverSeat,
                                    frontRightSeat: passengerSeat,
                                    rearLeftSeat: .unspecified,
                                    rearRightSeat: .unspecified,
                                    steeringWheel: steeringHeating
                                ))
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "fan.fill")
                                    Text(L10n.text("Start Climate"))
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .frame(maxWidth: .infinity, minHeight: 34)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(HisingenTheme.polestarAmber)
                            .disabled(isDisabled(Self.climateProbe))
                        }
                    }
                }

                if profile.permits(.preCleaning) && features.contains(.remotePreCleaning) {
                    Button {
                        let isCleaning = state.airQuality?.cleaningState == .on
                        onRemoteCommand(isCleaning ? .stopPreCleaning : .startPreCleaning)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.secondary)
                            Text(L10n.text(state.airQuality?.cleaningState == .on
                                ? "Stop Air Cleaning" : "Clean Cabin Air (PM2.5 Pre-Clean)"))
                                .font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity, minHeight: 26)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(true)
                }
            }
        }
        .opacity(cardOpacity(Self.climateProbe))
    }

    private var chargingControlCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(symbol: "bolt.fill", title: L10n.text("Charging Controls"), color: .green)

                if profile.permits(.chargeTarget) && features.contains(.remoteCharging) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(L10n.text("Target Limit"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(chargeTarget)%")
                                .font(.system(size: 12, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                        }

                        Picker("", selection: $chargeTarget) {
                            ForEach([50, 60, 70, 80, 90, 100], id: \.self) { v in
                                Text("\(v)%").tag(v)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .disabled(true)
                        .onChange(of: chargeTarget) { [old = chargeTarget] _ in
                            guard isInitialized, chargeTarget != old else { return }
                            onRemoteCommand(.setChargeTarget(chargeTarget))
                        }
                    }
                }

                if profile.permits(.chargingCurrentLimit) && features.contains(.remoteCharging) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(L10n.text("Current Limit"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(ampLimit) A")
                                .font(.system(size: 12, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                        }

                        Picker("", selection: $ampLimit) {
                            ForEach([6, 8, 10, 13, 16, 20, 25, 32], id: \.self) { v in
                                Text("\(v)A").tag(v)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .disabled(true)
                        .onChange(of: ampLimit) { [old = ampLimit] _ in
                            guard isInitialized, ampLimit != old else { return }
                            onRemoteCommand(.setAmpLimit(ampLimit))
                        }
                    }
                }

                if profile.permits(.chargingScheduleOverride) && (features.contains(.remoteCharging) || features.contains(.remoteSchedules)) {
                    Divider().opacity(0.5)

                    HStack(spacing: 8) {
                        Button {
                            onRemoteCommand(.startChargingOverride)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "bolt.fill")
                                Text(L10n.text("Charge Now"))
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .frame(maxWidth: .infinity, minHeight: 30)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(true)

                        Button {
                            onRemoteCommand(.stopChargingOverride)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "clock.arrow.circlepath")
                                Text(L10n.text("Resume Schedule"))
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .frame(maxWidth: .infinity, minHeight: 30)
                        }
                        .buttonStyle(.bordered)
                        .disabled(true)
                    }
                }

                if features.contains(.remoteSchedules) || features.contains(.remoteCharging) {
                    Divider().opacity(0.5)

                    Button {
                        showScheduleEditor = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar.badge.clock")
                            Text(L10n.text("Manage Timers & Schedules…"))
                                .font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .opacity(0.65)
    }

    private var accessControlCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: "lock.fill", title: L10n.text("Locks & Security"), color: .blue)
                    Spacer()
                    if let isLocked = state.exteriorStatus?.isLocked {
                        Pill(
                            text: isLocked ? L10n.text("Locked") : L10n.text("Unlocked"),
                            color: isLocked ? HisingenTheme.semanticGood : HisingenTheme.semanticWarning,
                            symbol: isLocked ? "lock.fill" : "lock.open.fill"
                        )
                    }
                }

                HStack(spacing: 8) {
                    let isLocked = state.exteriorStatus?.isLocked == true

                    if profile.permits(.locks) && features.contains(.remoteLocks) {
                        Button {
                            onRemoteCommand(.lock)
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 15))
                                Text(L10n.text("Lock"))
                                    .font(.system(size: 11, weight: !isLocked ? .semibold : .medium))
                            }
                            .frame(maxWidth: .infinity, minHeight: 46)
                        }
                        .buttonStyle(.bordered)
                        .tint(!isLocked ? .blue : nil)
                        .disabled(isDisabled(.lock))

                        Button {
                            onRemoteCommand(.unlock)
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "lock.open.fill")
                                    .font(.system(size: 15))
                                Text(L10n.text("Unlock"))
                                    .font(.system(size: 11, weight: isLocked ? .semibold : .medium))
                            }
                            .frame(maxWidth: .infinity, minHeight: 46)
                        }
                        .buttonStyle(.bordered)
                        .tint(isLocked ? .blue : nil)
                        .disabled(isDisabled(.unlock))
                    }

                    if profile.permits(.trunk) && features.contains(.remoteLocks) {
                        Button {
                            onRemoteCommand(.unlockTrunk)
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "car.rear")
                                    .font(.system(size: 15))
                                Text(L10n.text("Trunk"))
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .frame(maxWidth: .infinity, minHeight: 46)
                        }
                        .buttonStyle(.bordered)
                        .disabled(true)
                    }
                }
            }
        }
        .opacity(cardOpacity(.lock))
    }

    private var windowsLocateCard: some View {
        let showWindows = profile.permits(.windows) && features.contains(.remoteWindows)
        let showLocate = profile.permits(.honkAndFlash) && features.contains(.remoteHonkFlash)
        let headerTitle = showWindows && showLocate
            ? L10n.text("Windows & Locate Vehicle")
            : (showWindows ? L10n.text("Windows Control") : L10n.text("Locate Vehicle"))
        let headerSymbol = showWindows ? "rectangle.arrowtriangle.2.outward" : "flashlight.on.fill"

        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: headerSymbol, title: headerTitle, color: .indigo)

                HStack(spacing: 8) {
                    if profile.permits(.windows) && features.contains(.remoteWindows) {
                        Button {
                            onRemoteCommand(.closeWindows)
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: "rectangle.arrowtriangle.2.inward")
                                    .font(.system(size: 13))
                                Text(L10n.text("Close Windows"))
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .frame(maxWidth: .infinity, minHeight: 42)
                        }
                        .buttonStyle(.bordered)
                        .disabled(true)

                        Button {
                            onRemoteCommand(.openWindows)
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: "rectangle.arrowtriangle.2.outward")
                                    .font(.system(size: 13))
                                Text(L10n.text("Vent Windows"))
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .frame(maxWidth: .infinity, minHeight: 42)
                        }
                        .buttonStyle(.bordered)
                        .disabled(true)
                    }

                    if profile.permits(.honkAndFlash) && features.contains(.remoteHonkFlash) {
                        Button {
                            onRemoteCommand(.flashLights)
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: "flashlight.on.fill")
                                    .font(.system(size: 13))
                                Text(L10n.text("Flash Lights"))
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .frame(maxWidth: .infinity, minHeight: 42)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isDisabled(.flashLights))

                        Button {
                            onRemoteCommand(.honkHorn)
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 13))
                                Text(L10n.text("Honk Horn"))
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .frame(maxWidth: .infinity, minHeight: 42)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isDisabled(.honkHorn))

                        Button {
                            onRemoteCommand(.honkAndFlash)
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: "horn.blast.fill")
                                    .font(.system(size: 13))
                                Text(L10n.text("Honk & Flash"))
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .frame(maxWidth: .infinity, minHeight: 42)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isDisabled(.honkAndFlash))
                    }
                }
            }
        }
        .opacity(cardOpacity(.honkAndFlash))
    }

    private var otaControlCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "shippingbox.fill", title: L10n.text("Vehicle Software & OTA"), color: .blue)
                if let software = state.softwareInfo {
                    otaStatusLine(software)
                    otaActions(software)
                } else {
                    otaStatusRow(symbol: "questionmark.circle.fill",
                                 tint: .secondary,
                                 text: L10n.text("Software status is unavailable for this vehicle."))
                }
            }
        }
    }

    /// The advertised version only means "an update is waiting" while the state says so —
    /// in every settled state it is what the car is already running, so it must not be
    /// described as pending.
    @ViewBuilder
    private func otaStatusLine(_ software: VehicleSoftwareInfo) -> some View {
        let pending = software.latestAvailableVersion ?? software.version
        switch software.state {
        case .available:
            otaStatusRow(symbol: "arrow.down.circle", tint: .blue,
                         text: pending.map { L10n.format("Software update %@ is available. The vehicle downloads it automatically; it can be installed once that finishes.", $0) }
                            ?? L10n.text("A software update is available. The vehicle downloads it automatically."))
        case .downloaded, .deferred:
            otaStatusRow(symbol: "arrow.down.circle.fill", tint: .blue,
                         text: pending.map { L10n.format("Software update %@ is ready to install.", $0) }
                            ?? L10n.text("A software update is ready to install."))
        case .downloading:
            otaStatusRow(symbol: "arrow.down.circle", tint: .blue,
                         text: pending.map { L10n.format("Downloading software update %@…", $0) }
                            ?? L10n.text("Downloading a software update…"))
        case .installing:
            otaStatusRow(symbol: "gearshape.2.fill", tint: .blue,
                         text: pending.map { L10n.format("Installing software update %@…", $0) }
                            ?? L10n.text("Installing a software update…"))
        case .scheduled:
            let when = software.scheduledAt.map(Format.dateTimeFormatter.string(from:))
            otaStatusRow(symbol: "calendar.badge.clock", tint: .blue,
                         text: when.map { L10n.format("Installation is scheduled for %@.", $0) }
                            ?? L10n.text("An installation is scheduled."))
        case .failed:
            otaStatusRow(symbol: "exclamationmark.triangle.fill", tint: HisingenTheme.semanticWarning,
                         text: L10n.text("The last software update failed."))
        case .completed, .unknown:
            let installed = software.installedVersion ?? software.version
            otaStatusRow(symbol: "checkmark.circle.fill", tint: HisingenTheme.semanticGood,
                         text: installed.map { L10n.format("Software is up to date (%@).", $0) }
                            ?? L10n.text("Software is up to date"))
        }
    }

    @ViewBuilder
    private func otaActions(_ software: VehicleSoftwareInfo) -> some View {
        switch software.state {
        case .downloaded, .deferred:
            otaButton(title: L10n.text("Install Update Now"), symbol: "arrow.down.circle.fill",
                      prominent: true) { onRemoteCommand(.installOTANow) }
        case .scheduled:
            VStack(spacing: 6) {
                otaButton(title: L10n.text("Install Update Now"), symbol: "arrow.down.circle.fill",
                          prominent: true) { onRemoteCommand(.installOTANow) }
                otaButton(title: L10n.text("Cancel Scheduled Installation"), symbol: "xmark.circle",
                          prominent: false) { onRemoteCommand(.cancelOTA) }
            }
        // `available` offers no button: the scheduler rejects an update the car has not
        // downloaded yet, so a live-looking button would only ever produce an error.
        case .available, .downloading, .installing, .failed, .completed, .unknown:
            EmptyView()
        }
    }

    private func otaStatusRow(symbol: String, tint: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(HisingenTheme.ink)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func otaButton(title: String, symbol: String, prominent: Bool,
                           action: @escaping () -> Void) -> some View {
        let label = HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(title)
        }
        .frame(maxWidth: .infinity)

        if prominent {
            Button(action: action) { label }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.regular)
                .disabled(remoteCommandInProgress)
        } else {
            Button(action: action) { label }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(remoteCommandInProgress)
        }
    }

    private var engineStartControlCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    CardHeader(symbol: "flame.fill", title: L10n.text("Remote Engine Start (RES)"), color: .orange)
                    Spacer()
                    if state.isEngineRunning == true {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(HisingenTheme.semanticGood)
                                .frame(width: 6, height: 6)
                            Text(L10n.text("Engine Running"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(HisingenTheme.semanticGood)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(HisingenTheme.semanticGood.opacity(0.12), in: Capsule())
                    } else {
                        Text(L10n.text("Engine Stopped"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }

                Text(L10n.text("Starts combustion engine to precondition cabin temperature before departure. Automatically runs for 15 minutes."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        onRemoteCommand(.startEngine(runtimeMinutes: 15))
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "flame.fill")
                            Text(L10n.text("Start Engine (15 min)"))
                                .font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(isDisabled(.startEngine(runtimeMinutes: 15)) || (state.isEngineRunning == true))

                    Button {
                        onRemoteCommand(.stopEngine)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "stop.fill")
                            Text(L10n.text("Stop Engine"))
                                .font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDisabled(.stopEngine) || (state.isEngineRunning != true))
                }
            }
        }
        .opacity(cardOpacity(.startEngine(runtimeMinutes: 15)))
    }

    private var noControlsEnabledCard: some View {
        Card {
            VStack(spacing: 8) {
                Image(systemName: "switch.2")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                Text(L10n.text("No Remote Controls Enabled"))
                    .font(.system(size: 13, weight: .semibold))
                Text(L10n.text("Enable remote controls in Settings under Telemetry & Features to display controls here."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }
}

struct SpinningFanView: View {
    let isSpinning: Bool
    var size: CGFloat = 13
    var color: Color = .orange

    @State private var angle: Double = 0

    var body: some View {
        Image(systemName: "fan.fill")
            .font(.system(size: size))
            .foregroundStyle(color)
            .rotationEffect(.degrees(angle))
            .onAppear {
                if isSpinning {
                    startSpinning()
                }
            }
            .onChange(of: isSpinning) { spinning in
                if spinning {
                    startSpinning()
                } else {
                    withAnimation(.easeOut(duration: 0.4)) {
                        angle = 0
                    }
                }
            }
    }

    private func startSpinning() {
        withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
            angle = 360
        }
    }
}


