import Foundation
import Testing
@testable import Hisingen

@MainActor
struct PolestarCapabilityTests {
    /// The three states `OptionalCapability` folded into `(value: nil, unavailable: false,
    /// unsupported: false)`. Its two booleans could not tell them apart; the enum must.
    @Test func neverAskedAndAskedButEmptyAreDifferentStates() async throws {
        let api = makeAPI()

        let disabled: CapabilityState<Int> = try await api.optionalCapability(
            .tripMeters, enabled: false, vin: "VIN-A"
        ) {
            Issue.record("A disabled reading was requested")
            return 42
        }
        #expect(disabled.summary == .unknown)

        // Requested, answered, and the provider simply had nothing for this reading. Not
        // `.unknown`: we did ask, and reporting it as unchecked would hide a provider gap.
        let empty: CapabilityState<Int> = try await api.optionalCapability(
            .tripMeters, enabled: true, vin: "VIN-B"
        ) { nil }
        #expect(empty.summary == .available)
        #expect(empty.value == nil)
        #expect(!empty.unavailable)
        #expect(!empty.unsupported)

        #expect(disabled != empty)
    }

    /// Exactly one state is ever true, and a payload only exists in the state that carries one.
    /// The old three-field struct could express `unavailable && unsupported` and a value that was
    /// simultaneously unavailable; the enum cannot.
    @Test func eachStateReportsExactlyOneCondition() async throws {
        let api = makeAPI()

        let states: [CapabilityState<Int>] = [
            try await api.optionalCapability(.tripMeters, enabled: true, vin: "VIN-VALUE") { 42 },
            try await api.optionalCapability(.exteriorStatus, enabled: true, vin: "VIN-EMPTY") { nil },
            try await api.optionalCapability(.remoteLocks, enabled: false, vin: "VIN-UNKNOWN") { 1 },
            try await api.optionalCapability(.tyreAndWarnings, enabled: true, vin: "VIN-FAIL") {
                throw PolestarError.grpcUnavailable(service: "test")
            },
            try await api.optionalCapability(.climateStatus, enabled: true, vin: "VIN-UNSUPPORTED") {
                throw PolestarError.grpcUnimplemented(service: "test")
            }
        ]

        for state in states {
            let conditions = [state.unavailable, state.unsupported]
            #expect(conditions.filter { $0 }.count <= 1)
            // A payload is only ever reachable through `.available`.
            if state.value != nil || state.summary == .available {
                if case .available = state {} else {
                    Issue.record("\(state.summary) carried a payload outside .available")
                }
            }
        }

        // The states collapse onto exactly the four summaries the badge can draw. `available(42)`
        // and `available(nil)` deliberately share `.available`: the badge names the state, and
        // whether the provider had a payload is not a state.
        let summaries = Set(states.map(\.summary))
        #expect(summaries == [.available, .unsupported, .unavailable, .unknown])
        #expect(states.filter { $0.summary == .available }.count == 2)
    }

    /// The summaries the badge draws, including the case the old UI enum could not name.
    @Test func summariesCoverEveryState() {
        #expect(CapabilityState<Int>.available(1).summary == .available)
        #expect(CapabilityState<Int>.available(nil).summary == .available)
        #expect(CapabilityState<Int>.unsupported.summary == .unsupported)
        #expect(CapabilityState<Int>.unavailable.summary == .unavailable)
        #expect(CapabilityState<Int>.unknown.summary == .unknown)

        for summary: CapabilitySummary in [.available, .unsupported, .unavailable, .unknown] {
            #expect(!summary.label.isEmpty)
            #expect(!summary.symbol.isEmpty)
        }
    }

    private func makeAPI() -> PolestarAPI {
        PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.capability.\(UUID())"))
    }

    @Test func lateSuccessCannotRepopulateClearedCaches() async throws {
        let api = makeAPI()
        let gate = CapabilityReadGate()
        let read = Task {
            try await api.optionalCapability(.tripMeters, enabled: true, vin: "VIN-A") {
                await gate.read()
            }
        }
        await gate.waitForArrival()
        await api.clearAccountState()
        await gate.release()
        do { _ = try await read.value; Issue.record("Stale read returned successfully") }
        catch { #expect(error is CancellationError) }
        #expect(await api.capabilityCache.isEmpty)
        #expect(await api.capabilityBackoff.isEmpty)
    }

    @Test func lateFailureCannotBackOffANewerSession() async throws {
        let api = makeAPI()
        let gate = CapabilityReadGate()
        let read = Task {
            try await api.optionalCapability(.tripMeters, enabled: true, vin: "VIN-A") { () async throws -> Int? in
                _ = await gate.read()
                throw PolestarError.grpcUnavailable(service: "test")
            }
        }
        await gate.waitForArrival()
        await api.clearAccountState()
        await gate.release()
        do { _ = try await read.value; Issue.record("Stale failure was swallowed") }
        catch { #expect(error is CancellationError) }
        #expect(await api.capabilityBackoff.isEmpty)
    }

    @Test func cancelledReadDoesNotMarkCapabilityUnavailable() async {
        let api = makeAPI()
        do {
            let _: CapabilityState<Int> = try await api.optionalCapability(.tripMeters, enabled: true, vin: "VIN-A") {
                throw CancellationError()
            }
            Issue.record("Cancellation was swallowed")
        } catch { #expect(error is CancellationError) }
        #expect(await api.capabilityBackoff.isEmpty)
    }

    @Test func backoffPreservesFailureUntilAReadSucceeds() async throws {
        let api = makeAPI()
        let first: CapabilityState<Int> = try await api.optionalCapability(.tripMeters, enabled: true, vin: "VIN-A") {
            throw PolestarError.grpcUnavailable(service: "test")
        }
        let retry: CapabilityState<Int> = try await api.optionalCapability(.tripMeters, enabled: true, vin: "VIN-A") {
            Issue.record("Backoff issued another request")
            return 42
        }
        #expect(first.unavailable)
        #expect(retry.unavailable)
        let other: CapabilityState<Int> = try await api.optionalCapability(.tripMeters, enabled: true, vin: "VIN-B") { 42 }
        #expect(other.value == 42)
        #expect(!other.unavailable)
    }

    @Test func unimplementedCapabilityRemainsUnsupportedDuringBackoff() async throws {
        let api = makeAPI()
        let first: CapabilityState<Int> = try await api.optionalCapability(
            .connectivityDiagnostics, enabled: true, vin: "VIN-A"
        ) {
            throw PolestarError.grpcUnimplemented(service: "dashboard")
        }
        let retry: CapabilityState<Int> = try await api.optionalCapability(
            .connectivityDiagnostics, enabled: true, vin: "VIN-A"
        ) {
            Issue.record("Unsupported capability issued another request during backoff")
            return 42
        }
        #expect(first.unsupported)
        #expect(retry.unsupported)
        #expect(!first.unavailable)
        #expect(!retry.unavailable)
    }

    @Test func permissionDeniedCapabilityRemainsUnsupportedDuringBackoff() async throws {
        let api = makeAPI()
        let first: CapabilityState<Int> = try await api.optionalCapability(
            .connectivityDiagnostics, enabled: true, vin: "VIN-A"
        ) { throw PolestarError.permissionDenied(operation: "diagnostics") }
        let retry: CapabilityState<Int> = try await api.optionalCapability(
            .connectivityDiagnostics, enabled: true, vin: "VIN-A"
        ) {
            Issue.record("Permission-gated capability issued another request during backoff")
            return 42
        }
        #expect(first.unsupported)
        #expect(retry.unsupported)
        #expect(!first.unavailable)
        #expect(!retry.unavailable)
    }

    @Test func commandRefreshPreservesUnsupportedBackoffAndClearsTransientBackoff() async throws {
        let api = makeAPI()
        let _: CapabilityState<Int> = try await api.optionalCapability(
            .connectivityDiagnostics, enabled: true, vin: "VIN-A"
        ) { throw PolestarError.permissionDenied(operation: "diagnostics") }
        let _: CapabilityState<Int> = try await api.optionalCapability(
            .tripMeters, enabled: true, vin: "VIN-A"
        ) { throw PolestarError.grpcUnavailable(service: "odometer") }

        await api.clearTransientCapabilityBackoffAfterCommand(for: "VIN-A")

        let diagnostics: CapabilityState<Int> = try await api.optionalCapability(
            .connectivityDiagnostics, enabled: true, vin: "VIN-A"
        ) {
            Issue.record("Command refresh retried a permission-gated capability")
            return 1
        }
        let trips: CapabilityState<Int> = try await api.optionalCapability(
            .tripMeters, enabled: true, vin: "VIN-A"
        ) { 42 }
        #expect(diagnostics.unsupported)
        #expect(trips.value == 42)
    }

    @Test func featureAliasesShareTheSameReadingCache() async throws {
        let api = makeAPI()
        let first: CapabilityState<Int> = try await api.optionalCapability(.exteriorStatus, enabled: true, vin: "VIN-A") { 42 }
        let second: CapabilityState<Int> = try await api.optionalCapability(.remoteLocks, enabled: true, vin: "VIN-A") {
            Issue.record("The same reading was fetched again under another UI feature")
            return 0
        }
        #expect(first.value == second.value)
    }

    @Test func commandConfirmationCanBypassCapabilityCache() async throws {
        let api = makeAPI()
        let counter = CapabilityReadCounter()
        let first: CapabilityState<Int> = try await api.optionalCapability(
            .remoteClimate,
            key: "climate-status",
            enabled: true,
            vin: "VIN-A"
        ) { await counter.next() }
        let cached: CapabilityState<Int> = try await api.optionalCapability(
            .remoteClimate,
            key: "climate-status",
            enabled: true,
            vin: "VIN-A"
        ) { await counter.next() }
        let refreshed: CapabilityState<Int> = try await api.optionalCapability(
            .remoteClimate,
            key: "climate-status",
            enabled: true,
            vin: "VIN-A",
            bypassCache: true
        ) { await counter.next() }

        #expect(first.value == 1)
        #expect(cached.value == 1)
        #expect(refreshed.value == 2)
    }

    @Test func dynamicReadingsNeverInheritMetadataLifetime() {
        for feature: AppFeature in [.tripMeters, .connectivityDiagnostics, .exteriorStatus, .remoteLocks, .remoteWindows] {
            #expect(PolestarAPI.capabilityCacheLifetime(feature, key: feature.rawValue) == 30)
        }
        #expect(PolestarAPI.capabilityCacheLifetime(.chargingDetails, key: "amp-limit") == 30)
        #expect(PolestarAPI.capabilityCacheLifetime(.climateStatus, key: "climate-status") == 15)
        #expect(PolestarAPI.capabilityCacheLifetime(.remoteSchedules, key: "climate-timers") == 60)
        #expect(PolestarAPI.capabilityCacheLifetime(.softwareUpdates, key: "my-cars") == 3600)
    }
}

private actor CapabilityReadCounter {
    private var value = 0

    func next() -> Int? {
        value += 1
        return value
    }
}

private actor CapabilityReadGate {
    private var arrived = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var result: CheckedContinuation<Int?, Never>?
    func read() async -> Int? {
        arrived = true
        arrival?.resume()
        arrival = nil
        return await withCheckedContinuation { result = $0 }
    }
    func waitForArrival() async {
        if !arrived { await withCheckedContinuation { arrival = $0 } }
    }
    func release() { result?.resume(returning: 42); result = nil }
}
