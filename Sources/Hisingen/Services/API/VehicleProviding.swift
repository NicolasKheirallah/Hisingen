import Foundation


protocol VehicleProviding: RemoteCommandExecuting {
    var brand: VehicleBrand { get }
    var cars: [CarSummary] { get async }
    /// True when the provider already holds enough state (a refresh token, known vehicles, and
    /// discovery metadata) to serve `fetchVehicleState` without a full `restoreSession` – the
    /// lazy `refreshTokenIfNeeded` inside the fetch path covers an expired access token. The
    /// background garage scan checks this before re-restoring a dormant brand every pass, which
    /// otherwise forced a token grant and a full vehicle re-discovery every five minutes.
    var hasWarmSession: Bool { get async }
    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws
    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws
    func resetSession() async
    func signOut() async throws
    func resolvedVIN(preferred: String?) async -> String?
    /// Everything the adapter needs before a session can be restored, in its own terms: Volvo
    /// assembles its client credentials here, and an adapter that needs nothing inherits the
    /// no-op. This is what stops a security module from reaching a concrete adapter to configure
    /// it, and what keeps the credentials where the adapter that uses them lives.
    func prepareSession() async throws
    /// Explicitly reload optional metadata; ordinary fetches prepare their VIN internally.
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws
    /// Requires a session, but no prior vehicle-selection call.
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState
    /// Identity the provider already holds for a VIN, without a telemetry fetch. The
    /// augmented provider overlays it onto portal-served state so consumer-only metadata
    /// (model name, plate, owner greeting) survives refreshes that never touch the
    /// consumer API. Nil when the provider holds none.
    func identitySnapshot(for vin: String, features: FeatureSelection) async -> VehicleIdentitySnapshot?
}

extension VehicleProviding {
    func identitySnapshot(for vin: String, features: FeatureSelection) async -> VehicleIdentitySnapshot? { nil }
}

enum VehicleLiveUpdate: Equatable, Sendable {
    case connected(activeTransportStreams: Int)
    case battery(GrpcBatteryExtras)
    case exterior(ExteriorSnapshot, reportedAt: Date?)
}

enum VehicleLiveStreamPurpose: Equatable, Sendable {
    case charging
    case exteriorConfirmation
}

protocol VehicleLiveStreaming: Sendable {
    func liveVehicleUpdates(
        vin: String, purpose: VehicleLiveStreamPurpose
    ) async throws -> AsyncThrowingStream<VehicleLiveUpdate, Error>
    func refreshLiveStreamAuthorization() async throws
}

extension VehicleProviding {
    /// The default: an adapter with no configuration of its own.
    func prepareSession() async throws {}
}

extension PolestarAPI: VehicleProviding {}
extension VolvoAPI: VehicleProviding {}
