import SwiftUI

@MainActor
struct VehicleSoftwareCard: View {
    let state: VehicleState
    let software: VehicleSoftwareInfo
    let preferences: PreferencesStore
    @Binding var dismissedSoftwareEventIdentifier: String?

    static func make(state: VehicleState, features: FeatureSelection, preferences: PreferencesStore, dismissedSoftwareEventIdentifier: Binding<String?>) -> AnyView? {
        guard features.contains(.softwareUpdates) else { return nil }
        guard let software = state.softwareInfo else {
            guard !state.isVolvo else { return nil }
            return AnyView(Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(symbol: "gearshape.2.fill", title: L10n.text("Vehicle Software"), color: .blue)
                    CapabilityBadge(title: L10n.text("Software status"), state: .unavailable)
                }
            })
        }
        return AnyView(Self(state: state, software: software, preferences: preferences, dismissedSoftwareEventIdentifier: dismissedSoftwareEventIdentifier))
    }

    private var eventDismissed: Bool { dismissedSoftwareEventIdentifier == software.eventIdentifier }

    private var rows: [KVRow] {
        var rows: [KVRow] = []
        if let installed = software.installedVersion {
            rows.append(KVRow(L10n.text("Backend-Reported Version"), installed, symbol: "checkmark.seal.fill", info: L10n.text("Reported by an undocumented Polestar backend field. Treat as unverified until it matches the version shown in the vehicle.")))
        }
        if let latest = software.latestAvailableVersion {
            rows.append(KVRow(software.rawState == .updateAvailable ? L10n.text("Announced Version") : L10n.text("Update Version"), latest, symbol: "shippingbox.fill"))
        }
        if let title = software.title { rows.append(KVRow(L10n.text("Release"), title, symbol: "doc.text")) }
        if let summary = software.shortDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty, summary != software.title { rows.append(KVRow(L10n.text("Summary"), summary, symbol: "doc.plaintext")) }
        if let minutes = software.scheduleRelativeMinutes, minutes > 0 { rows.append(KVRow(L10n.text("Installs In"), L10n.format("%d min", minutes), symbol: "hourglass")) }
        let status = software.state == .failed && !software.hasActionableFailure() ? L10n.text("Past event — no current action required") : software.statusDisplayName
        rows.append(KVRow(L10n.text("Update Status"), status, symbol: "arrow.triangle.2.circlepath", valueWarning: software.hasActionableFailure() && !eventDismissed))
        if let scheduled = software.scheduledAt {
            rows.append(KVRow(L10n.text("Installation Scheduled"), Format.dateTimeFormatter.string(from: scheduled), symbol: "calendar.badge.clock"))
            if let setter = software.scheduleSetBy, setter != .unknown { rows.append(KVRow(L10n.text("Scheduled By"), setter.displayName, symbol: "person.crop.circle")) }
        }
        if let updated = software.updatedAt { rows.append(KVRow(L10n.text("Last Updated"), Format.dateTimeFormatter.string(from: updated), symbol: "clock.arrow.circlepath")) }
        if let duration = software.estimatedInstallDurationSeconds, duration / 60 > 0 { rows.append(KVRow(L10n.text("Install Duration"), L10n.format("%d min", duration / 60), symbol: "timer")) }
        return rows
    }

    private var updateInstallable: Bool {
        software.rawState?.isInstallable ?? (software.state == .downloaded || software.state == .deferred || software.state == .scheduled)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "gearshape.2.fill", title: L10n.text("Vehicle Software"), color: .blue)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
                if updateInstallable {
                    Divider().opacity(0.4)
                    HStack {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                        Text(L10n.format("Version %@ is ready to install in Controls.", software.latestAvailableVersion ?? software.version ?? "—"))
                            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(HisingenTheme.ink)
                    }
                }
                if software.state == .failed { failedEventControls }
                if software.rawState == .updateAvailable { waitingForAuthorization }
                if let notes = software.longDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                    Divider().opacity(0.4)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("Release notes")).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(HisingenTheme.ink)
                        Text(Self.strippedReleaseNotes(notes)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if let code = software.qbCode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty,
                   code.lowercased() != software.latestAvailableVersion?.lowercased(), code.lowercased() != software.installedVersion?.lowercased() {
                    Divider().opacity(0.4)
                    Text(L10n.format("Build code: %@", code)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let originator = software.originator?.trimmingCharacters(in: .whitespacesAndNewlines), !originator.isEmpty {
                    Divider().opacity(0.4)
                    Text(L10n.format("Schedule originator: %@", originator)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var failedEventControls: some View {
        Group {
            Divider().opacity(0.4)
            Button {
                let identifier = eventDismissed ? nil : software.eventIdentifier
                preferences.setDismissedSoftwareEventIdentifier(identifier, for: state.identity.vin)
                dismissedSoftwareEventIdentifier = identifier
            } label: {
                Label(eventDismissed ? L10n.text("Restore software event") : L10n.text("Dismiss software event"), systemImage: eventDismissed ? "arrow.uturn.backward.circle" : "xmark.circle")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .buttonStyle(.borderless)
            Text(eventDismissed ? L10n.text("This event is hidden from Needs Attention on this Mac.") : L10n.text("Dismissal is local and does not alter vehicle or Polestar backend data."))
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
    }

    private var waitingForAuthorization: some View {
        Group {
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange).font(.system(size: 10.5))
                    Text(L10n.text("Waiting for backend authorization")).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.orange)
                }
                Text(L10n.text("The update has been announced but not yet authorized for download. Polestar releases major updates in batches — your VIN may not be in the current cohort. The car downloads it automatically once the backend authorizes it."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if let updated = software.updatedAt { Text(L10n.format("Announced: %@", Format.dateTimeFormatter.string(from: updated))).font(.system(size: 10)).foregroundStyle(.secondary) }
                Text(state.otaCapabilities?.supportsCloudBasedOtaDownloadConsent == false
                    ? L10n.text("This vehicle does not support cloud-based download consent — the update can only be downloaded when the car checks in with the backend autonomously. A Polestar service appointment can apply it directly.")
                    : L10n.text("If the update has been waiting for a long time, contact Polestar Support or book a service appointment — workshops can apply it directly."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    nonisolated static func strippedReleaseNotes(_ html: String) -> String {
        var text = html
        if let open = text.range(of: "<textblock>"), let close = text.range(of: "</textblock>"), open.lowerBound < close.lowerBound {
            text = String(text[open.upperBound..<close.lowerBound])
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return text.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
