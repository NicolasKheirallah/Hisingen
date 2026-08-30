import Foundation


protocol VehicleProviding: Sendable {
    var brand: VehicleBrand { get }
    var cars: [CarSummary] { get async }
    /// True when the provider already holds enough state (a refresh token, known vehicles, and
    /// discovery metadata) to serve `fetchVehicleState` without a full `restoreSession` — the
    /// lazy `refreshTokenIfNeeded` inside the fetch path covers an expired access token. The
    /// background garage scan checks this before re-restoring a dormant brand every pass, which
    /// otherwise forced a token grant and a full vehicle re-discovery every five minutes.
    var hasWarmSession: Bool { get async }
    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws
    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws
    func resetSession() async
    func signOut() async throws
    func resolvedVIN(preferred: String?) async -> String?
    func selectCar(vin: String, features: FeatureSelection) async throws
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult
}

enum VehicleLiveUpdate: Sendable {
    case battery(GrpcBatteryExtras)
    case exterior(ExteriorSnapshot, reportedAt: Date?)
}

protocol VehicleLiveStreaming: Sendable {
    func liveVehicleUpdates(vin: String) async throws -> AsyncThrowingStream<VehicleLiveUpdate, Error>
}

extension PolestarAPI: VehicleProviding {}
extension VolvoAPI: VehicleProviding {}

