import SwiftUI
import AppKit

@MainActor
struct ControlsTabView: View {
    let state: VehicleState
    let remoteCommandInProgress: Bool
    /// `RemoteCommand.identifier` of the command currently in flight, so the specific control
    /// that was tapped can show a "Sending…" state instead of the whole page dimming.
    var inFlightCommandID: String? = nil
    /// Most recent command outcome, shown inline so a failure is visible even with system
    /// notifications muted.
    var feedback: RemoteCommandFeedback? = nil
    let onRemoteCommand: (RemoteCommand) -> Void
    /// Triggers an authoritative telemetry + capability refresh (footer refresh equivalent),
    /// surfaced here so a dimmed card offers a way to re-check what the vehicle supports.
    var onRefresh: () -> Void = {}

    @State private var targetTemperature: Double = 21
    @State private var driverSeat: HeatingLevel = .unspecified
    @State private var passengerSeat: HeatingLevel = .unspecified
    @State private var rearLeftSeat: HeatingLevel = .unspecified
    @State private var rearRightSeat: HeatingLevel = .unspecified
    @State private var steeringHeating: HeatingLevel = .unspecified
    @State private var showRearSeats = false
    @Environment(\.preferencesStore) private var preferences
    @State private var engineRuntimeMinutes: Int = 15
    @State private var showScheduleEditor = false
    @State private var scheduleEditorKind: ScheduleKind = .climate
    @State private var chargeTargetDraft: Double?
    @State private var ampLimitDraft: Double?
    @State private var locationAmpDrafts: [String: Double] = [:]
    @State private var locationSocDrafts: [String: Double] = [:]
    @State private var showAddLocation = false
    @State private var renamingLocation: ChargeLocationSnapshot?
    @State private var renameDraft: String = ""
    @State private var dismissedFeedbackID: UUID?
    @State private var otaScheduleDelayMinutes: Int = 120
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Charge target derived from state (not @State) so it survives view rebuilds.
    /// When a command is in progress or the optimistic lock is active, use the optimistic
    /// value from the state; otherwise use the backend-reported value.
    private var chargeTarget: Int? {
        state.chargeTargetPercentage.flatMap { $0 > 0 ? $0 : nil }
    }
    /// Amp limit derived from state (not @State) for the same reason.
    private var ampLimit: Int? {
        state.chargingCurrentLimitAmps.flatMap { $0 > 0 ? $0 : nil }
    }

    private var isBrandVolvo: Bool { preferences.activeBrand == .volvo }
    private var profile: VehicleCapabilityProfile { state.capabilityProfile }
    private var features: Set<AppFeature> { preferences.features.enabled }
    private let capabilityGate = CapabilityGate()

    /// True only when the provider has explicitly reported the vehicle as unavailable (offline
    /// / in privacy mode). Distinct from "asleep" (`state.isStale()`), which still accepts most
    /// commands as a wake-up.
    private var vehicleOffline: Bool {
        if case .unavailable = state.availability { return true }
        return false
    }

    // MARK: Command dispatch

    /// Every dispatch goes through here: a light haptic tick (matching the footer refresh
    /// button and other command surfaces) then the upstream handler. Security-sensitive and
    /// destructive commands still get the coordinator's confirm + device-owner-auth gate;
    /// this only adds the tactile acknowledgement the rest of the app already has.
    private func send(_ command: RemoteCommand) {
        NSHapticFeedbackManager.defaultPerformer.perform(
            command.risk == .routine ? .generic : .levelChange, performanceTime: .now)
        onRemoteCommand(command)
    }

    private func availability(_ command: RemoteCommand, ignoreBusy: Bool = false) -> CommandAvailability {
        capabilityGate.availability(
            for: command,
            state: state,
            brand: preferences.activeBrand,
            enabledFeatures: features,
            commandInProgress: ignoreBusy ? false : remoteCommandInProgress
        )
    }

    /// A control is live only when all three layers agree: this app implements the command for
    /// the active brand, the vehicle's capability profile permits it, and nothing else is
    /// already in flight.
    private func isDisabled(_ command: RemoteCommand) -> Bool {
        !availability(command).isAvailable
    }

    /// Whether *this specific* command is the one currently executing.
    private func isSending(_ command: RemoteCommand) -> Bool {
        remoteCommandInProgress && inFlightCommandID == command.identifier
    }

    /// The best *structural* availability across a card's representative commands: `.available`
    /// if any is. Ignores the transient busy state on purpose — a card must not dim or grow a
    /// "why" caption just because an unrelated command is mid-flight.
    private func cardAvailability(_ commands: [RemoteCommand]) -> CommandAvailability {
        var fallback: CommandAvailability = .unsupportedByVehicle
        for command in commands {
            let a = availability(command, ignoreBusy: true)
            if a.isAvailable { return .available }
            fallback = a
        }
        return fallback
    }

    /// Dims a whole card whose commands are unavailable on this vehicle, so "shown but inert"
    /// reads as deliberate rather than broken.
    private func cardOpacity(_ commands: [RemoteCommand]) -> Double {
        cardAvailability(commands) == .available ? 1.0 : 0.6
    }

    /// Stands in for the real `.startClimate` when only its gating matters — neither
    /// `isImplemented(by:)` nor `requiredCapability` looks at the associated values.
    private static let climateProbe = RemoteCommand.startClimate(
        temperatureCelsius: 0, frontLeftSeat: .unspecified, frontRightSeat: .unspecified,
        rearLeftSeat: .unspecified, rearRightSeat: .unspecified, steeringWheel: .unspecified
    )
    private var climateActive: Bool {
        guard let status = state.climateStatus else { return false }
        return status.activity == .active || status.activity == .heating
            || status.activity == .cooling || status.activity == .ventilating
    }

    // MARK: Card visibility

    /// One declarative table of (should-show, builder) so `body` and the "any cards?" check
    /// cannot drift apart the way the previous hand-maintained pair of predicates could. The
    /// view is a closure so a hidden card's body is never built.
    private struct CardEntry: Identifiable {
        let id: String
        let isVisible: Bool
        let view: () -> AnyView
    }

    private var hasAnyVisibleChargingControls: Bool {
        guard state.powertrain.hasElectricRange else { return false }
        return (profile.permits(.chargeTarget) && features.contains(.remoteCharging)) ||
        (profile.permits(.chargingCurrentLimit) && features.contains(.remoteCharging)) ||
        (profile.permits(.chargingScheduleOverride) && (features.contains(.remoteCharging) || features.contains(.remoteSchedules))) ||
        (profile.permits(.chargeLocations) && features.contains(.remoteCharging)) ||
        (profile.permits(.chargingSchedule) && (features.contains(.remoteSchedules) || features.contains(.remoteCharging)))
    }

    private var cards: [CardEntry] {
        [
            CardEntry(
                id: "climate",
                isVisible: features.contains(.remoteClimate)
                    || (features.contains(.remotePreCleaning) && profile.permits(.preCleaning)),
                view: { AnyView(self.climateControlCard) }),
            CardEntry(
                id: "engine",
                isVisible: state.powertrain.hasCombustionEngine && isBrandVolvo && engineStartPermitted,
                view: { AnyView(self.engineStartControlCard) }),
            CardEntry(
                id: "charging",
                isVisible: hasAnyVisibleChargingControls,
                view: { AnyView(self.chargingControlCard) }),
            CardEntry(
                id: "access",
                isVisible: features.contains(.remoteLocks),
                view: { AnyView(self.accessControlCard) }),
            CardEntry(
                id: "windows-locate",
                isVisible: (features.contains(.remoteWindows) && profile.permits(.windows))
                    || features.contains(.remoteHonkFlash),
                view: { AnyView(self.windowsLocateCard) }),
            CardEntry(
                id: "ota",
                isVisible: features.contains(.remoteOTA) && profile.permits(.softwareInstallControl),
                view: { AnyView(self.otaControlCard) }),
        ]
    }

    private var visibleCards: [CardEntry] { cards.filter(\.isVisible) }

    private var engineStartPermitted: Bool {
        profile.hasEngineStart || profile.permits(.engineStart)
    }

    /// Show the inline outcome only while it is fresh — re-entering the tab days later must
    /// not resurface an old "Command sent" (the view's dismiss state resets on tab switch).
    private var liveFeedback: RemoteCommandFeedback? {
        guard let feedback, feedback.id != dismissedFeedbackID,
              Date().timeIntervalSince(feedback.issuedAt) < 45 else { return nil }
        return feedback
    }

    var body: some View {
        VStack(spacing: HisingenTheme.sectionSpacing) {
            if let feedback = liveFeedback {
                feedbackBanner(feedback)
            }
            if vehicleOffline {
                offlineBanner
            }
            if !visibleCards.isEmpty {
                restrictedNoticeBanner
                ForEach(visibleCards) { entry in entry.view() }
                if anyCardDimmed || state.probedCapabilities == nil {
                    reprobeFooter
                }
            } else {
                noControlsEnabledCard
            }
        }
        .sheet(isPresented: $showScheduleEditor) {
            ScheduleEditorSheet(state: state, initialKind: scheduleEditorKind, onRemoteCommand: onRemoteCommand)
        }
        .sheet(isPresented: $showAddLocation) {
            ChargeLocationEditorSheet(defaultAmpLimit: ampLimit ?? 16) { alias, amps, soc, optimised in
                send(.createChargeLocationAtCar(
                    alias: alias, ampLimit: amps, minimumSoc: soc, optimisedCharging: optimised))
            }
        }
        .alert(L10n.text("Rename charge location"),
               isPresented: Binding(get: { renamingLocation != nil },
                                    set: { if !$0 { renamingLocation = nil } })) {
            TextField(L10n.text("Location name"), text: $renameDraft)
            Button(L10n.text("Save")) {
                if let loc = renamingLocation {
                    let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, trimmed != loc.alias {
                        send(.updateChargeLocationAlias(id: loc.id, alias: trimmed))
                    }
                }
                renamingLocation = nil
            }
            Button(L10n.text("Cancel"), role: .cancel) { renamingLocation = nil }
        }
        .onAppear {
            targetTemperature = preferences.remoteClimateTemperature
            driverSeat = preferences.remoteDriverSeatHeating
            passengerSeat = preferences.remoteFrontRightSeatHeating
            rearLeftSeat = preferences.remoteRearLeftSeatHeating
            rearRightSeat = preferences.remoteRearRightSeatHeating
            steeringHeating = preferences.remoteSteeringWheelHeating
            engineRuntimeMinutes = preferences.remoteEngineRuntimeMinutes
            showRearSeats = rearLeftSeat != .unspecified || rearRightSeat != .unspecified
        }
        // Drop stale slider drafts once the vehicle reports the value we just set, so a
        // follow-up refresh landing mid-interaction can't fight the knob.
        .onChange(of: chargeTarget) { _, _ in chargeTargetDraft = nil }
        .onChange(of: ampLimit) { _, _ in ampLimitDraft = nil }
    }

    private var anyCardDimmed: Bool {
        visibleCards.contains { entry in
            switch entry.id {
            case "climate": return cardOpacity([Self.climateProbe, .startPreCleaning]) < 1
            case "engine": return cardOpacity([.startEngine(runtimeMinutes: engineRuntimeMinutes)]) < 1
            case "charging": return cardOpacity([.setChargeTarget(80), .setAmpLimit(16), .startChargingOverride]) < 1
            case "access": return cardOpacity([.lock, .unlock]) < 1
            case "windows-locate": return cardOpacity([.closeWindows, .honkAndFlash, .flashLights]) < 1
            case "ota": return cardOpacity([.installOTANow]) < 1
            default: return false
            }
        }
    }

    // MARK: Banners

    private func feedbackBanner(_ feedback: RemoteCommandFeedback) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: feedback.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(feedback.success ? HisingenTheme.semanticGood : HisingenTheme.semanticWarning)
            VStack(alignment: .leading, spacing: 2) {
                Text(feedback.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(feedback.message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button {
                withAnimation { dismissedFeedbackID = feedback.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Dismiss"))
        }
        .padding(10)
        .background((feedback.success ? HisingenTheme.semanticGood : HisingenTheme.semanticWarning).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke((feedback.success ? HisingenTheme.semanticGood : HisingenTheme.semanticWarning).opacity(0.28), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        // Successes clear themselves; failures stay until dismissed.
        .task(id: feedback.id) {
            guard feedback.success else { return }
            try? await Task.sleep(for: .seconds(6))
            withAnimation { dismissedFeedbackID = feedback.id }
        }
    }

    private var offlineBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 14))
                .foregroundStyle(HisingenTheme.semanticWarning)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("Vehicle is offline"))
                    .font(.system(size: 11, weight: .semibold))
                Text(L10n.text("Commands may not be delivered until it reconnects."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(HisingenTheme.semanticWarning.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var restrictedNoticeBanner: some View {
        let activeNames = AppFeature.allCases
            .filter { $0.isRemoteControl && features.contains($0) }
            .map(\.title)
        return HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 16))
                .foregroundStyle(HisingenTheme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(isBrandVolvo ? L10n.text("Volvo Connected Vehicle API") : L10n.text("Polestar Remote Commands"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(activeNames.isEmpty
                     ? L10n.text("No remote-control features are enabled.")
                     : L10n.format("Enabled: %@.", activeNames.joined(separator: ", ")))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(HisingenTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(HisingenTheme.accent.opacity(0.3), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }

    private var reprobeFooter: some View {
        Button {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            onRefresh()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text(L10n.text("Re-check what this vehicle supports"))
                    .font(.system(size: 10.5, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 26)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(L10n.text("Refreshes telemetry and re-probes the vehicle's capability set."))
    }

    /// Caption shown inside a dimmed card explaining why its controls are inert.
    @ViewBuilder
    private func dimReason(_ availability: CommandAvailability) -> some View {
        if let reason = availability.shortReason {
            HStack(spacing: 5) {
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                Text(reason)
                    .font(.system(size: 9.5))
            }
            .foregroundStyle(.secondary)
        }
    }

    /// Inline "Sending…" affordance for the button that dispatched the in-flight command.
    @ViewBuilder
    private func sendingOverlay(_ command: RemoteCommand) -> some View {
        if isSending(command) {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(L10n.text("Sending…")).font(.system(size: 9, weight: .medium))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    // MARK: Climate card

    private var climateControlCard: some View {
        let climateCommands = [Self.climateProbe, RemoteCommand.startPreCleaning]
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    HStack(spacing: 7) {
                        SpinningFanView(isSpinning: climateActive && !reduceMotion, size: 14,
                                        color: climateActive ? .orange : HisingenTheme.inkMuted)
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
                        Pill(text: status.activity.displayName, color: .secondary, symbol: nil)
                    }
                }

                dimReason(cardAvailability(climateCommands))

                if features.contains(.remoteClimate) {
                    if profile.hasSelectableClimateTemperature {
                        temperatureControls
                    } else {
                        climateAutomaticInfo
                    }

                    if profile.hasSelectableSeatHeating || profile.hasSelectableSteeringWheelHeating {
                        seatAndSteeringControls
                    }

                    Divider().opacity(0.5)
                    climateStartStopButtons

                    if features.contains(.remoteSchedules) && profile.permits(.climateTimers) {
                        Button {
                            scheduleEditorKind = .climate
                            showScheduleEditor = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "calendar.badge.clock")
                                Text(L10n.text("Schedule departure preconditioning…"))
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                            .frame(maxWidth: .infinity, minHeight: 26)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if profile.permits(.preCleaning) && features.contains(.remotePreCleaning) {
                    Button {
                        let isCleaning = state.airQuality?.cleaningState == .on
                        send(isCleaning ? .stopPreCleaning : .startPreCleaning)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles").foregroundStyle(.secondary)
                            Text(L10n.text(state.airQuality?.cleaningState == .on
                                ? "Stop Air Cleaning" : "Clean Cabin Air (PM2.5 Pre-Clean)"))
                                .font(.system(size: 11, weight: .medium))
                            sendingOverlay(.startPreCleaning)
                        }
                        .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isDisabled(.startPreCleaning))
                }
            }
        }
        .opacity(cardOpacity(climateCommands))
    }

    /// A "max preheat" that does not silently rewrite the user's saved comfort settings: it
    /// sends one high-heat command (30 °C plus every heater the vehicle exposes at its top
    /// level) without persisting anything.
    private var maxHeatCommand: RemoteCommand {
        .startClimate(
            temperatureCelsius: 30,
            frontLeftSeat: profile.hasSelectableSeatHeating ? .level3 : .unspecified,
            frontRightSeat: profile.hasSelectableSeatHeating ? .level3 : .unspecified,
            rearLeftSeat: profile.hasSelectableSeatHeating ? .level3 : .unspecified,
            rearRightSeat: profile.hasSelectableSeatHeating ? .level3 : .unspecified,
            steeringWheel: profile.hasSelectableSteeringWheelHeating ? .level3 : .unspecified
        )
    }

    /// Step the setpoint by whole display units so a Fahrenheit user never sees the same
    /// rounded value twice, then snap back to the nearest 0.5 °C the backend accepts.
    private func adjustTemperature(byDisplayUnits delta: Double) {
        let unit = preferences.temperatureUnit
        let currentDisplay: Double
        switch unit {
        case .celsius: currentDisplay = targetTemperature
        case .fahrenheit: currentDisplay = targetTemperature * 9 / 5 + 32
        }
        let nextDisplay = currentDisplay + delta
        let nextCelsius: Double
        switch unit {
        case .celsius: nextCelsius = nextDisplay
        case .fahrenheit: nextCelsius = (nextDisplay - 32) * 5 / 9
        }
        let clamped = min(30.0, max(16.0, (nextCelsius * 2).rounded() / 2))
        targetTemperature = clamped
        preferences.remoteClimateTemperature = clamped
    }

    private var temperatureStep: Double {
        preferences.temperatureUnit == .fahrenheit ? 1 : 0.5
    }

    private var temperatureControls: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    send(maxHeatCommand)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "windshield.front.heat")
                        Text(L10n.text("Max Heat")).font(.system(size: 9, weight: .semibold))
                        sendingOverlay(maxHeatCommand)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.orange)
                .disabled(isDisabled(maxHeatCommand))
                .help(L10n.text("Sends 30 °C with every heater at maximum. Does not change your saved settings."))
                Spacer()
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("Preconditioning Command Setpoint"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(L10n.text("Saved command setting; not live cabin telemetry"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    if let remaining = state.climateStatus?.timeRemainingMinutes, climateActive {
                        Text(L10n.format("%d min remaining", remaining))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(HisingenTheme.polestarAmber)
                    }
                }
                Spacer()
                Text(Format.temperature(celsius: targetTemperature, unit: preferences.temperatureUnit))
                    .font(.system(size: 22, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(HisingenTheme.temperatureColor(celsius: targetTemperature))
                    .accessibilityLabel(L10n.text("Target temperature"))
                    .accessibilityValue(Format.temperature(celsius: targetTemperature, unit: preferences.temperatureUnit))
            }

            HStack(spacing: 8) {
                Button {
                    adjustTemperature(byDisplayUnits: -temperatureStep)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(targetTemperature <= 16.0)
                .accessibilityLabel(L10n.text("Decrease target temperature"))

                HStack(spacing: 4) {
                    ForEach([19, 20, 21, 22, 23], id: \.self) { temp in
                        let isSelected = abs(targetTemperature - Double(temp)) < 0.25
                        Button {
                            targetTemperature = Double(temp)
                            preferences.remoteClimateTemperature = Double(temp)
                        } label: {
                            Text(Format.temperature(celsius: Double(temp), unit: preferences.temperatureUnit, decimals: 0))
                                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(isSelected ? Color.orange : nil)
                        .controlSize(.small)
                        .accessibilityLabel(L10n.format("Set target to %@",
                            Format.temperature(celsius: Double(temp), unit: preferences.temperatureUnit, decimals: 0)))
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    }
                }

                Button {
                    adjustTemperature(byDisplayUnits: temperatureStep)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(targetTemperature >= 30.0)
                .accessibilityLabel(L10n.text("Increase target temperature"))
            }
        }
    }

    @ViewBuilder
    private var climateAutomaticInfo: some View {
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
                        Text(L10n.text("Interior")).font(.system(size: 9.5)).foregroundStyle(.secondary)
                        Text(Format.temperature(celsius: interior, unit: preferences.temperatureUnit))
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
                    Text(Format.temperature(celsius: interior, unit: preferences.temperatureUnit))
                        .font(.system(size: 12.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var seatAndSteeringControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if profile.hasSelectableSeatHeating {
                    SeatHeatingControl(title: L10n.text("Driver"), level: $driverSeat) {
                        preferences.remoteDriverSeatHeating = $0
                    }
                    .disabled(isDisabled(Self.climateProbe))

                    SeatHeatingControl(title: L10n.text("Passenger"), level: $passengerSeat) {
                        preferences.remoteFrontRightSeatHeating = $0
                    }
                    .disabled(isDisabled(Self.climateProbe))
                }

                if profile.hasSelectableSteeringWheelHeating {
                    SteeringHeatingControl(level: $steeringHeating) {
                        preferences.remoteSteeringWheelHeating = $0
                    }
                    .disabled(isDisabled(Self.climateProbe))
                }
            }

            if profile.hasSelectableSeatHeating {
                if showRearSeats {
                    HStack(spacing: 8) {
                        SeatHeatingControl(title: L10n.text("Rear left"), level: $rearLeftSeat) {
                            preferences.remoteRearLeftSeatHeating = $0
                        }
                        .disabled(isDisabled(Self.climateProbe))
                        SeatHeatingControl(title: L10n.text("Rear right"), level: $rearRightSeat) {
                            preferences.remoteRearRightSeatHeating = $0
                        }
                        .disabled(isDisabled(Self.climateProbe))
                        Spacer(minLength: 0)
                    }
                } else {
                    Button {
                        withAnimation { showRearSeats = true }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.down")
                            Text(L10n.text("Rear seat heating")).font(.system(size: 10, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(HisingenTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var startClimateCommand: RemoteCommand {
        .startClimate(
            temperatureCelsius: Float(targetTemperature),
            frontLeftSeat: driverSeat,
            frontRightSeat: passengerSeat,
            rearLeftSeat: showRearSeats ? rearLeftSeat : .unspecified,
            rearRightSeat: showRearSeats ? rearRightSeat : .unspecified,
            steeringWheel: steeringHeating
        )
    }

    private var climateStartStopButtons: some View {
        HStack(spacing: 8) {
            if climateActive {
                Button {
                    send(.stopClimate)
                } label: {
                    HStack(spacing: 6) {
                        SpinningFanView(isSpinning: !reduceMotion, size: 13, color: .white)
                        Text(L10n.text("Stop Climate")).font(.system(size: 12, weight: .semibold))
                        sendingOverlay(.stopClimate)
                    }
                    .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.red)
                .disabled(isDisabled(.stopClimate))
            } else {
                Button {
                    send(startClimateCommand)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "fan.fill")
                        Text(L10n.text("Start Climate")).font(.system(size: 12, weight: .semibold))
                        sendingOverlay(Self.climateProbe)
                    }
                    .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(HisingenTheme.polestarAmber)
                .disabled(isDisabled(Self.climateProbe))
            }
        }
    }

    // MARK: Charging card

    private var chargingControlCard: some View {
        let chargingCommands = [RemoteCommand.setChargeTarget(80), .setAmpLimit(16), .startChargingOverride]
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(symbol: "bolt.fill", title: L10n.text("Charging Controls"), color: .green)
                dimReason(cardAvailability(chargingCommands))

                if profile.permits(.chargeTarget) && features.contains(.remoteCharging) {
                    chargeTargetControls
                }
                if profile.permits(.chargingCurrentLimit) && features.contains(.remoteCharging) {
                    currentLimitControls
                }
                if profile.permits(.chargingScheduleOverride)
                    && (features.contains(.remoteCharging) || features.contains(.remoteSchedules)) {
                    Divider().opacity(0.5)
                    chargeOverrideButtons
                }

                chargeLocationsSection

                if profile.permits(.chargingSchedule)
                    && (features.contains(.remoteSchedules) || features.contains(.remoteCharging)) {
                    Divider().opacity(0.5)
                    Button {
                        scheduleEditorKind = .globalCharging
                        showScheduleEditor = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar.badge.clock")
                            Text(L10n.text("Manage Timers & Schedules…")).font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .opacity(cardOpacity(chargingCommands))
    }

    private var chargeTargetPresets: [Int] { [50, 60, 70, 80, 90, 100] }

    private var chargeTargetControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text("Target Limit"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(chargeTarget.map { Format.percent(Double($0)) } ?? L10n.text("Unavailable"))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(reduceMotion ? .identity : .numericText())
            }

            HStack(spacing: 6) {
                ForEach(chargeTargetPresets, id: \.self) { target in
                    let selected = chargeTarget == target
                    Button {
                        send(.setChargeTarget(target))
                    } label: {
                        Text(Format.percent(Double(target)))
                            .font(.system(size: 9.5, weight: selected ? .bold : .medium))
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity)
                            .background(selected ? HisingenTheme.accent.opacity(0.18) : Color.primary.opacity(0.05),
                                       in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(selected ? HisingenTheme.accent : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled(.setChargeTarget(target)))
                    .accessibilityLabel(L10n.format("Set charge target to %@", Format.percent(Double(target))))
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }

            if let chargeTarget {
                Slider(value: Binding(
                    get: { chargeTargetDraft ?? Double(chargeTarget) },
                    set: { chargeTargetDraft = $0 }
                ), in: 50...100, step: 5, onEditingChanged: { editing in
                    guard !editing, let draft = chargeTargetDraft else { return }
                    chargeTargetDraft = nil
                    let rounded = Int(draft.rounded())
                    guard rounded != chargeTarget else { return }
                    send(.setChargeTarget(rounded))
                })
                .tint(.green)
                .disabled(isDisabled(.setChargeTarget(chargeTarget)))
                .accessibilityValue(Format.percent(Double(chargeTargetDraft.map { Int($0.rounded()) } ?? chargeTarget)))
                sendingOverlay(.setChargeTarget(chargeTarget))
            } else {
                Text(L10n.text("The vehicle did not report its current target. Choose a preset to set a new value."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var currentLimitControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L10n.text("Current Limit"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ampLimit.map { Format.amps($0) } ?? L10n.text("Unavailable"))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(reduceMotion ? .identity : .numericText())
            }

            if let ampLimit {
                let chips = [6, 8, 10, 13, 16].filter { $0 != ampLimit }
                if !chips.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(chips, id: \.self) { preset in
                            Button {
                                send(.setAmpLimit(preset))
                            } label: {
                                Text(Format.amps(preset))
                                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                    .frame(minWidth: 34)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isDisabled(.setAmpLimit(preset)))
                            .accessibilityLabel(L10n.format("Set charging current to %@", Format.amps(preset)))
                        }
                        Spacer()
                    }
                    .padding(.bottom, 2)
                }
                Slider(value: Binding(
                    get: { ampLimitDraft ?? Double(ampLimit) },
                    set: { ampLimitDraft = $0 }
                ), in: 6...32, step: 1, onEditingChanged: { editing in
                    guard !editing, let draft = ampLimitDraft else { return }
                    ampLimitDraft = nil
                    let rounded = Int(draft.rounded())
                    guard rounded != ampLimit else { return }
                    send(.setAmpLimit(rounded))
                })
                .tint(.orange)
                .disabled(isDisabled(.setAmpLimit(ampLimit)))
                .accessibilityValue(Format.amps(ampLimitDraft.map { Int($0.rounded()) } ?? ampLimit))
            } else {
                Text(L10n.text("The vehicle did not report a configurable current limit."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chargeOverrideButtons: some View {
        HStack(spacing: 8) {
            Button {
                send(.startChargingOverride)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                    Text(L10n.text("Charge Now")).font(.system(size: 11, weight: .medium))
                    sendingOverlay(.startChargingOverride)
                }
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(isDisabled(.startChargingOverride))

            Button {
                send(.stopChargingOverride)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text(L10n.text("Resume Schedule")).font(.system(size: 11, weight: .medium))
                    sendingOverlay(.stopChargingOverride)
                }
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.bordered)
            .disabled(isDisabled(.stopChargingOverride))
        }
    }

    /// Per-location charging settings from Polestar's ChargeLocationService.
    private var chargeLocationsSection: some View {
        let locations = state.chargeLocations.filter { $0.isSavedLocation || !$0.alias.isEmpty }
        guard profile.permits(.chargeLocations), features.contains(.remoteCharging) else {
            return AnyView(EmptyView())
        }
        return AnyView(VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.5)
            HStack {
                Text(L10n.text("Saved Charge Locations"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showAddLocation = true
                } label: {
                    Label(L10n.text("Add here"), systemImage: "plus.circle")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.borderless)
                .disabled(remoteCommandInProgress)
                .help(L10n.text("Saves the vehicle's current position as a charge location."))
            }

            if locations.isEmpty {
                Text(L10n.text("No saved locations. Use “Add here” while parked where you charge."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }

            ForEach(locations) { location in
                chargeLocationRow(location)
            }
        })
    }

    private func chargeLocationRow(_ location: ChargeLocationSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(HisingenTheme.accent)
                Text(location.alias.isEmpty ? L10n.text("Unnamed location") : location.alias)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button {
                    renameDraft = location.alias
                    renamingLocation = location
                } label: {
                    Image(systemName: "pencil").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .disabled(remoteCommandInProgress)
                .help(L10n.text("Rename"))
                .accessibilityLabel(L10n.text("Rename location"))
            }

            // Minimum state of charge kept at this location.
            HStack {
                Text(L10n.text("Minimum charge")).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text(Format.percent(Double(locationSocDrafts[location.id].map { Int($0.rounded()) } ?? location.minimumSoc)))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            Slider(value: Binding(
                get: { locationSocDrafts[location.id] ?? Double(location.minimumSoc) },
                set: { locationSocDrafts[location.id] = $0 }
            ), in: 0...100, step: 5, onEditingChanged: { editing in
                guard !editing, let draft = locationSocDrafts[location.id] else { return }
                locationSocDrafts[location.id] = nil
                let rounded = Int(draft.rounded())
                guard rounded != location.minimumSoc else { return }
                send(.updateChargeLocationMinimumSoc(id: location.id, soc: rounded))
            })
            .tint(.green)
            .disabled(remoteCommandInProgress)
            .accessibilityLabel(L10n.text("Minimum charge at location"))

            let locationAmpDraft = locationAmpDrafts[location.id]
            HStack {
                Text(L10n.text("Current limit")).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if let draftAmps = locationAmpDraft.map({ Int($0.rounded()) }) {
                    Text(Format.amps(draftAmps)).font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                } else if location.ampLimit > 0 {
                    Text(Format.amps(location.ampLimit)).font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                } else {
                    Text(L10n.text("Vehicle default")).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Slider(value: Binding(
                get: { locationAmpDraft ?? Double(location.ampLimit > 0 ? location.ampLimit : 16) },
                set: { locationAmpDrafts[location.id] = $0 }
            ), in: 6...32, step: 1, onEditingChanged: { editing in
                guard !editing, let draft = locationAmpDrafts[location.id] else { return }
                locationAmpDrafts[location.id] = nil
                let rounded = Int(draft.rounded())
                guard rounded != location.ampLimit else { return }
                send(.updateChargeLocationAmpLimit(id: location.id, amps: rounded))
            })
            .tint(.orange)
            .disabled(remoteCommandInProgress)
            .accessibilityLabel(L10n.text("Charging current at location"))

            Toggle(isOn: Binding(
                get: { location.optimisedChargingEnabled },
                set: { send(.setChargeLocationOptimisedCharging(id: location.id, enabled: $0)) }
            )) {
                Text(L10n.text("Optimised charging")).font(.system(size: 10.5))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(remoteCommandInProgress)
            if let modeName = location.optimisedChargingModeName {
                Text(modeName)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }

            Button(role: .destructive) {
                send(.deleteChargeLocation(id: location.id))
            } label: {
                Label(L10n.text("Delete Location"), systemImage: "trash")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(remoteCommandInProgress)
        }
        .padding(8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: Access card

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
                dimReason(cardAvailability([.lock, .unlock]))

                HStack(spacing: 8) {
                    let isLocked = state.exteriorStatus?.isLocked == true

                    if profile.permits(.locks) && features.contains(.remoteLocks) {
                        Button {
                            send(isLocked ? .unlock : .lock)
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: isLocked ? "lock.open.fill" : "lock.fill")
                                    .font(.system(size: 18))
                                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                                Text(isLocked ? L10n.text("Unlock") : L10n.text("Lock"))
                                    .font(.system(size: 12, weight: .semibold))
                                sendingOverlay(isLocked ? .unlock : .lock)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.bordered)
                        .tint(isLocked ? .blue : .green)
                        .disabled(isDisabled(isLocked ? .unlock : .lock))
                    }

                    if state.model.brand == .volvo, !isLocked,
                       profile.permits(.reducedGuardLock), features.contains(.remoteLocks) {
                        Button {
                            send(.lockReducedGuard)
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "lock.shield.fill").font(.system(size: 16))
                                Text(L10n.text("Reduced Guard")).font(.system(size: 11, weight: .medium))
                                sendingOverlay(.lockReducedGuard)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isDisabled(.lockReducedGuard))
                        .help(L10n.text("Locks the vehicle with reduced alarm guard sensitivity, when supported."))
                    }

                    if features.contains(.remoteLocks) {
                        let caps = state.otaCapabilities
                        let showTrunkUnlock = profile.permits(.trunk) && (caps?.supportsTrunkUnlock ?? profile.permits(.trunk))
                        let showTailgateControl = caps?.supportsTrunkControl ?? false

                        if showTrunkUnlock {
                            Button {
                                send(.unlockTrunk)
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: "car.side.rear.open.fill").font(.system(size: 15))
                                    Text(L10n.text("Unlock Trunk")).font(.system(size: 11, weight: .medium))
                                    sendingOverlay(.unlockTrunk)
                                }
                                .frame(maxWidth: .infinity, minHeight: 46)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isDisabled(.unlockTrunk))
                        }

                        if showTailgateControl {
                            let tailgateIsOpen = state.exteriorStatus?.isTailgateOpen ?? false
                            Button {
                                send(tailgateIsOpen ? .closeTailgate : .openTailgate)
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: tailgateIsOpen ? "car.side.rear.open.fill" : "car.side.rear.fill")
                                        .font(.system(size: 15))
                                    Text(tailgateIsOpen ? L10n.text("Close Tailgate") : L10n.text("Open Tailgate"))
                                        .font(.system(size: 11, weight: .medium))
                                    sendingOverlay(tailgateIsOpen ? .closeTailgate : .openTailgate)
                                }
                                .frame(maxWidth: .infinity, minHeight: 46)
                            }
                            .buttonStyle(.bordered)
                            .tint(tailgateIsOpen ? .orange : nil)
                            .disabled(isDisabled(tailgateIsOpen ? .closeTailgate : .openTailgate))
                        }
                    }
                }
            }
        }
        .opacity(cardOpacity([.lock, .unlock]))
    }

    // MARK: Windows / locate card

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
                dimReason(cardAvailability([.closeWindows, .honkAndFlash, .flashLights]))

                HStack(spacing: 8) {
                    if showWindows {
                        Button {
                            send(.closeWindows)
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: "rectangle.arrowtriangle.2.inward").font(.system(size: 13))
                                Text(L10n.text("Close Windows")).font(.system(size: 10, weight: .medium))
                                sendingOverlay(.closeWindows)
                            }
                            .frame(maxWidth: .infinity, minHeight: 42)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isDisabled(.closeWindows))

                        Button {
                            send(.openWindows)
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: "rectangle.arrowtriangle.2.outward").font(.system(size: 13))
                                Text(L10n.text("Vent Windows")).font(.system(size: 10, weight: .medium))
                                sendingOverlay(.openWindows)
                            }
                            .frame(maxWidth: .infinity, minHeight: 42)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isDisabled(.openWindows))
                    }

                    if showLocate {
                        let caps = state.otaCapabilities
                        let supportsHonk = caps?.supportsHonkAndFlash ?? true
                        let supportsFlashOnly = caps?.supportsFlash ?? true

                        if supportsFlashOnly {
                            Button {
                                send(.flashLights)
                            } label: {
                                VStack(spacing: 3) {
                                    Image(systemName: "flashlight.on.fill").font(.system(size: 13))
                                    Text(L10n.text("Flash Lights")).font(.system(size: 10, weight: .medium))
                                    sendingOverlay(.flashLights)
                                }
                                .frame(maxWidth: .infinity, minHeight: 42)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isDisabled(.flashLights))
                        }

                        if supportsHonk {
                            Button {
                                send(.honkAndFlash)
                            } label: {
                                VStack(spacing: 3) {
                                    Image(systemName: "light.beacon.max.fill").font(.system(size: 13))
                                    Text(L10n.text("Honk & Flash")).font(.system(size: 10, weight: .medium))
                                    sendingOverlay(.honkAndFlash)
                                }
                                .frame(maxWidth: .infinity, minHeight: 42)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isDisabled(.honkAndFlash))

                            Button {
                                send(.honkHorn)
                            } label: {
                                VStack(spacing: 3) {
                                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 13))
                                    Text(L10n.text("Honk Horn")).font(.system(size: 10, weight: .medium))
                                    sendingOverlay(.honkHorn)
                                }
                                .frame(maxWidth: .infinity, minHeight: 42)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isDisabled(.honkHorn))
                        }
                    }
                }
            }
        }
        .opacity(cardOpacity([.closeWindows, .honkAndFlash, .flashLights]))
    }

    // MARK: OTA card

    private var otaControlCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "shippingbox.fill", title: L10n.text("Vehicle Software & OTA"), color: .blue)
                dimReason(cardAvailability([.installOTANow]))
                if let software = state.softwareInfo {
                    otaStatusLine(software)
                    otaProgressLine(software)
                    otaActions(software)
                } else {
                    otaStatusRow(symbol: "questionmark.circle.fill", tint: .secondary,
                                 text: L10n.text("Software status is unavailable for this vehicle."))
                }
            }
        }
        .opacity(cardOpacity([.installOTANow]))
    }

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
        case .failed where software.hasActionableFailure():
            otaStatusRow(symbol: "exclamationmark.triangle.fill", tint: HisingenTheme.semanticWarning,
                         text: L10n.text("The last software update failed."))
        case .failed:
            otaStatusRow(symbol: "clock.arrow.circlepath", tint: .secondary,
                         text: L10n.text("An older software event is recorded, but no current update failure requires attention."))
        case .completed:
            let installed = software.installedVersion ?? software.version
            otaStatusRow(symbol: "checkmark.circle.fill", tint: HisingenTheme.semanticGood,
                         text: installed.map { L10n.format("Backend reports installation completed for version %@.", $0) }
                            ?? L10n.text("Backend reports that installation completed."))
        case .unknown:
            otaStatusRow(symbol: "questionmark.circle", tint: .secondary,
                         text: L10n.text("Software status is unavailable; the app cannot confirm that the vehicle is up to date."))
        }
    }

    /// Indeterminate progress plus the backend's own duration estimate while a download or
    /// install is in flight — previously the card just showed a one-line status.
    @ViewBuilder
    private func otaProgressLine(_ software: VehicleSoftwareInfo) -> some View {
        if software.state == .downloading || software.state == .installing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.8)
                if let seconds = software.estimatedInstallDurationSeconds, seconds > 0 {
                    Text(L10n.format("Estimated %d min", max(1, seconds / 60)))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func otaActions(_ software: VehicleSoftwareInfo) -> some View {
        switch software.state {
        case .downloaded, .deferred:
            VStack(spacing: 6) {
                otaButton(title: L10n.text("Install Update Now"), symbol: "arrow.down.circle.fill",
                          command: .installOTANow, prominent: true)
                otaScheduleRow
            }
        case .scheduled:
            VStack(spacing: 6) {
                otaButton(title: L10n.text("Install Update Now"), symbol: "arrow.down.circle.fill",
                          command: .installOTANow, prominent: true)
                otaButton(title: L10n.text("Cancel Scheduled Installation"), symbol: "xmark.circle",
                          command: .cancelOTA, prominent: false)
            }
        case .available, .downloading, .installing, .failed, .completed, .unknown:
            EmptyView()
        }
    }

    private var otaScheduleRow: some View {
        HStack(spacing: 6) {
            Picker("", selection: $otaScheduleDelayMinutes) {
                Text(L10n.format("In %d h", 2)).tag(120)
                Text(L10n.format("In %d h", 8)).tag(480)
                Text(L10n.format("In %d h", 12)).tag(720)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            Button {
                send(.scheduleOTA(delayMinutes: otaScheduleDelayMinutes))
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar.badge.plus")
                    Text(L10n.text("Schedule")).font(.system(size: 10, weight: .medium))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isDisabled(.scheduleOTA(delayMinutes: otaScheduleDelayMinutes)))
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
    private func otaButton(title: String, symbol: String, command: RemoteCommand,
                           prominent: Bool) -> some View {
        let label = HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(title)
            sendingOverlay(command)
        }
        .frame(maxWidth: .infinity)

        if prominent {
            Button { send(command) } label: { label }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.regular)
                .disabled(isDisabled(command))
        } else {
            Button { send(command) } label: { label }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(isDisabled(command))
        }
    }

    // MARK: Engine card

    private var engineStartControlCard: some View {
        let startCommand = RemoteCommand.startEngine(runtimeMinutes: engineRuntimeMinutes)
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    CardHeader(symbol: "flame.fill", title: L10n.text("Remote Engine Start (RES)"), color: .orange)
                    Spacer()
                    if state.isEngineRunning == true {
                        HStack(spacing: 4) {
                            Circle().fill(HisingenTheme.semanticGood).frame(width: 6, height: 6)
                            Text(L10n.text("Engine Running"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(HisingenTheme.semanticGood)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(HisingenTheme.semanticGood.opacity(0.12), in: Capsule())
                    } else if state.isEngineRunning == false {
                        Text(L10n.text("Engine Stopped"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    } else {
                        Text(L10n.text("Status Unavailable"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                dimReason(cardAvailability([startCommand]))

                Text(L10n.text("Starts combustion engine to precondition cabin temperature before departure."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack {
                    Text(L10n.text("Runtime")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $engineRuntimeMinutes) {
                        Text(L10n.format("%d min", 5)).tag(5)
                        Text(L10n.format("%d min", 10)).tag(10)
                        Text(L10n.format("%d min", 15)).tag(15)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 170)
                    .disabled(isDisabled(startCommand) || (state.isEngineRunning == true))
                    .onChange(of: engineRuntimeMinutes) { _, newValue in
                        preferences.remoteEngineRuntimeMinutes = newValue
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        send(startCommand)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "flame.fill")
                            Text(L10n.format("Start Engine (%d min)", engineRuntimeMinutes))
                                .font(.system(size: 11, weight: .medium))
                            sendingOverlay(startCommand)
                        }
                        .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(isDisabled(startCommand) || (state.isEngineRunning == true))

                    Button {
                        send(.stopEngine)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "stop.fill")
                            Text(L10n.text("Stop Engine")).font(.system(size: 11, weight: .medium))
                            sendingOverlay(.stopEngine)
                        }
                        .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDisabled(.stopEngine) || (state.isEngineRunning != true))
                }
            }
        }
        .opacity(cardOpacity([startCommand]))
    }

    private var noControlsEnabledCard: some View {
        Card {
            VStack(spacing: 8) {
                Image(systemName: "switch.2").font(.system(size: 24)).foregroundStyle(.secondary)
                Text(L10n.text("No Remote Controls Enabled"))
                    .font(.system(size: 13, weight: .semibold))
                Text(L10n.text("Enable remote controls in Settings under Telemetry & Features to display controls here."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if state.probedCapabilities == nil {
                    reprobeFooter
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }
}

// MARK: - Add-charge-location sheet

@MainActor
struct ChargeLocationEditorSheet: View {
    let defaultAmpLimit: Int
    let onSave: (_ alias: String, _ ampLimit: Int, _ minimumSoc: Int, _ optimisedCharging: Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var alias: String = ""
    @State private var ampLimit: Double = 16
    @State private var minimumSoc: Double = 0
    @State private var optimised: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(HisingenTheme.accent)
                Text(L10n.text("Save Charge Location"))
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.text("Saves the vehicle's current position. Do this while parked where you normally charge."))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("Name")).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        TextField(L10n.text("Home, Office…"), text: $alias)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L10n.text("Current limit")).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.amps(Int(ampLimit.rounded()))).font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        Slider(value: $ampLimit, in: 6...32, step: 1).tint(.orange)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L10n.text("Minimum charge")).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.percent(minimumSoc)).font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        Slider(value: $minimumSoc, in: 0...100, step: 5).tint(.green)
                    }

                    Toggle(L10n.text("Optimised charging"), isOn: $optimised)
                        .font(.system(size: 11))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .padding(16)
            }

            Divider().opacity(0.4)
            HStack {
                Button(L10n.text("Cancel")) { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
                Button(L10n.text("Save")) {
                    onSave(alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? L10n.text("Charge location") : alias.trimmingCharacters(in: .whitespacesAndNewlines),
                           Int(ampLimit.rounded()), Int(minimumSoc.rounded()), optimised)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(HisingenTheme.accent)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 360, height: 380)
        .background(HisingenTheme.canvas)
        .onAppear { ampLimit = Double(min(32, max(6, defaultAmpLimit))) }
    }
}

struct SpinningFanView: View {
    let isSpinning: Bool
    var size: CGFloat = 13
    var color: Color = .orange

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0

    private var shouldSpin: Bool { isSpinning && !reduceMotion }

    var body: some View {
        Image(systemName: "fan.fill")
            .font(.system(size: size))
            .foregroundStyle(color)
            .rotationEffect(.degrees(angle))
            .onAppear { if shouldSpin { startSpinning() } }
            .onChange(of: shouldSpin) { _, spinning in
                if spinning {
                    startSpinning()
                } else {
                    withAnimation(.easeOut(duration: 0.4)) { angle = 0 }
                }
            }
            .accessibilityHidden(true)
    }

    private func startSpinning() {
        withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
            angle = 360
        }
    }
}
