import SwiftUI

@MainActor
final class PopoverViewModel: ObservableObject {
    struct Snapshot {
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
        var settingsMode: Bool
        var setupMode: Bool
    }

    @Published private(set) var snapshot: Snapshot

    init(snapshot: Snapshot) { self.snapshot = snapshot }

    func update(_ snapshot: Snapshot) { self.snapshot = snapshot }
}

@MainActor
struct PopoverRootView: View {
    @ObservedObject var model: PopoverViewModel
    let content: @MainActor (PopoverViewModel.Snapshot) -> AnyView

    var body: some View { content(model.snapshot) }
}
