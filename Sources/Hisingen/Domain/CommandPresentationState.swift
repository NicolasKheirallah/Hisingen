import Foundation

struct CommandPresentationState: Codable, Equatable, Sendable {
    var optimisticLockUntil: Date?
    var receipts: [CommandReceipt]

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

    init(
        optimisticLockUntil: Date? = nil,
        receipts: [CommandReceipt] = [],
        receipt: CommandReceipt? = nil
    ) {
        self.optimisticLockUntil = optimisticLockUntil
        self.receipts = receipts.isEmpty ? receipt.map { [$0] } ?? [] : receipts
    }

    private enum CodingKeys: String, CodingKey {
        case optimisticLockUntil, receipts, receipt, pending
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        optimisticLockUntil = try values.decodeIfPresent(Date.self, forKey: .optimisticLockUntil)
        if let decoded = try values.decodeIfPresent([CommandReceipt].self, forKey: .receipts) {
            receipts = decoded
        } else if let legacy = try values.decodeIfPresent(CommandReceipt.self, forKey: .receipt)
            ?? values.decodeIfPresent(CommandReceipt.self, forKey: .pending) {
            receipts = [legacy]
        } else {
            receipts = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(optimisticLockUntil, forKey: .optimisticLockUntil)
        if !receipts.isEmpty {
            try values.encode(receipts, forKey: .receipts)
        }
    }
}
