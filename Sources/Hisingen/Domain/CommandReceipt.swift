import Foundation

enum CommandConfirmationStatus: Codable, Equatable, Sendable {
    case awaiting
    /// The provider acknowledged the command, but this provider does not expose telemetry
    /// capable of proving the physical outcome.
    case acknowledged(at: Date)
    case confirmed(at: Date)
    case timedOut(at: Date)

    var isAwaiting: Bool {
        if case .awaiting = self { return true }
        return false
    }

    var isConfirmed: Bool {
        if case .confirmed = self { return true }
        return false
    }

    var isAcknowledged: Bool {
        if case .acknowledged = self { return true }
        return false
    }

    var isTerminal: Bool { !isAwaiting }
}

/// Display-only receipt for a remote command and its authoritative confirmation lifecycle.
/// Requested values remain optimistic until fresh vehicle telemetry moves `status` to
/// `confirmed`; the refresh coordinator owns the only timeout transition.
struct CommandReceipt: Codable, Equatable, Sendable {
    static let maximumConfirmationDuration: TimeInterval = 5 * 60
    static let confirmationTimestampTolerance: TimeInterval = 2
    static let maximumRetainedTerminalCount = 5

    var id: UUID
    /// Matches `RemoteCommand.identifier` and the command-audit trail.
    var commandIdentifier: String
    var issuedAt: Date
    var command: RemoteCommand? = nil
    /// Frozen dispatch target and provider. Optional for backward-compatible decoding of
    /// receipts written by earlier builds.
    var targetVIN: String? = nil
    var providerBrand: VehicleBrand? = nil
    /// Correlates provider acknowledgement with later confirmation/timeout in SQLite.
    var auditID: String? = nil
    var status: CommandConfirmationStatus = .awaiting

    init(
        id: UUID = UUID(),
        commandIdentifier: String,
        issuedAt: Date,
        command: RemoteCommand? = nil,
        targetVIN: String? = nil,
        providerBrand: VehicleBrand? = nil,
        auditID: String? = nil,
        status: CommandConfirmationStatus = .awaiting
    ) {
        self.id = id
        self.commandIdentifier = commandIdentifier
        self.issuedAt = issuedAt
        self.command = command
        self.targetVIN = targetVIN
        self.providerBrand = providerBrand
        self.auditID = auditID
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id, commandIdentifier, issuedAt, command, targetVIN, providerBrand, auditID,
             status, confirmedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        commandIdentifier = try values.decode(String.self, forKey: .commandIdentifier)
        issuedAt = try values.decode(Date.self, forKey: .issuedAt)
        command = try values.decodeIfPresent(RemoteCommand.self, forKey: .command)
        targetVIN = try values.decodeIfPresent(String.self, forKey: .targetVIN)
        providerBrand = try values.decodeIfPresent(VehicleBrand.self, forKey: .providerBrand)
        auditID = try values.decodeIfPresent(String.self, forKey: .auditID)
        if let decoded = try values.decodeIfPresent(CommandConfirmationStatus.self, forKey: .status) {
            status = decoded
        } else if let confirmedAt = try values.decodeIfPresent(Date.self, forKey: .confirmedAt) {
            status = .confirmed(at: confirmedAt)
        } else {
            status = .awaiting
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(commandIdentifier, forKey: .commandIdentifier)
        try values.encode(issuedAt, forKey: .issuedAt)
        try values.encodeIfPresent(command, forKey: .command)
        try values.encodeIfPresent(targetVIN, forKey: .targetVIN)
        try values.encodeIfPresent(providerBrand, forKey: .providerBrand)
        try values.encodeIfPresent(auditID, forKey: .auditID)
        try values.encode(status, forKey: .status)
    }
}
