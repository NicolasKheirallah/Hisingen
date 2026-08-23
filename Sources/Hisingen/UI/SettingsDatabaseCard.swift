import SwiftUI
import UniformTypeIdentifiers

/// SQLite storage statistics, maintenance actions, and history exports — extracted from
/// `SettingsView` so data-management UI lives beside the persistence layer it drives.
@MainActor
struct SettingsDatabaseCard: View {
    let state: VehicleState?
    let database: VehicleDatabase

    @Environment(\.preferencesStore) private var preferences

    @State private var persistLocationHistory = false

    @State private var vacuumed = false
    @State private var pruned = false
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
                        preferences.persistLocationHistory = value
                        if !value { database.clearStoredLocations(for: state?.vin) }
                    }
            }

            Divider().opacity(0.4)
                .padding(.vertical, 2)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        // VACUUM rewrites the whole database file; never on the main thread.
                        let db = database
                        Task.detached(priority: .utility) { db.vacuum() }
                        Task { await loadStats() }
                        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            vacuumed = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                vacuumed = false
                            }
                        }
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

                    Button {
                        let db = database
                        Task.detached(priority: .utility) { db.pruneHistoricalSamples(olderThanDays: 90) }
                        Task { await loadStats() }
                        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            pruned = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                pruned = false
                            }
                        }
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
                .disabled(state == nil)

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
                        guard let data else { return }
                        saveDataWithPanel(
                            suggestedFilename: "hisingen_backup_\(Int(Date().timeIntervalSince1970)).json",
                            contentType: .json,
                            data: data
                        )
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "archivebox")
                        Text(L10n.text("Export Full Backup (JSON)"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state == nil)

                Button {
                    Task { @MainActor in
                        guard let data = try? await APIDiagnosticLogStore.shared.exportData() else { return }
                        saveDataWithPanel(
                            suggestedFilename: "hisingen_api_diagnostics.json",
                            contentType: .json,
                            data: data
                        )
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stethoscope")
                        Text(L10n.text("Export Redacted API Data"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L10n.text("Exports only sanitized JSON response bodies. Paths, metadata, vehicle identifiers, credentials, locations, and image URLs are removed."))
            }
        }
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
                try? csvContent.write(to: url, atomically: true, encoding: .utf8)
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
        }
    }

    private func saveDataWithPanel(suggestedFilename: String, contentType: UTType, data: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = suggestedFilename
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? data.write(to: url, options: .atomic)
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
        }
    }
}
