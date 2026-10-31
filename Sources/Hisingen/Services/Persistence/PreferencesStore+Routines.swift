import Foundation

extension PreferencesStore {
    static let commandRoutinesKey = "command_routines_v1"

    /// The routines the reader saved, in the order they were created. A value that fails to
    /// decode reads as no routines, so a damaged entry cannot take the Controls tab down with it.
    var commandRoutines: [CommandRoutine] {
        get {
            guard let data = d.data(forKey: Self.commandRoutinesKey),
                  let decoded = try? JSONDecoder().decode([CommandRoutine].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            d.set(data, forKey: Self.commandRoutinesKey)
        }
    }
}
