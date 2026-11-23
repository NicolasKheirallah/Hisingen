import Foundation
import Testing
@testable import Hisingen

@MainActor
struct GarageScannerTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "HisingenGarageScannerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    /// Regression: a mid-scan interruption – a remote command grabs the provider, or the user
    /// switches vehicles – must abort the WHOLE pass, not fall through to the next brand or the
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
        let diagnostics = GarageScanDiagnosticsStore()

        let scanner = GarageScanner(
            context: context,
            preferences: preferences,
            provider: { $0 == .volvo ? volvo : polestar },
            hasResumableSession: { _ in true },
            restoreDormantSession: { brand in if brand == .volvo { await volvoRestores.increment() } },
            diagnosticsStore: diagnostics
        )

        await scanner.scanNow()

        #expect(context.capturedStates.count == 1, "only the car scanned before the interruption should be captured")
        #expect(context.completePassCount == 0, "an aborted pass must not fire the closing re-render")
        let restores = await volvoRestores.count
        #expect(restores == 0, "the pass must not advance to the dormant brand after aborting")
        let scanStats = await diagnostics.current()
        #expect(scanStats.passesStarted == 1)
        #expect(scanStats.passesCompleted == 0)
        #expect(scanStats.lastPassWasPartial, "an interrupted pass must be explicit in exported diagnostics")
        #expect(scanStats.vehiclesScannedTotal == 1)
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
        #expect(context.capturedStates.count == 3)
        #expect(context.completePassCount == 1)
        let polestarSelections = await polestar.fetchSelections
        let volvoSelections = await volvo.fetchSelections
        #expect(polestarSelections == [.garageScan])
        #expect(volvoSelections == [.garageScan, .garageScan])
    }

    @Test
    func aSignedOutVehicleIsNotScanned() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.activeBrand = .polestar
        preferences.setVin("P1", for: .polestar)

        let context = RecordingScanContext()
        let polestar = StubProvider(brand: .polestar, vins: ["P1", "P2"])

        let scanner = GarageScanner(
            context: context,
            preferences: preferences,
            provider: { _ in polestar },
            hasResumableSession: { $0 == .polestar },
            restoreDormantSession: { _ in },
            isVehicleDetached: { $0 == "P2" }
        )

        await scanner.scanNow()

        #expect(context.capturedStates.isEmpty, "P1 is selected and P2 is signed out")
        #expect(context.completePassCount == 1)
    }

    /// A dormant brand whose provider is still warm is scanned without a restore round trip.
    @Test
    func warmDormantBrandIsScannedWithoutRestoring() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.activeBrand = .polestar
        preferences.setVin("P1", for: .polestar)
        preferences.setVin("VSELECTED", for: .volvo)

        let context = RecordingScanContext()
        let polestar = StubProvider(brand: .polestar, vins: ["P1", "P2"])
        let volvo = StubProvider(brand: .volvo, vins: ["V1"], warm: true)
        let volvoRestores = CallCounter()

        let scanner = GarageScanner(
            context: context,
            preferences: preferences,
            provider: { $0 == .volvo ? volvo : polestar },
            hasResumableSession: { _ in true },
            restoreDormantSession: { brand in if brand == .volvo { await volvoRestores.increment() } }
        )

        await scanner.scanNow()

        let restores = await volvoRestores.count
        #expect(restores == 0, "a warm dormant provider must not be re-restored")
        #expect(context.capturedStates.count == 2, "P2 + V1 still scanned")
        #expect(context.completePassCount == 1)
    }

    /// A cold dormant brand is still restored before its vehicles are scanned.
    @Test
    func coldDormantBrandIsRestoredBeforeScanning() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.activeBrand = .polestar
        preferences.setVin("P1", for: .polestar)
        preferences.setVin("VSELECTED", for: .volvo)

        let context = RecordingScanContext()
        let polestar = StubProvider(brand: .polestar, vins: ["P1", "P2"])
        let volvo = StubProvider(brand: .volvo, vins: ["V1"], warm: false)
        let volvoRestores = CallCounter()

        let scanner = GarageScanner(
            context: context,
            preferences: preferences,
            provider: { $0 == .volvo ? volvo : polestar },
            hasResumableSession: { _ in true },
            restoreDormantSession: { brand in if brand == .volvo { await volvoRestores.increment() } }
        )

        await scanner.scanNow()

        let restores = await volvoRestores.count
        #expect(restores == 1, "a cold dormant provider is restored once")
        #expect(context.capturedStates.count == 2)
    }

    /// A command that starts while a sibling's request is already on the wire cancels that request
    /// and ends the pass, instead of letting it run alongside the command.
    @Test
    func aCommandStartingMidRequestCancelsTheRequestAndEndsThePass() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.activeBrand = .polestar
        preferences.setVin("PSELECTED", for: .polestar)

        let context = RecordingScanContext()
        let provider = HangingProvider(brand: .polestar, vins: ["P1", "P2"])
        let scanner = GarageScanner(
            context: context, preferences: preferences,
            provider: { _ in provider },
            hasResumableSession: { $0 == .polestar },
            restoreDormantSession: { _ in },
            interruptionCheckInterval: 0.02)

        let pass = Task { await scanner.scanNow() }
        for _ in 0..<500 where await provider.startedFetches == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await provider.startedFetches == 1)
        context.commandPipelineIsBusy = true

        let started = Date()
        await pass.value
        #expect(Date().timeIntervalSince(started) < 5, "The request in flight must yield to the command")
        #expect(await provider.cancelledFetches == 1)
        #expect(await provider.startedFetches == 1, "The pass must not go on to the next car")
        #expect(context.capturedStates.isEmpty)
        #expect(context.completePassCount == 0)
    }

    /// A request that fails on its own is the provider's failure, reported as before. The pass
    /// must come back rather than wait on the interruption watcher.
    @Test
    func aRequestThatFailsOnItsOwnEndsThePassWithoutHanging() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.activeBrand = .polestar
        preferences.setVin("PSELECTED", for: .polestar)
        let context = RecordingScanContext()
        let diagnostics = GarageScanDiagnosticsStore()
        let provider = HangingProvider(brand: .polestar, vins: ["P1"], failsImmediately: true)
        let scanner = GarageScanner(
            context: context, preferences: preferences,
            provider: { _ in provider },
            hasResumableSession: { $0 == .polestar },
            restoreDormantSession: { _ in },
            diagnosticsStore: diagnostics,
            interruptionCheckInterval: 0.02)

        let pass = Task { await scanner.scanNow() }
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await pass.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(finished, "A failing request must not leave the pass waiting")
        #expect(context.capturedStates.isEmpty)
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

        #expect(context.capturedStates.count == 0)
        #expect(context.completePassCount == 0)
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
    /// Defaults to cold so the dormant-brand restore path stays exercised; a test can pass
    /// `warm: true` to check the skip.
    let warm: Bool
    private(set) var fetchSelections: [FeatureSelection] = []

    init(brand: VehicleBrand, vins: [String], warm: Bool = false) {
        self.brand = brand
        self.vins = vins
        self.warm = warm
    }

    var cars: [CarSummary] { vins.map { CarSummary(vin: $0, title: $0) } }
    var hasWarmSession: Bool { warm }
    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func restoreSession(preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) -> String? { vins.first }
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {}
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        fetchSelections.append(features)
        return vehicle(vin: vin, brand: brand)
    }
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        RemoteCommandResult(outcome: .completed, message: nil)
    }
}

/// A provider whose request never answers on its own: it waits until it is cancelled.
private actor HangingProvider: VehicleProviding {
    let brand: VehicleBrand
    private let vins: [String]
    private(set) var startedFetches = 0
    private(set) var cancelledFetches = 0
    private let failsImmediately: Bool

    struct Failure: Error {}

    init(brand: VehicleBrand, vins: [String], failsImmediately: Bool = false) {
        self.brand = brand
        self.vins = vins
        self.failsImmediately = failsImmediately
    }

    var cars: [CarSummary] { vins.map { CarSummary(vin: $0, title: $0) } }
    var hasWarmSession: Bool { true }
    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func restoreSession(preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) -> String? { vins.first }
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {}
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        startedFetches += 1
        if failsImmediately { throw Failure() }
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            cancelledFetches += 1
            throw error
        }
        return vehicle(vin: vin, brand: brand)
    }
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        RemoteCommandResult(outcome: .completed, message: nil)
    }
}
