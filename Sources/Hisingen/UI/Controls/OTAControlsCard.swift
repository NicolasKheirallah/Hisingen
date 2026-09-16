import SwiftUI

@MainActor
struct OTAControlsCard: View {
    let state: VehicleState
    let gate: ControlsCommandGate
    /// Asks the host to re-read the vehicle, so a failed install has somewhere to go.
    let onRefresh: () -> Void

    @State private var otaScheduleDelayMinutes: Int = 120
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(
                    symbol: "shippingbox.fill",
                    title: L10n.text("Vehicle Software & OTA"),
                    color: HisingenTheme.semanticActive
                )
                gate.dimReason(gate.liveAvailability([.installOTANow]))
                if let software = state.softwareInfo {
                    // One keyed animation drives the whole status morph: symbol
                    // replace-crossfade, progress line and action groups in/out.
                    Group {
                        otaStatusLine(software)
                        otaProgressLine(software)
                        otaActions(software)
                    }
                    .hisAnimation(Motion.stateChange, value: software.state)
                } else {
                    otaStatusRow(
                        symbol: "questionmark.circle.fill",
                        tint: .secondary,
                        text: L10n.text("Software status is unavailable for this vehicle.")
                    )
                }
            }
        }
        .opacity(gate.liveOpacity([.installOTANow]))
        .hisAnimation(Motion.stateChange, value: gate.liveAvailability([.installOTANow]))
    }

    @ViewBuilder
    private func otaStatusLine(_ software: VehicleSoftwareInfo) -> some View {
        let pending = software.latestAvailableVersion ?? software.version
        switch software.state {
        case .available:
            otaStatusRow(
                symbol: "arrow.down.circle",
                tint: HisingenTheme.semanticActive,
                text: pending.map {
                    L10n.format(
                        "Software update %@ is available. The vehicle downloads it automatically; it can be installed once that finishes.",
                        $0
                    )
                } ?? L10n.text("A software update is available. The vehicle downloads it automatically.")
            )
        case .downloaded, .deferred:
            otaStatusRow(
                symbol: "arrow.down.circle.fill",
                tint: HisingenTheme.semanticActive,
                text: pending.map { L10n.format("Software update %@ is ready to install.", $0) }
                    ?? L10n.text("A software update is ready to install.")
            )
        case .downloading:
            otaStatusRow(
                symbol: "arrow.down.circle",
                tint: HisingenTheme.semanticActive,
                text: pending.map { L10n.format("Downloading software update %@…", $0) }
                    ?? L10n.text("Downloading a software update…")
            )
        case .installing:
            otaStatusRow(
                symbol: "gearshape.2.fill",
                tint: HisingenTheme.semanticActive,
                text: pending.map { L10n.format("Installing software update %@…", $0) }
                    ?? L10n.text("Installing a software update…")
            )
        case .scheduled:
            let when = software.scheduledAt.map(Format.dateTimeFormatter.string(from:))
            otaStatusRow(
                symbol: "calendar.badge.clock",
                tint: HisingenTheme.semanticActive,
                text: when.map { L10n.format("Installation is scheduled for %@.", $0) }
                    ?? L10n.text("An installation is scheduled.")
            )
        case .failed where software.hasActionableFailure():
            otaStatusRow(
                symbol: "exclamationmark.triangle.fill",
                tint: HisingenTheme.semanticWarning,
                text: L10n.text("The last software update failed.")
            )
            // The card narrated the failure and then offered nothing at all: no retry, no re-check,
            // no route onward. The only re-probe button on the tab appears for a different
            // condition, so a user who hit this was stuck with a sentence.
            Button(action: onRefresh) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                    Text(L10n.text("Re-check Software Status"))
                        .hisType(.caption, weight: .medium)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(L10n.text("Checks the vehicle again for the current software status."))
            .transition(.opacity)
        case .failed:
            otaStatusRow(
                symbol: "clock.arrow.circlepath",
                tint: .secondary,
                text: L10n.text("An older software event is recorded, but no current update failure requires attention.")
            )
        case .completed:
            let installed = software.installedVersion ?? software.version
            otaStatusRow(
                symbol: "checkmark.circle.fill",
                tint: HisingenTheme.semanticGood,
                text: installed.map { L10n.format("Backend reports installation completed for version %@.", $0) }
                    ?? L10n.text("Backend reports that installation completed.")
            )
        case .unknown:
            otaStatusRow(
                symbol: "questionmark.circle",
                tint: .secondary,
                text: L10n.text("Software status is unavailable; the app cannot confirm that the vehicle is up to date.")
            )
        }
    }

    @ViewBuilder
    private func otaProgressLine(_ software: VehicleSoftwareInfo) -> some View {
        if software.state == .downloading || software.state == .installing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.8)
                if let seconds = software.estimatedInstallDurationSeconds, seconds > 0 {
                    Text(L10n.format("Estimated %d min", max(1, seconds / 60)))
                        .hisType(.micro)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func otaActions(_ software: VehicleSoftwareInfo) -> some View {
        switch software.state {
        case .downloaded, .deferred:
            VStack(spacing: 6) {
                otaButton(
                    title: L10n.text("Install Update Now"),
                    symbol: "arrow.down.circle.fill",
                    command: .installOTANow,
                    prominent: true
                )
                otaScheduleRow
            }
            .transition(.opacity)
        case .scheduled:
            VStack(spacing: 6) {
                otaButton(
                    title: L10n.text("Install Update Now"),
                    symbol: "arrow.down.circle.fill",
                    command: .installOTANow,
                    prominent: true
                )
                otaButton(
                    title: L10n.text("Cancel Scheduled Installation"),
                    symbol: "xmark.circle",
                    command: .cancelOTA,
                    prominent: false
                )
            }
            .transition(.opacity)
        case .available, .downloading, .installing, .failed, .completed, .unknown:
            // A failure that still requires attention renders its own action beside the status
            // line, because it is the state's explanation and its way out together.
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
                gate.send(.scheduleOTA(delayMinutes: otaScheduleDelayMinutes))
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar.badge.plus")
                    Text(L10n.text("Schedule")).hisType(.caption, weight: .medium)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(gate.isDisabled(.scheduleOTA(delayMinutes: otaScheduleDelayMinutes)))
        }
    }

    private func otaStatusRow(symbol: String, tint: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            Text(text)
                .hisType(.label, weight: .medium)
                .foregroundStyle(HisingenTheme.ink)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func otaButton(
        title: String,
        symbol: String,
        command: RemoteCommand,
        prominent: Bool
    ) -> some View {
        let label = HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(title)
            gate.sendingOverlay(command)
        }
        .frame(maxWidth: .infinity)

        if prominent {
            Button { gate.send(command) } label: { label }
                .buttonStyle(.borderedProminent)
                .tint(HisingenTheme.semanticActive)
                .controlSize(.regular)
                .disabled(gate.isDisabled(command))
        } else {
            Button { gate.send(command) } label: { label }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(gate.isDisabled(command))
        }
    }
}
