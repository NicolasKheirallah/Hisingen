import SwiftUI

enum SettingsChange {
    case credentials
    case features
    case notifications
    case presentation
    case launchAtLogin
    case updater
    case checkForUpdates
    case automation
    case volvoSignIn(clientID: String, clientSecret: String, vccApiKey: String, nickname: String)
    case polestarCommandAuthorization
    case polestarWebSignIn
    /// Renew an existing brand's session without re-entering credentials: Polestar through
    /// its interactive browser window, Volvo by re-running its browser OAuth with the
    /// developer keys already on file.
    case reauthenticate(VehicleBrand)
    case switchToBrand(VehicleBrand)
    case selectVehicle(String)
    case closeSettings
}

/// Shared plumbing so a card extracted into its own `View` keeps the `binder(\.key, .change)`
/// ergonomics without carrying a local `@State` mirror. Writes go straight through
/// `PreferencesStore`'s own setter (where side effects like `applyAppearance()` live), then
/// `bump()` re-renders the settings composition (covering same-screen mirrored readouts) and
/// `change`, when given, is forwarded to `onSettingsChanged`.
@MainActor
struct PreferenceBinder {
    let preferences: PreferencesStore
    let notify: (SettingsChange) -> Void
    let bump: () -> Void

    func callAsFunction<Value>(
        _ keyPath: ReferenceWritableKeyPath<PreferencesStore, Value>,
        _ change: SettingsChange? = nil
    ) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { newValue in
                preferences[keyPath: keyPath] = newValue
                bump()
                if let change { notify(change) }
            }
        )
    }
}

