import Foundation
import Testing
@testable import Hisingen

@MainActor
struct PolestarCapabilityTests {
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
            let _: OptionalCapability<Int> = try await api.optionalCapability(.tripMeters, enabled: true, vin: "VIN-A") {
                throw CancellationError()
            }
            Issue.record("Cancellation was swallowed")
        } catch { #expect(error is CancellationError) }
        #expect(await api.capabilityBackoff.isEmpty)
    }

    @Test func backoffPreservesFailureUntilAReadSucceeds() async throws {
        let api = makeAPI()
        let first: OptionalCapability<Int> = try await api.optionalCapability(.tripMeters, enabled: true, vin: "VIN-A") {
            throw PolestarError.grpcUnavailable(service: "test")
        }
        let retry: OptionalCapability<Int> = try await api.optionalCapability(.tripMeters, enabled: true, vin: "VIN-A") {
            Issue.record("Backoff issued another request")
            return 42
        }
        #expect(first.unavailable)
        #expect(retry.unavailable)
        let other: OptionalCapability<Int> = try await api.optionalCapability(.tripMeters, enabled: true, vin: "VIN-B") { 42 }
        #expect(other.value == 42)
        #expect(!other.unavailable)
    }

    @Test func unimplementedCapabilityRemainsUnsupportedDuringBackoff() async throws {
        let api = makeAPI()
        let first: OptionalCapability<Int> = try await api.optionalCapability(
            .connectivityDiagnostics, enabled: true, vin: "VIN-A"
        ) {
            throw PolestarError.grpcUnimplemented(service: "dashboard")
        }
        let retry: OptionalCapability<Int> = try await api.optionalCapability(
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

    @Test func serviceAuthorizationGapRemainsUnsupportedDuringBackoff() async throws {
        let api = makeAPI()
        let first: OptionalCapability<Int> = try await api.optionalCapability(
            .vehicleErrors, enabled: true, vin: "VIN-A"
        ) { throw PolestarError.permissionDenied(operation: "errors") }
        let retry: OptionalCapability<Int> = try await api.optionalCapability(
            .vehicleErrors, enabled: true, vin: "VIN-A"
        ) {
            Issue.record("Permission-gated capability issued another request during backoff")
            return 42
        }
        #expect(first.unsupported)
        #expect(retry.unsupported)
        #expect(!first.unavailable)
        #expect(!retry.unavailable)
    }

    @Test func featureAliasesShareTheSameReadingCache() async throws {
        let api = makeAPI()
        let first: OptionalCapability<Int> = try await api.optionalCapability(.exteriorStatus, enabled: true, vin: "VIN-A") { 42 }
        let second: OptionalCapability<Int> = try await api.optionalCapability(.remoteLocks, enabled: true, vin: "VIN-A") {
            Issue.record("The same reading was fetched again under another UI feature")
            return 0
        }
        #expect(first.value == second.value)
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
