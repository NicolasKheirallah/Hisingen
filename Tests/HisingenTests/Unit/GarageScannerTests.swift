import Foundation
import Testing
@testable import Hisingen

@MainActor
struct GarageScannerTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "HisingenGarageScannerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    /// Regression: a mid-scan interruption — a remote command grabs the provider, or the user
    /// switches vehicles — must abort the WHOLE pass, not fall through to the next brand or the
    /// closing re-render. The pre-extraction `refreshGarageVehicles` bailed the entire function
    /// from its inner guards; turning them into `return`s from a per-brand helper silently lost
    /// that, letting a scan keep hitting the network while an interactive operation was live.
    @Test
    func midScanInterruptionAbortsEntirePass() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.activeBrand = .polestar
        preferences.setVin("PSELECTED", for: .polestar)   // deliberately not among the scanned cars
        preferences.setVin("VSELECTED", for: .volvo)

        let context = RecordingScanContext()
        // The first captured snapshot simulates a remote command starting mid-pass.
        context.onCapture = { context.commandPipelineIsBusy = true }

        let polestar = StubProvider(brand: .polestar, vins: ["P1", "P2"])
        let volvo = StubProvider(brand: .volvo, vins: ["V1", "V2"])
        let volvoRestores = CallCounter()

        let scanner = GarageScanner(
            context: context,
            preferences: preferences,
            provider: { $0 == .volvo ? volvo : polestar },
            hasResumableSession: { _ in true },
            restoreDormantSession: { brand in if brand == .volvo { await volvoRestores.increment() } }
        )

        await scanner.scanNow()

        XCTAssertEqual(context.capturedStates.count, 1,
                       "only the car scanned before the interruption should be captured")
        XCTAssertEqual(context.completePassCount, 0,
                       "an aborted pass must not fire the closing re-render")
        let restores = await volvoRestores.count
        XCTAssertEqual(restores, 0,
                       "the pass must not advance to the dormant brand after aborting")
    }

    /// The clean path: with nothing interrupting, every non-selected car of every resumable
    /// brand is scanned and the pass closes with exactly one re-render.
    @Test
    func uninterruptedPassScansEveryBrandAndRendersOnce() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.activeBrand = .polestar
        preferences.setVin("P1", for: .polestar)   // P1 is the active selection -> skipped by the scan
        preferences.setVin("VSELECTED", for: .volvo)

        let context = RecordingScanContext()
        let polestar = StubProvider(brand: .polestar, vins: ["P1", "P2"])
        let volvo = StubProvider(brand: .volvo, vins: ["V1", "V2"])

        let scanner = GarageScanner(
            context: context,
            preferences: preferences,
            provider: { $0 == .volvo ? volvo : polestar },
            hasResumableSession: { _ in true },
            restoreDormantSession: { _ in }
        )

        await scanner.scanNow()

        // P1 skipped (active selection); P2 + V1 + V2 scanned.
        XCTAssertEqual(context.capturedStates.count, 3)
        XCTAssertEqual(context.completePassCount, 1)
    }

    /// A scan started while a command is already in progress never begins.
    @Test
    func scanIsSuppressedWhileACommandIsInProgress() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.activeBrand = .polestar
        preferences.setVin("PSELECTED", for: .polestar)

        let context = RecordingScanContext()
        context.commandPipelineIsBusy = true

        let scanner = GarageScanner(
            context: context,
            preferences: preferences,
            provider: { _ in StubProvider(brand: .polestar, vins: ["P1"]) },
            hasResumableSession: { _ in true },
            restoreDormantSession: { _ in }
        )

        await scanner.scanNow()

        XCTAssertEqual(context.capturedStates.count, 0)
        XCTAssertEqual(context.completePassCount, 0)
    }
}

@MainActor
private final class RecordingScanContext: GarageScanContext {
    var commandPipelineIsBusy = false
    var refreshPipelineIsBusy = false
    var refreshPipelineIsRateLimited = false
    private(set) var capturedStates: [VehicleState] = []
    private(set) var completePassCount = 0
    var onCapture: (() -> Void)?

    func garageScanDidCaptureState(_ state: VehicleState) {
        capturedStates.append(state)
        onCapture?()
    }

    func garageScanDidCompletePass() {
        completePassCount += 1
    }
}

private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor StubProvider: VehicleProviding {
    let brand: VehicleBrand
    private let vins: [String]

    init(brand: VehicleBrand, vins: [String]) {
        self.brand = brand
        self.vins = vins
    }

    var cars: [CarSummary] { vins.map { CarSummary(vin: $0, title: $0) } }
    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) -> String? { vins.first }
    func selectCar(vin: String, features: FeatureSelection) async throws {}
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        vehicle(vin: vin, brand: brand)
    }
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        RemoteCommandResult(outcome: .completed, message: nil)
    }
}
