import SwiftUI

/// What the panel displays, updated wholesale by the app layer. One struct replaces the
/// 14-field snapshot relay and the five separately-poked controller variables, so a new
/// piece of panel state is an edit here, not edits in every relay layer.
struct PanelDisplay {
    var state: VehicleState?
    var error: String?
    var authenticated: Bool
    var activeVin: String?
    var fleet: FleetSnapshot
    var remoteCommandInProgress: Bool
    var commandBrand: VehicleBrand
    var inFlightRemoteCommandID: String?
    var lastRemoteCommandFeedback: RemoteCommandFeedback?
    var updateVersion: String?
    var checkingForUpdates: Bool
    var notificationPermission: NotificationPermission
    var diagnostics: DiagnosticsSnapshot?
    var setupMode: Bool
}

/// The panel's command surface, fixed at construction. The closures are the deliberate
/// seam to the app shell; they are actions, not display state, so they live apart from
/// `PanelDisplay` and never ride an update.
struct PanelActions {
    let onRefresh: () -> Void
    let onSettings: () -> Void
    let onClose: () -> Void
    let onCheckForUpdates: () -> Void
    let onOpenUpdate: () -> Void
    let onRemoteCommand: (RemoteCommand) -> Void
    let onSelectCar: (String) -> Void
    let onDismissCommandReceipt: (UUID) -> Void
    let onSettingsChanged: (SettingsChange) -> Void
    let onSignOut: () -> Void
    let onTestConnection: (VehicleBrand) async -> ConnectionCheck
    let onCompleteSetup: () -> Void
}

/// The panel's single observed model. `StatusItemController` builds `display` in one place
/// and publishes it wholesale; the panel reads display state, actions, and services from
/// here instead of a 29-parameter view init.
@MainActor
final class PanelModel: ObservableObject {
    @Published private(set) var display: PanelDisplay
    let actions: PanelActions
    let history: HistoryWorkspace
    let accountConnection: AccountConnectionModel
    let reverseGeocoder: ReverseGeocoder
    let imageCache: CarImageCache

    init(display: PanelDisplay, actions: PanelActions,
         history: HistoryWorkspace, accountConnection: AccountConnectionModel,
         reverseGeocoder: ReverseGeocoder, imageCache: CarImageCache) {
        self.display = display
        self.actions = actions
        self.history = history
        self.accountConnection = accountConnection
        self.reverseGeocoder = reverseGeocoder
        self.imageCache = imageCache
    }

    func update(_ display: PanelDisplay) {
        self.display = display
    }
}
