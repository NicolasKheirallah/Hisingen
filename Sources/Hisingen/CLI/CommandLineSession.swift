import AppKit
import Foundation

/// The command-line surface's live wiring: the app's own stores, providers, session and command
/// coordinator, reached from a process that has no shell.
///
/// Nothing here decides anything about a command. It resolves which vehicle was meant, obtains a
/// reading the capability gate can be asked about, and then hands the command to
/// `CommandCoordinator` — the same gate, confirmation, provider call, audit row and receipt the
/// Controls tab, the deep links and the Shortcuts intents cross.
@MainActor
final class CommandLineSession: CommandLineVehicleDirectory, CommandLineCommandSending {
    private let preferences: PreferencesStore
    private let database: VehicleDatabase
    private let stateStore: VehicleStateStore
    private let providers: ProviderRegistry
    private let sessionManager: SessionManager

    init(preferences: PreferencesStore = .shared, database: VehicleDatabase = .shared) {
        self.preferences = preferences
        self.database = database
        self.stateStore = VehicleStateStore(database: database, preferences: preferences)
        let imageCache = CarImageCache.shared
        self.providers = ProviderRegistry(
            polestar: PolestarAPI(imageCache: imageCache, preferences: preferences),
            polestarDataPortal: PolestarDataPortalAPI(keychain: .app, imageCache: imageCache,
                                                     preferences: preferences),
            volvo: VolvoAPI(keychain: .app, imageCache: imageCache, preferences: preferences),
            preferences: preferences)
        self.sessionManager = SessionManager()
    }

    // MARK: - Listing

    func vehicles(refresh: Bool) async -> CommandLineVehicleListReport {
        var reports: [CommandLineVehicleReport] = []
        for vin in configuredVehicles() {
            let reading = await reading(for: vin, refresh: refresh)
            reports.append(report(for: vin, reading: reading))
        }
        return CommandLineVehicleListReport(vehicles: reports)
    }

    /// Every vehicle this Mac knows about, in the order the app shows them: the selected one
    /// first, then whatever each account has discovered. A signed-out vehicle is not listed:
    /// `knownVINs(for:)` already drops it, because Bring Back in Settings is the way back.
    private func configuredVehicles() -> [String] {
        if preferences.isDemoMode { return [DemoMode.vin] }
        var seen = Set<String>()
        var vins: [String] = []
        let candidates = [preferences.vin] + VehicleBrand.allCases.flatMap { preferences.knownVINs(for: $0) }
        for candidate in candidates {
            let normalized = candidate.normalizedVIN
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            vins.append(normalized)
        }
        return vins
    }

    private struct Reading {
        /// What the gate should be asked about.
        var state: VehicleState?
        /// `live`, `cached` or `uncached`.
        var source: String
        /// Why a live reading did not arrive.
        var note: String?
    }

    private func reading(for vin: String, refresh: Bool) async -> Reading {
        if preferences.isDemoMode, vin == DemoMode.vin {
            return Reading(state: DemoMode.state(), source: "live", note: nil)
        }
        let cached = stateStore.snapshot(for: vin)
        let stored = Reading(state: cached, source: cached == nil ? "uncached" : "cached", note: nil)
        guard refresh else { return stored }
        do {
            let session = try await liveVehicle(vin: vin)
            return Reading(state: session.state, source: "live", note: nil)
        } catch {
            var failed = stored
            failed.note = message(for: error)
            return failed
        }
    }

    private func report(for vin: String, reading: Reading) -> CommandLineVehicleReport {
        let brand = VehicleBrandResolver.brand(
            for: vin, snapshotBrand: reading.state?.model.brand, preferences: preferences)
        var commands: [String: String]?
        var reasons: [String: String]?
        if let state = reading.state {
            var answers: [String: String] = [:]
            var why: [String: String] = [:]
            for spec in CommandLineCommandTable.specs {
                // The listing asks the same question a dispatch asks, with the same gate and the
                // same brand authority. A representative argument stands in for the value a
                // `send` would carry; the gate's answer for the command's capability and settings
                // does not depend on it, but a value the vehicle's own limits reject is only
                // reported by the `send` that carries it.
                let availability = CapabilityGate.availability(
                    for: spec.probe,
                    state: state,
                    brand: brand,
                    polestarConnectionMode: preferences.polestarConnectionMode,
                    enabledFeatures: preferences.features.enabled,
                    commandInProgress: false,
                    volvoRestrictedScopesEnabled: preferences.volvoRestrictedScopesEnabled,
                    volvoGrantedScopes: Set(preferences.volvoGrantedScopes))
                answers[spec.identifier] = Self.key(for: availability)
                if let reason = availability.shortReason {
                    why[spec.identifier] = reason
                }
            }
            commands = answers
            reasons = why.isEmpty ? nil : why
        }
        return CommandLineVehicleReport(
            vin: vin,
            name: name(for: vin, state: reading.state, brand: brand),
            brand: brand.rawValue,
            selected: vin.caseInsensitiveCompare(preferences.vin) == .orderedSame,
            state: reading.source,
            fetchedAt: reading.state?.freshness.fetchedAt,
            commands: commands,
            reasons: reasons,
            note: reading.note)
    }

    private static func key(for availability: CommandAvailability) -> String {
        switch availability {
        case .available: return "available"
        case .disabledBySettings: return "disabled-by-settings"
        case .unsupportedByVehicle: return "unsupported-by-vehicle"
        case .unimplementedByProvider: return "unimplemented-by-provider"
        case .unavailableWhileBusy: return "busy"
        case .unavailableUntilRefresh: return "needs-refresh"
        case .notVehicleOwner: return "not-vehicle-owner"
        case .requiresAccountApproval: return "requires-account-approval"
        case .invalidSettings: return "invalid-settings"
        }
    }

    // MARK: - Sending

    func send(_ request: CommandLineSendRequest) async throws -> CommandLineSendReport {
        guard let vin = resolvedVIN(request.vehicle) else {
            if request.vehicle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                // A name or VIN that matches nothing is an argument the surface cannot use, not a
                // refusal by the car.
                throw CommandLineUsageError(
                    message: L10n.text("No vehicle in Hisingen matches that name or VIN."))
            }
            return CommandLineSendReport(
                status: .refused, command: request.command.identifier, vin: nil, vehicle: nil,
                outcome: nil,
                message: L10n.text("No vehicle is set up in Hisingen. Sign in on this Mac first."))
        }
        let brand = VehicleBrandResolver.brand(
            for: vin, snapshotBrand: stateStore.snapshot(for: vin)?.model.brand, preferences: preferences)

        if preferences.isDemoMode {
            // There is no provider to execute against in demo mode, and the coordinator's own
            // first check refuses a demo command in the same words. Answering here keeps the
            // surface from fabricating an executor that would "succeed" and write an audit row
            // for a vehicle that does not exist.
            return CommandLineSendReport(
                status: .notSent, command: request.command.identifier, vin: vin,
                vehicle: name(for: vin, state: nil, brand: brand), outcome: nil,
                message: L10n.text("Demo mode: commands are not sent to a vehicle."))
        }

        let live: (provider: any VehicleProviding, state: VehicleState)
        do {
            live = try await liveVehicle(vin: vin, brand: brand)
        } catch {
            return CommandLineSendReport(
                status: .notSent, command: request.command.identifier, vin: vin,
                vehicle: name(for: vin, state: nil, brand: brand), outcome: nil,
                message: message(for: error))
        }

        let confirmation = CommandLineConfirmation(confirmed: request.confirmed)
        let authorizer = CommandLineAuthorizer(confirmation: confirmation)
        authorizer.install(RemoteActionAuthorizer(
            preferences: preferences,
            confirm: { command, vehicle in confirmation.confirm(command, vehicle: vehicle) },
            reportAuthenticationFailure: { error in authorizer.authenticationDidFail(error) }))

        let context = CommandLineExecutionContext(
            executor: live.provider, state: live.state, store: stateStore)
        let coordinator = CommandCoordinator(
            context: context, preferences: preferences, database: database, authorizer: authorizer)
        let outcome = await CommandLineDispatcher(coordinator: coordinator)
            .perform(request.command, targetVIN: vin, origin: .commandLine)

        return CommandLineDispatchMapper(authorizer: authorizer)
            .report(
                for: outcome,
                presentation: context.presentation,
                command: request.command,
                vehicle: .init(vin: live.state.identity.vin,
                               name: name(for: live.state.identity.vin, state: live.state, brand: brand)))
    }

    /// Resolves a `--vin` value the same way Shortcuts resolves its vehicle argument: a VIN that
    /// belongs to this Mac, a nickname, or a model name. Nil means the selected vehicle.
    private func resolvedVIN(_ requested: String?) -> String? {
        AutomationHandoff.resolveVIN(from: requested, preferences: preferences, stateStore: stateStore)
    }

    /// Restores the account's session and asks the provider for a reading of this vehicle. The
    /// gate refuses a command without a reading younger than ten minutes, so a terminal send has
    /// to fetch one: the app would be showing the same refusal on a car it had not refreshed.
    private func liveVehicle(
        vin: String,
        brand: VehicleBrand? = nil
    ) async throws -> (provider: any VehicleProviding, state: VehicleState) {
        let resolvedBrand = brand ?? VehicleBrandResolver.brand(
            for: vin, snapshotBrand: stateStore.snapshot(for: vin)?.model.brand, preferences: preferences)
        let provider = providers.provider(for: resolvedBrand)
        try await sessionManager.restore(api: provider, preferences: preferences, preferredVIN: vin)
        let state = try await provider.fetchVehicleState(vin: vin, features: preferences.features)
        return (provider, state)
    }

    private func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func name(for vin: String, state: VehicleState?, brand: VehicleBrand) -> String {
        preferences.formattedVehicleTitle(
            vin: vin,
            modelName: state?.identity.modelName,
            modelYear: state?.identity.modelYear,
            registrationNo: state?.identity.registrationNo,
            fallbackBrand: brand)
    }
}
