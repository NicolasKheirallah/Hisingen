import Foundation
import SwiftUI
import Testing
@testable import Hisingen

/// The panel's push path is one observed model: the app layer updates `display`
/// wholesale, the actions seam stays fixed, and the view reads everything from the model.
@MainActor
@Suite("PanelModel")
struct PanelModelTests {

    private func makeDisplay(authenticated: Bool = true) -> PanelDisplay {
        PanelDisplay(
            state: nil, error: nil, authenticated: authenticated, activeVin: nil,
            fleet: FleetSnapshot(),
            remoteCommandInProgress: false, commandBrand: .polestar,
            inFlightRemoteCommandID: nil, lastRemoteCommandFeedback: nil,
            updateVersion: nil, checkingForUpdates: false,
            notificationPermission: .notDetermined, diagnostics: nil, setupMode: false)
    }

    private func makeActions() -> PanelActions {
        PanelActions(
            onRefresh: {}, onSettings: {}, onClose: {}, onCheckForUpdates: {},
            onOpenUpdate: {}, onRemoteCommand: { _ in }, onSelectCar: { _ in },
            onDismissCommandReceipt: { _ in }, onSettingsChanged: { _ in },
            onSignOut: {}, onTestConnection: { _ in (false, "", nil) }, onCompleteSetup: {})
    }

    @Test func updatePublishesTheWholeDisplay() {
        let raw = try! SQLiteDatabase.inMemory()
        let model = PanelModel(display: makeDisplay(), actions: makeActions(),
                               database: VehicleDatabase(database: raw),
                               reverseGeocoder: ReverseGeocoder(), imageCache: CarImageCache())
        var published = 0
        let cancellable = model.objectWillChange.sink { published += 1 }

        var next = makeDisplay()
        next.authenticated = false
        next.activeVin = "YSMTEST"
        next.updateVersion = "2.1.0"
        model.update(next)

        #expect(published == 1)
        #expect(model.display.authenticated == false)
        #expect(model.display.activeVin == "YSMTEST")
        #expect(model.display.updateVersion == "2.1.0")
        _ = cancellable
    }

    @Test func theActionSeamSurvivesAWholesaleDisplayUpdate() {
        let raw = try! SQLiteDatabase.inMemory()
        var selectedVIN: String?
        let actions = PanelActions(
            onRefresh: {}, onSettings: {}, onClose: {}, onCheckForUpdates: {},
            onOpenUpdate: {}, onRemoteCommand: { _ in }, onSelectCar: { selectedVIN = $0 },
            onDismissCommandReceipt: { _ in }, onSettingsChanged: { _ in },
            onSignOut: {}, onTestConnection: { _ in (false, "", nil) }, onCompleteSetup: {})
        let model = PanelModel(display: makeDisplay(), actions: actions,
                               database: VehicleDatabase(database: raw),
                               reverseGeocoder: ReverseGeocoder(), imageCache: CarImageCache())

        model.update(makeDisplay())
        model.actions.onSelectCar("YSMTEST")

        #expect(selectedVIN == "YSMTEST")
    }
}
