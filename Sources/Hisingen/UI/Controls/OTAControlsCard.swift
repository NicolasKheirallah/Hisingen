import SwiftUI

@MainActor
struct OTAControlsCard: View {
    let state: VehicleState
    let gate: ControlsCommandGate

    @State private var otaScheduleDelayMinutes: Int = 120

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(
                    symbol: "shippingbox.fill",
                    title: L10n.text("Vehicle Software & OTA"),
                    color: .blue
                )
                gate.dimReason(gate.cardAvailability([.installOTANow]))
                if let software = state.softwareInfo {
                    otaStatusLine(software)
                    otaProgressLine(software)
                    otaActions(software)
                } else {
                    otaStatusRow(
                        symbol: "questionmark.circle.fill",
                        tint: .secondary,
                        text: L10n.text("Software status is unavailable for this vehicle.")
                    )
                }
            }
        }
        .opacity(gate.cardOpacity([.installOTANow]))
    }

    @ViewBuilder
    private func otaStatusLine(_ software: VehicleSoftwareInfo) -> some View {
        let pending = software.latestAvailableVersion ?? software.version
        switch software.state {
        case .available:
            otaStatusRow(
                symbol: "arrow.down.circle",
                tint: .blue,
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
                tint: .blue,
                text: pending.map { L10n.format("Software update %@ is ready to install.", $0) }
                    ?? L10n.text("A software update is ready to install.")
            )
        case .downloading:
            otaStatusRow(
                symbol: "arrow.down.circle",
                tint: .blue,
                text: pending.map { L10n.format("Downloading software update %@…", $0) }
                    ?? L10n.text("Downloading a software update…")
            )
        case .installing:
            otaStatusRow(
                symbol: "gearshape.2.fill",
                tint: .blue,
                text: pending.map { L10n.format("Installing software update %@…", $0) }
                    ?? L10n.text("Installing a software update…")
            )
        case .scheduled:
            let when = software.scheduledAt.map(Format.dateTimeFormatter.string(from:))
            otaStatusRow(
                symbol: "calendar.badge.clock",
                tint: .blue,
                text: when.map { L10n.format("Installation is scheduled for %@.", $0) }
                    ?? L10n.text("An installation is scheduled.")
            )
        case .failed where software.hasActionableFailure():
            otaStatusRow(
                symbol: "exclamationmark.triangle.fill",
                tint: HisingenTheme.semanticWarning,
                text: L10n.text("The last software update failed.")
            )
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
                otaButton(
                    title: L10n.text("Install Update Now"),
                    symbol: "arrow.down.circle.fill",
                    command: .installOTANow,
                    prominent: true
                )
                otaScheduleRow
            }
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
                gate.send(.scheduleOTA(delayMinutes: otaScheduleDelayMinutes))
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar.badge.plus")
                    Text(L10n.text("Schedule")).font(.system(size: 10, weight: .medium))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(gate.isDisabled(.scheduleOTA(delayMinutes: otaScheduleDelayMinutes)))
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
                .tint(.blue)
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
