import Foundation


protocol VehicleProviding: Sendable {
    var brand: VehicleBrand { get }
    var cars: [CarSummary] { get async }
    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws
    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws
    func resetSession() async
    func signOut() async throws
    func resolvedVIN(preferred: String?) async -> String?
    func selectCar(vin: String, features: FeatureSelection) async throws
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult
}

extension PolestarAPI: VehicleProviding {}
extension VolvoAPI: VehicleProviding {}

