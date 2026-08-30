import Foundation
import OSLog

/// What the garage scanner needs from the app shell. The scanner owns loop timing,
/// re-entrancy, and every "is it safe to run right now" interlock; the shell only reports
/// whether the interactive paths are busy and absorbs the snapshots a scan produces.
@MainActor
protocol GarageScanContext: AnyObject {
    /// True while the remote-command pipeline holds the active provider.
    var commandPipelineIsBusy: Bool { get }
    /// True while an interactive refresh or vehicle switch owns provider selection.
    var refreshPipelineIsBusy: Bool { get }
    /// True inside a provider rate-limit pause.
    var refreshPipelineIsRateLimited: Bool { get }
    /// A sibling- or dormant-account vehicle snapshot the scan just fetched: persist it,
    /// cache it, and run notification rules against it.
    func garageScanDidCaptureState(_ state: VehicleState)
    /// Fired once after a full scan pass, only while the active brand is unchanged.
    func garageScanDidCompletePass()
}

/// Keeps the *unselected* vehicles fresh. The foreground `RefreshCoordinator` only ever polls
/// the one selected car; this walks every brand with a resumable session — siblings on the
/// active account and every vehicle on the dormant account — so the fleet list and the
/// warning badge stay current without the user switching to each car.
///
/// Runs a first pass ~45 s after launch and every 5 min after that, plus a one-shot pass ~8 s
/// after each session is established. Extracted from `AppDelegate`; the interlocks that stop a
/// scan from doubling per-account request volume into a provider rate limit all live here now.
@MainActor
final class GarageScanner {
    private let logger = AppLog.logger("garage-scan")
    private let preferences: PreferencesStore
    private let provider: (VehicleBrand) -> any VehicleProviding
    /// Whether `brand` has credentials the scan can restore a session from. Injected (rather
    /// than read straight off `preferences`) so a test can drive the brand set without the
    /// system Keychain.
    private let hasResumableSession: (VehicleBrand) -> Bool
    /// Re-establishes a dormant brand's session before its vehicles are scanned (its provider
    /// is not kept warm). Only invoked for a brand other than the currently active one.
    private let restoreDormantSession: (VehicleBrand) async throws -> Void
    private weak var context: (any GarageScanContext)?

    /// Cadence knobs, injectable so tests do not wait real minutes.
    private let initialDelay: TimeInterval
    private let loopInterval: TimeInterval

    private var loopTask: Task<Void, Never>?
    /// Pending one-shot passes, keyed so each can drop its own handle on completion. Cancelled
    /// wholesale by `stop()`.
    private var scheduledPasses: [UUID: Task<Void, Never>] = [:]
    private var scanInProgress = false

    /// Whether a per-brand scan finished cleanly, or hit a condition that aborts the whole pass
    /// (cancelled, the user switched vehicles, or an interactive operation started). The latter
    /// must not fall through to the next brand or the closing re-render.
    private enum PassOutcome { case completed, abort }

    init(context: any GarageScanContext,
         preferences: PreferencesStore,
         provider: @escaping (VehicleBrand) -> any VehicleProviding,
         hasResumableSession: @escaping (VehicleBrand) -> Bool,
         restoreDormantSession: @escaping (VehicleBrand) async throws -> Void,
         initialDelay: TimeInterval = 45,
         loopInterval: TimeInterval = 5 * 60) {
        self.context = context
        self.preferences = preferences
        self.provider = provider
        self.hasResumableSession = hasResumableSession
        self.restoreDormantSession = restoreDormantSession
        self.initialDelay = initialDelay
        self.loopInterval = loopInterval
    }

    /// Starts the periodic loop, cancelling any previous one first.
    func startLoop() {
        loopTask?.cancel()
        let initialDelay = self.initialDelay
        let loopInterval = self.loopInterval
        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(initialDelay)) } catch { return }
                guard let self else { return }
                await self.scanNow()
                do { try await Task.sleep(for: .seconds(loopInterval)) } catch { return }
            }
        }
    }

    /// Schedules one extra pass `seconds` from now — used right after a session is established,
    /// since the foreground loop only ever refreshes the selected car.
    func schedulePass(after seconds: TimeInterval) {
        let id = UUID()
        scheduledPasses[id] = Task { @MainActor [weak self] in
            defer { self?.scheduledPasses[id] = nil }
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            await self?.scanNow()
        }
    }

    /// Cancels the loop and every pending one-shot pass (termination, sign-out, brand switch).
    func stop() {
        loopTask?.cancel()
        loopTask = nil
        for task in scheduledPasses.values { task.cancel() }
        scheduledPasses.removeAll()
    }

    /// Runs one scan pass immediately. Public so the one-shot scheduler and tests can force one.
    func scanNow() async {
        guard let context else { return }
        guard !scanInProgress, !context.commandPipelineIsBusy else { return }
        // Never run inside a coordinator operation or a provider rate-limit pause: a scan
        // roughly doubles per-account request volume, which both extends the 429 backoff
        // window and starves the interactive paths (refresh, vehicle switching).
        guard !context.refreshPipelineIsBusy, !context.refreshPipelineIsRateLimited else { return }
        scanInProgress = true
        defer { scanInProgress = false }

        let originalBrand = preferences.activeBrand
        for brand in VehicleBrand.allCases where hasResumableSession(brand) {
            guard !Task.isCancelled else { return }
            do {
                if try await scan(brand: brand, originalBrand: originalBrand, context: context) == .abort {
                    return
                }
            } catch {
                logger.debug("Background garage refresh for \(brand.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        guard preferences.activeBrand == originalBrand else { return }
        context.garageScanDidCompletePass()
    }

    private func scan(brand: VehicleBrand, originalBrand: VehicleBrand,
                      context: any GarageScanContext) async throws -> PassOutcome {
        // The dormant brand's provider is not kept warm, so re-establish its session before
        // scanning its vehicles.
        if brand != originalBrand {
            try await restoreDormantSession(brand)
        }

        let provider = self.provider(brand)
        let selectedVIN = preferences.vin(for: brand)
        let providerCars = await provider.cars
        for car in providerCars {
            guard !Task.isCancelled, preferences.activeBrand == originalBrand,
                  !context.commandPipelineIsBusy, !context.refreshPipelineIsBusy else { return .abort }
            // If the user switched vehicles mid-scan, stand down at once: the coordinator
            // owns provider selection from that moment.
            if preferences.vin(for: brand) != selectedVIN { return .abort }
            if brand == originalBrand && car.vin == selectedVIN { continue }
            try await provider.selectCar(vin: car.vin, features: preferences.features)
            let state = try await provider.fetchVehicleState(vin: car.vin, features: preferences.features)
            guard preferences.activeBrand == originalBrand,
                  preferences.vin(for: brand) == selectedVIN,
                  !context.commandPipelineIsBusy else { return .abort }
            context.garageScanDidCaptureState(state)
        }
        // No re-selection of the previously selected car at the end: telemetry and commands
        // address vehicles explicitly by VIN, so the shared selection pointer carries no
        // behavioural weight anymore — and re-selecting cost a full Polestar discovery round
        // trip on every single scan.
        return .completed
    }
}
