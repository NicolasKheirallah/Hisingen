import Foundation

struct CommandPresentationState: Codable, Equatable, Sendable {
    /// The overlay with nothing to show.
    static let empty = CommandPresentationState()

    var optimisticLockUntil: Date?
    var receipts: [CommandReceipt]

    var hasAwaitingTelemetryConfirmation: Bool {
        receipts.contains { $0.status.isAwaiting && $0.supportsTelemetryConfirmation }
    }

    /// Compatibility view for call sites that only need the newest status.
    var receipt: CommandReceipt? {
        get { receipts.last }
        set {
            if let newValue {
                receipts = [newValue]
            } else {
                receipts = []
            }
        }
    }

    init(optimisticLockUntil: Date? = nil, receipts: [CommandReceipt] = []) {
        self.optimisticLockUntil = optimisticLockUntil
        self.receipts = receipts
    }

    private enum CodingKeys: String, CodingKey {
        case optimisticLockUntil, receipts
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        optimisticLockUntil = try values.decodeIfPresent(Date.self, forKey: .optimisticLockUntil)
        receipts = try values.decodeIfPresent([CommandReceipt].self, forKey: .receipts) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(optimisticLockUntil, forKey: .optimisticLockUntil)
        if !receipts.isEmpty {
            try values.encode(receipts, forKey: .receipts)
        }
    }
}
