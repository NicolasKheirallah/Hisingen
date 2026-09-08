import Foundation
import Testing
@testable import Hisingen

@Suite(.serialized)
@MainActor
struct VehiclePreparationTests {
    private let vinA = "LP5SVSEDEKML000001"
    private let vinB = "LP2SVSEDEKML000002"

    private func makeAPI() async throws -> PolestarAPI {
        PreparationTransport.counts.reset()
        let api = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.VehiclePreparation.\(UUID())"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreparationTransport.self]
        let session = URLSession(configuration: configuration)
        await api.installPreparationTestSession(session)
        return api
    }

    @Test
    func fetchPreparesAllDiscoveredIdentitiesAndInterleavedReadsRemainVINScoped() async throws {
        let api = try await makeAPI()
        let features = FeatureSelection(enabled: [.vehicleIdentity])
        let first = try await api.fetchVehicleState(vin: vinA, features: features)
        #expect(first.modelName == "Polestar 4")
        #expect(first.registrationNo == "ABC123")
        async let second = api.fetchVehicleState(vin: vinB, features: features)
        async let third = api.fetchVehicleState(vin: vinA, features: features)
        let (b, a) = try await (second, third)
        #expect(b.vin == vinB)
        #expect(b.modelName == "Polestar 2")
        #expect(b.registrationNo == "DEF456")
        #expect(a.vin == vinA)
        #expect(a.modelName == "Polestar 4")
        #expect(await api.resolvedVIN(preferred: nil) == vinA,
                "Fetching a sibling must not change the provider's discovery fallback")
        #expect(PreparationTransport.counts.value("discovery") == 1)
        #expect(PreparationTransport.counts.value("telemetry") == 3)
    }

    @Test
    func optionalArtworkPreparationIsCachedUntilExplicitReload() async throws {
        let api = try await makeAPI()
        let features = FeatureSelection(enabled: [.vehicleImage])
        _ = try await api.fetchVehicleState(vin: vinB, features: features)
        _ = try await api.fetchVehicleState(vin: vinB, features: features)
        #expect(PreparationTransport.counts.value("images") == 1)
        try await api.reloadVehicleMetadata(vin: vinB, features: features)
        _ = try await api.fetchVehicleState(vin: vinB, features: features)
        #expect(PreparationTransport.counts.value("images") == 2)
        #expect(PreparationTransport.counts.value("discovery") == 1)
    }
}

private extension PolestarAPI {
    func installPreparationTestSession(_ testSession: URLSession) {
        session.invalidateAndCancel()
        session = testSession
        accessToken = "test-access-token"
        tokenExpiry = Date().addingTimeInterval(3600)
        // Discovery must not consult another client's credentials in this transport test.
        vdmsDiscoveryBlockedUntil = Date().addingTimeInterval(3600)
    }
}

private final class PreparationRequestCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    func reset() { lock.lock(); defer { lock.unlock() }; values = [:] }
    func increment(_ key: String) { lock.lock(); defer { lock.unlock() }; values[key, default: 0] += 1 }
    func value(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return values[key, default: 0] }
}

private final class PreparationTransport: URLProtocol, @unchecked Sendable {
    static let counts = PreparationRequestCounts()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let query = payload?["query"] as? String ?? ""
            let responseData: Data
            if query.contains("GetConsumerCarsV2") {
                Self.counts.increment("discovery")
                let url = try #require(Bundle.module.url(forResource: "account-cars-multi", withExtension: "json"))
                responseData = try Data(contentsOf: url)
            } else if query.contains("GetCarImages") {
                Self.counts.increment("images")
                responseData = Data(#"{"data":{"getCarImages":{"transparent":[],"opaque":[]}}}"#.utf8)
            } else if let variables = payload?["variables"] as? [String: Any],
                      let vin = (variables["vins"] as? [String])?.first {
                Self.counts.increment("telemetry")
                let url = try #require(Bundle.module.url(forResource: "vehicle-complete", withExtension: "json"))
                let fixture = try String(contentsOf: url, encoding: .utf8)
                responseData = Data(fixture.replacingOccurrences(of: "YSMTEST0000000001", with: vin).utf8)
            } else {
                throw URLError(.unsupportedURL)
            }
            let response = try #require(HTTPURLResponse(url: request.url!, statusCode: 200,
                                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}
