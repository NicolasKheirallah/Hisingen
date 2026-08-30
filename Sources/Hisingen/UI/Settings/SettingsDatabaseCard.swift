import SwiftUI
import UniformTypeIdentifiers

/// SQLite storage statistics, maintenance actions, and history exports — extracted from
/// `SettingsView` so data-management UI lives beside the persistence layer it drives.
@MainActor
struct SettingsDatabaseCard: View {
    let state: VehicleState?
    let database: VehicleDatabase
    @Binding var persistLocationHistory: Bool

    @Environment(\.preferencesStore) private var preferences

    @State private var vacuumed = false
    @State private var pruned = false
    @State private var isMaintaining = false
    @State private var showPruneConfirmation = false
    @State private var showLocationClearConfirmation = false
    @State private var showWipeConfirmation = false
    @State private var showAPIDiagnosticInspector = false
    @State private var retentionDays = 90
    @State private var eraseHistoryOnSignOut = false
    @State private var feedback: (message: String, isError: Bool)?
    @State private var stats = Stats(
        counts: (snapshots: 0, chargingSessions: 0, chargingSamples: 0,
                 batteryHealth: 0, telemetry: 0, commands: 0),
        sizeBytes: 0)

    struct Stats: Sendable {
        let counts: (snapshots: Int, chargingSessions: Int, chargingSamples: Int,
                     batteryHealth: Int, telemetry: Int, commands: Int)
        let sizeBytes: Int64
    }

    var body: some View {
    let counts = stats.counts
    let sizeStr = ByteCountFormatter.string(fromByteCount: stats.sizeBytes, countStyle: .file)

    Card {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: "cylinder.split.1x2.fill", title: L10n.text("SQLite Storage & Data"), color: .blue)

            VStack(spacing: 6) {
                KVRow(L10n.text("Database Engine"), "SQLite 3 · WAL Mode", symbol: "server.rack")
                KVRow(L10n.text("Storage Size"), sizeStr, symbol: "internaldrive")
                KVRow(L10n.text("Vehicle Snapshots"), "\(counts.snapshots)", symbol: "car.side.fill")
                KVRow(L10n.text("Charging Sessions"), "\(counts.chargingSessions) (\(counts.chargingSamples) samples)", symbol: "bolt.fill")
                KVRow(L10n.text("Battery Health Logs"), "\(counts.batteryHealth)", symbol: "heart.fill")
                KVRow(L10n.text("Telemetry Entries"), "\(counts.telemetry)", symbol: "chart.xyaxis.line")
                KVRow(L10n.text("Remote Command Audit"), "\(counts.commands)", symbol: "checklist")
            }

            Divider().opacity(0.4)

            HStack(spacing: 8) {
                Image(systemName: "location.slash.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("Store precise location history"))
                        .font(.system(size: 11, weight: .medium))
                    Text(L10n.text("Off by default. Live parking location still works, but coordinates are not written to history."))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $persistLocationHistory)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: persistLocationHistory) { _, value in
                        if value {
                            preferences.persistLocationHistory = true
                        } else if preferences.persistLocationHistory {
                            // Clearing retained coordinates is destructive; keep the
                            // effective value on until the user confirms it below.
                            persistLocationHistory = true
                            showLocationClearConfirmation = true
                        }
                    }
                    .accessibilityLabel(L10n.text("Store precise location history"))
            }

            Divider().opacity(0.4)
                .padding(.vertical, 2)

            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.2.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("Erase local history on sign out"))
                        .font(.system(size: 11, weight: .medium))
                    Text(L10n.text("Off by default. Signing out keeps charging, trip and health history on this Mac; turn on to remove it with the session."))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $eraseHistoryOnSignOut)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: eraseHistoryOnSignOut) { _, value in
                        preferences.eraseHistoryOnSignOut = value
                    }
                    .accessibilityLabel(L10n.text("Erase local history on sign out"))
            }

            Divider().opacity(0.4)
                .padding(.vertical, 2)

            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("High-volume sample retention"))
                        .font(.system(size: 11, weight: .medium))
                    Text(L10n.text("Used by Prune Old Samples; charging summaries are retained longer."))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $retentionDays) {
                    ForEach([30, 90, 180, 365], id: \.self) { days in
                        Text(L10n.format("%d days", days)).tag(days)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 90)
                .onChange(of: retentionDays) { _, value in preferences.historySampleRetentionDays = value }
                .accessibilityLabel(L10n.text("High-volume sample retention"))
            }

            Divider().opacity(0.4)
                .padding(.vertical, 2)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        runMaintenance(.vacuum)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: vacuumed ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                            Text(vacuumed ? L10n.text("Optimized!") : L10n.text("Vacuum & Checkpoint"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(vacuumed ? HisingenTheme.semanticGood : nil)
                    .disabled(isMaintaining)

                    Button {
                        showPruneConfirmation = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: pruned ? "checkmark.circle.fill" : "clock.arrow.circlepath")
                            Text(pruned ? L10n.text("Pruned!") : L10n.text("Prune Old Samples"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(pruned ? HisingenTheme.semanticGood : nil)
                    .disabled(isMaintaining)
                }

                if isMaintaining {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("Database maintenance in progress…"))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }

                if let feedback {
                    Label(feedback.message, systemImage: feedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(feedback.isError ? Color.red : HisingenTheme.semanticGood)
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Button {
                        let vin = state?.vin
                        let db = database
                        Task { @MainActor in
                            let csv = await Task.detached(priority: .userInitiated) {
                                db.exportChargingSessionsCSV(for: vin)
                            }.value
                            saveCSVWithPanel(suggestedFilename: "charging_sessions_\(vin?.prefix(8) ?? "all").csv", csvContent: csv)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                            Text(L10n.text("Export Charging (CSV)"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        let vin = state?.vin
                        let db = database
                        Task { @MainActor in
                            let csv = await Task.detached(priority: .userInitiated) {
                                db.exportBatteryHealthCSV(for: vin)
                            }.value
                            saveCSVWithPanel(suggestedFilename: "battery_health_\(vin?.prefix(8) ?? "all").csv", csvContent: csv)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                            Text(L10n.text("Export Health (CSV)"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                HStack(spacing: 8) {
                    Button {
                        guard let vin = state?.vin else { return }
                        let db = database
                        Task { @MainActor in
                            let csv = await Task.detached(priority: .userInitiated) {
                                db.exportTelemetryCSV(for: vin)
                            }.value
                            saveCSVWithPanel(suggestedFilename: "telemetry_\(vin.prefix(8)).csv", csvContent: csv)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                            Text(L10n.text("Export Trips (CSV)"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(state == nil)

                    Button {
                        guard let vin = state?.vin else { return }
                        let db = database
                        Task { @MainActor in
                            let csv = await Task.detached(priority: .userInitiated) {
                                db.exportCommandAuditsCSV(for: vin)
                            }.value
                            saveCSVWithPanel(suggestedFilename: "command_audit_\(vin.prefix(8)).csv", csvContent: csv)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                            Text(L10n.text("Export Commands (CSV)"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(state == nil)
                }

                Button {
                    guard let vin = state?.vin else { return }
                    let db = database
                    Task { @MainActor in
                        let csv = await Task.detached(priority: .userInitiated) {
                            db.exportAirQualityCSV(for: vin)
                        }.value
                        saveCSVWithPanel(suggestedFilename: "air_quality_\(vin.prefix(8)).csv", csvContent: csv)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                        Text(L10n.text("Export Air Quality (CSV)"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    // Full local-history backup across every stored vehicle.
                    // Coordinates are included only when location history is opted in,
                    // mirroring the retention preference elsewhere in this pane.
                    let includeCoords = preferences.persistLocationHistory
                    let db = database
                    Task { @MainActor in
                        let data: Data? = await Task.detached(priority: .userInitiated) {
                            try? db.exportBackupJSON(includeCoordinates: includeCoords)
                        }.value
                        guard let data else {
                            feedback = (L10n.text("The backup could not be created."), true)
                            return
                        }
                        saveDataWithPanel(
                            suggestedFilename: "hisingen_backup_\(Int(Date().timeIntervalSince1970)).json",
                            contentType: .json,
                            data: data
                        )
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "archivebox")
                        Text(L10n.text("Export All History (JSON)"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    showAPIDiagnosticInspector = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform.path.ecg.rectangle")
                        Text(L10n.text("Inspect Live API Log"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L10n.text("Shows the in-memory redacted request log with live filters. No raw credentials, VINs, or locations are retained."))

                Button {
                    let db = database
                    Task { @MainActor in
                        let data = await Task.detached(priority: .userInitiated) {
                            try? await DiagnosticLogExporter.buildReport(database: db)
                        }.value
                        guard let data else {
                            feedback = (L10n.text("The diagnostic report could not be created."), true)
                            return
                        }
                        saveDataWithPanel(
                            suggestedFilename: "hisingen_diagnostics_\(Int(Date().timeIntervalSince1970)).json",
                            contentType: .json,
                            data: data
                        )
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.badge.clock")
                        Text(L10n.text("Export Diagnostic Logs"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L10n.text("Bundles recent app log entries, refresh diagnostics, and redacted API request metadata into one file you can attach to a bug report."))

                Button(role: .destructive) {
                    showWipeConfirmation = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text(state == nil ? L10n.text("Erase All Local Vehicle Data") : L10n.text("Erase This Vehicle’s Local Data"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .disabled(isMaintaining)
            }
        }
    }
    .task {
        persistLocationHistory = preferences.persistLocationHistory
        retentionDays = preferences.historySampleRetentionDays
        eraseHistoryOnSignOut = preferences.eraseHistoryOnSignOut
        await loadStats()
    }
    .sheet(isPresented: $showAPIDiagnosticInspector) {
        APIDiagnosticInspectorView()
    }
    .confirmationDialog(
        L10n.text("Prune old historical samples?"),
        isPresented: $showPruneConfirmation,
        titleVisibility: .visible
    ) {
        Button(L10n.format("Prune Samples Older Than %d Days", retentionDays), role: .destructive) {
            runMaintenance(.prune)
        }
        Button(L10n.text("Cancel"), role: .cancel) {}
    } message: {
        Text(L10n.format("Charging samples and telemetry older than %d days will be permanently removed. Summary sessions are kept.", retentionDays))
    }
    .confirmationDialog(
        L10n.text("Stop storing and clear saved locations?"),
        isPresented: $showLocationClearConfirmation,
        titleVisibility: .visible
    ) {
        Button(L10n.text("Turn Off & Clear Locations"), role: .destructive) {
            runMaintenance(.clearLocations)
        }
        Button(L10n.text("Cancel"), role: .cancel) {}
    } message: {
        Text(state == nil
             ? L10n.text("Saved coordinates for every vehicle will be permanently removed. Live parking location will still work.")
             : L10n.text("Saved coordinates for the current vehicle will be permanently removed. Live parking location will still work."))
    }
    .confirmationDialog(
        state == nil ? L10n.text("Erase all local vehicle data?") : L10n.text("Erase this vehicle’s local data?"),
        isPresented: $showWipeConfirmation,
        titleVisibility: .visible
    ) {
        Button(L10n.text("Erase Permanently"), role: .destructive) { runMaintenance(.wipe) }
        Button(L10n.text("Cancel"), role: .cancel) {}
    } message: {
        Text(L10n.text("Snapshots, cached images, charging and fuel history, telemetry, health logs, air quality, and command audits will be permanently removed. Account credentials are kept."))
    }
}

    private enum MaintenanceOperation: Equatable { case vacuum, prune, clearLocations, wipe }

    private func runMaintenance(_ operation: MaintenanceOperation) {
        guard !isMaintaining else { return }
        isMaintaining = true
        feedback = nil
        let db = database
        let selectedRetentionDays = retentionDays
        let selectedVIN = state?.vin
        Task { @MainActor in
            do {
                try await Task.detached(priority: .utility) {
                    switch operation {
                    case .vacuum: try db.vacuumOrThrow()
                    case .prune: try db.pruneHistoricalSamplesOrThrow(olderThanDays: selectedRetentionDays)
                    case .clearLocations: try db.clearStoredLocationsOrThrow(for: selectedVIN)
                    case .wipe: try db.wipeAllOrThrow(for: selectedVIN)
                    }
                }.value
                if operation == .clearLocations {
                    preferences.persistLocationHistory = false
                    persistLocationHistory = false
                    preferences.clearLegacyVehicleCaches(for: selectedVIN, includeBaselines: false)
                } else if operation == .wipe {
                    preferences.clearLegacyVehicleCaches(for: selectedVIN)
                }
                await loadStats()
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    vacuumed = operation == .vacuum
                    pruned = operation == .prune
                }
                switch operation {
                case .vacuum: feedback = (L10n.text("Database optimization completed."), false)
                case .prune: feedback = (L10n.text("Old historical samples were pruned."), false)
                case .clearLocations: feedback = (L10n.text("Saved location history was cleared."), false)
                case .wipe: feedback = (L10n.text("Local vehicle data was erased."), false)
                }
            } catch {
                feedback = (L10n.format("Database maintenance failed: %@", error.localizedDescription), true)
            }
            isMaintaining = false
        }
    }

    private func loadStats() async {
        let db = database
        let loaded = await Task.detached(priority: .utility) {
            Stats(counts: db.recordCounts(), sizeBytes: db.databaseSizeBytes)
        }.value
        guard !Task.isCancelled else { return }
        stats = loaded
    }

    private func saveCSVWithPanel(suggestedFilename: String, csvContent: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = suggestedFilename
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try csvContent.write(to: url, atomically: true, encoding: .utf8)
                    feedback = (L10n.text("Export saved."), false)
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                } catch {
                    feedback = (L10n.format("Export failed: %@", error.localizedDescription), true)
                }
            }
        }
    }

    private func saveDataWithPanel(suggestedFilename: String, contentType: UTType, data: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = suggestedFilename
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try data.write(to: url, options: .atomic)
                    feedback = (L10n.text("Export saved."), false)
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                } catch {
                    feedback = (L10n.format("Export failed: %@", error.localizedDescription), true)
                }
            }
        }
    }
}
