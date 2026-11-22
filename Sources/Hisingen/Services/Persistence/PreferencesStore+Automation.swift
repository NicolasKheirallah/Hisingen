import Foundation

extension PreferencesStore {
    /// The reader's scheduled actions, in the order they were created. A value that fails to
    /// decode reads as none, so a damaged entry cannot take the settings card or the scheduler
    /// down with it.
    static let scheduledCommandsKey = "scheduled_commands_v1"
    /// Which occurrence of each schedule already fired: schedule id → occurrence key. Persisted
    /// because a relaunch a minute after a send must not send it again.
    static let scheduledCommandFiredKey = "scheduled_command_fired_v1"
    /// The reader's arrival and departure triggers.
    static let locationTriggersKey = "location_triggers_v1"

    var scheduledCommands: [ScheduledCommand] {
        get {
            guard let data = d.data(forKey: Self.scheduledCommandsKey),
                  let decoded = try? JSONDecoder().decode([ScheduledCommand].self, from: data) else {
                return []
            }
            return decoded.map(\.sanitized)
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            d.set(data, forKey: Self.scheduledCommandsKey)
        }
    }

    var locationTriggers: [LocationTrigger] {
        get {
            guard let data = d.data(forKey: Self.locationTriggersKey),
                  let decoded = try? JSONDecoder().decode([LocationTrigger].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            d.set(data, forKey: Self.locationTriggersKey)
        }
    }

    func scheduledCommandFiredOccurrence(for id: UUID) -> String? {
        let all = d.dictionary(forKey: Self.scheduledCommandFiredKey) as? [String: String]
        return all?[id.uuidString]
    }

    func setScheduledCommandFiredOccurrence(_ key: String?, for id: UUID) {
        var all = d.dictionary(forKey: Self.scheduledCommandFiredKey) as? [String: String] ?? [:]
        if let key { all[id.uuidString] = key } else { all.removeValue(forKey: id.uuidString) }
        d.set(all, forKey: Self.scheduledCommandFiredKey)
    }

    /// Drops ledger rows whose schedule no longer exists, so deleting a schedule does not leave
    /// its last occurrence on disk forever.
    func pruneScheduledCommandFiredOccurrences(keeping ids: Set<UUID>) {
        let all = d.dictionary(forKey: Self.scheduledCommandFiredKey) as? [String: String] ?? [:]
        let known = Set(ids.map(\.uuidString))
        let remaining = all.filter { known.contains($0.key) }
        guard remaining.count != all.count else { return }
        if remaining.isEmpty {
            d.removeObject(forKey: Self.scheduledCommandFiredKey)
        } else {
            d.set(remaining, forKey: Self.scheduledCommandFiredKey)
        }
    }
}
