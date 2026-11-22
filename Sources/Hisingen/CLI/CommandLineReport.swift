import Foundation

/// What the command-line surface prints, and what `--json` encodes. One model serves both modes:
/// the text form is a rendering of the same fields, so a person and a script never read two
/// different answers.
struct CommandLineVehicleReport: Codable, Equatable, Sendable {
    let vin: String
    let name: String
    let brand: String
    let selected: Bool
    /// `live` when the vehicle service answered for this run, `cached` when the answer came from
    /// this Mac's last stored reading, `uncached` when there is no reading at all.
    let state: String
    let fetchedAt: Date?
    /// The capability gate's answer per command identifier: `available`, `disabled-by-settings`,
    /// `unsupported-by-vehicle`, `unimplemented-by-provider`, `busy`, `needs-refresh`,
    /// `not-vehicle-owner`, `requires-account-approval` or `invalid-settings`. Absent when there
    /// is no reading to ask the gate about.
    let commands: [String: String]?
    /// The gate's own sentence for every command that is not available, so a refusal read here is
    /// the same sentence a `send` would print.
    let reasons: [String: String]?
    /// Why a `--refresh` could not produce a live reading. Nil when nothing was asked or the
    /// reading arrived.
    let note: String?
}

struct CommandLineVehicleListReport: Codable, Equatable, Sendable {
    let vehicles: [CommandLineVehicleReport]
}

struct CommandLineSendReport: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        /// The provider accepted the command. The audit row and the receipt are the app's own.
        case sent
        /// Refused before anything reached the provider: the same answer the app gives.
        case refused
        /// The command needs a confirmation the invocation did not carry, or device-owner
        /// authentication did not succeed.
        case confirmationRequired = "confirmation-required"
        /// Not sent, and safe to retry: busy, telemetry still loading, or the selection moved.
        case notSent = "not-sent"
    }

    let status: Status
    let command: String
    let vin: String?
    let vehicle: String?
    /// The provider outcome when one arrived: `accepted`, `delivered` or `completed`.
    let outcome: String?
    /// The sentence the app's own banner would show for this dispatch.
    let message: String
}

/// The process exit code, which is what a script branches on. Kept apart from the report so the
/// mapping is one table a test can pin.
enum CommandLineExit: Int32 {
    case success = 0
    /// The surface itself failed (the database, an unexpected error).
    case failure = 1
    /// Arguments the surface could not read, or a value it will not ask a car for.
    case usage = 2
    /// The app would refuse this command: the capability gate's answer, or the provider's.
    case refused = 3
    /// Not sent because nobody confirmed it: `--confirm` was absent, or device-owner
    /// authentication did not succeed.
    case confirmationRequired = 4
    /// Not sent, and safe to retry: busy, telemetry still loading, or the selection moved.
    case notSent = 5

    static func exitCode(for status: CommandLineSendReport.Status) -> Int32 {
        switch status {
        case .sent: return CommandLineExit.success.rawValue
        case .refused: return CommandLineExit.refused.rawValue
        case .confirmationRequired: return CommandLineExit.confirmationRequired.rawValue
        case .notSent: return CommandLineExit.notSent.rawValue
        }
    }
}

/// Where the surface's output goes. Tests capture it; the live path writes to the process's
/// standard handles without the line buffering `print` can leave behind when a script reads a
/// pipe.
struct CommandLineOutput {
    var standardOutput: @Sendable (String) -> Void
    var standardError: @Sendable (String) -> Void

    static let live = CommandLineOutput(
        standardOutput: { text in
            FileHandle.standardOutput.write(Data(text.utf8))
        },
        standardError: { text in
            FileHandle.standardError.write(Data(text.utf8))
        }
    )

    func write(_ text: String) { standardOutput(text + "\n") }
    func writeError(_ text: String) { standardError(text + "\n") }

    /// JSON on the standard output even for a refusal: a script reads one stream and gets the
    /// same fields whatever happened. Human text puts a refusal on the error stream instead, so
    /// `hisingen cli send lock >> log` does not log a failure as if it succeeded.
    func write(_ report: CommandLineSendReport, json: Bool) {
        if json {
            write(encode(report))
        } else if report.status == .sent {
            write(report.message)
        } else {
            writeError(report.message)
        }
    }

    func write(_ report: CommandLineVehicleListReport, json: Bool) {
        if json {
            write(encode(report))
            return
        }
        guard !report.vehicles.isEmpty else {
            write(L10n.text("No vehicle is set up in Hisingen. Sign in on this Mac first."))
            return
        }
        for vehicle in report.vehicles {
            write(text(for: vehicle))
        }
    }

    /// The human rendering of one vehicle: who it is, how old the answer is, what can be sent
    /// now, and the gate's sentence for everything that cannot.
    func text(for vehicle: CommandLineVehicleReport) -> String {
        var lines: [String] = []
        var heading = "\(vehicle.brand.capitalized) — \(vehicle.name) (\(vehicle.vin))"
        // The app's own phrasing for the vehicle the panel is showing.
        if vehicle.selected { heading = L10n.format("%@, selected", heading) }
        lines.append(heading)
        if let fetchedAt = vehicle.fetchedAt {
            lines.append("  " + L10n.format("%@ (%@)", vehicle.state,
                                            fetchedAt.formatted(date: .abbreviated, time: .standard)))
        } else {
            lines.append("  " + vehicle.state)
        }
        if let note = vehicle.note {
            lines.append("  " + note)
        }
        if let commands = vehicle.commands {
            let ready = commands.filter { $0.value == "available" }.keys.sorted()
            if !ready.isEmpty {
                lines.append("  " + L10n.format("Ready: %@", ready.joined(separator: ", ")))
            }
            // Grouped by the gate's sentence: a dozen commands refused for the same reason read as
            // one line each in the JSON, and as one paragraph here.
            var byReason: [String: [String]] = [:]
            for (identifier, status) in commands where status != "available" {
                let reason = vehicle.reasons?[identifier] ?? status
                byReason[reason, default: []].append(identifier)
            }
            if !byReason.isEmpty {
                lines.append("  " + L10n.text("Blocked:"))
                for reason in byReason.keys.sorted() {
                    lines.append("    " + reason)
                    lines.append("      " + (byReason[reason] ?? []).sorted().joined(separator: ", "))
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
