import Foundation
import Testing
@testable import Hisingen

struct PolestarRefreshRequestTests {
    private static let softwarePath = "OtaDiscoveryService"
    private static let schedulePath = "SchedulerService"

    private func makeClient(transport: PathRecordingTransport, session: URLSession) -> PolestarGRPC {
        let suite = "refresh-requests.\(UUID())"
        return PolestarGRPC(defaultsSuiteName: suite, session: session,
                            diagnosticLog: APIDiagnosticLogStore(), transport: transport)
    }

    private func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefreshDiscoveryProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test("A schedule read that hit its deadline is not repeated on the next software read")
    func failedScheduleLegStandsDown() async throws {
        let session = stubbedSession()
        defer { session.invalidateAndCancel() }
        let transport = PathRecordingTransport(failing: [Self.schedulePath])
        let client = makeClient(transport: transport, session: session)

        let first = try await client.fetchSoftware(vin: "VIN-A", accessToken: "token", locale: "en")
        let second = try await client.fetchSoftware(vin: "VIN-A", accessToken: "token", locale: "en")

        #expect(first != nil && second != nil)
        #expect(await transport.count(of: Self.softwarePath) == 2)
        #expect(await transport.count(of: Self.schedulePath) == 1)
    }

    @Test("Command verification still asks for the schedule while the stand-down holds")
    func commandVerificationIgnoresStandDown() async throws {
        let session = stubbedSession()
        defer { session.invalidateAndCancel() }
        let transport = PathRecordingTransport(failing: [Self.schedulePath])
        let client = makeClient(transport: transport, session: session)

        _ = try await client.fetchSoftware(vin: "VIN-A", accessToken: "token", locale: "en")
        _ = try? await client.fetchSoftware(vin: "VIN-A", accessToken: "token", locale: "en",
                                            requireComplete: true)

        #expect(await transport.count(of: Self.schedulePath) == 2)
    }

    @Test("Another vehicle is not held back by one vehicle's stand-down")
    func standDownIsPerVehicle() async throws {
        let session = stubbedSession()
        defer { session.invalidateAndCancel() }
        let transport = PathRecordingTransport(failing: [Self.schedulePath])
        let client = makeClient(transport: transport, session: session)

        _ = try await client.fetchSoftware(vin: "VIN-A", accessToken: "token", locale: "en")
        _ = try await client.fetchSoftware(vin: "VIN-B", accessToken: "token", locale: "en")

        #expect(await transport.count(of: Self.schedulePath) == 2)
    }

    @Test("Schedules and charge locations read together share one ChargeLocationService request")
    func chargeLocationsAreFetchedOncePerRefresh() async throws {
        let session = stubbedSession()
        defer { session.invalidateAndCancel() }
        let transport = PathRecordingTransport(failing: [], delays: ["GlobalChargeTimerService": .milliseconds(120),
                                                                     "ChargeLocationService": .milliseconds(40)])
        let client = makeClient(transport: transport, session: session)

        async let locations = client.fetchChargeLocations(vin: "VIN-A", accessToken: "token")
        async let schedules = client.fetchChargingSchedules(vin: "VIN-A", accessToken: "token",
                                                            includesChargeLocations: true)
        _ = try await (locations, schedules)

        #expect(await transport.count(of: "ChargeLocationService") == 1)
        #expect(await transport.count(of: "GlobalChargeTimerService") == 1)
    }

    @Test("Without the charge-locations feature the schedules read never calls ChargeLocationService")
    func chargeLocationsAreSkippedWhenSwitchedOff() async throws {
        let session = stubbedSession()
        defer { session.invalidateAndCancel() }
        let transport = PathRecordingTransport(failing: [])
        let client = makeClient(transport: transport, session: session)

        _ = try await client.fetchChargingSchedules(vin: "VIN-A", accessToken: "token",
                                                    includesChargeLocations: false)

        #expect(await transport.count(of: "ChargeLocationService") == 0)
        #expect(await transport.count(of: "GlobalChargeTimerService") == 1)
    }

    @Test("Saved charge locations are off by default and when upgrading a stored selection")
    func chargeLocationsStartSwitchedOff() {
        #expect(!FeatureSelection.default.contains(.chargeLocations))
        #expect(!FeatureSelection.default.adding(AppFeature.safeBulkEnableCases.filter { $0 != .chargeLocations })
            .contains(.chargeLocations))
    }

    @Test("The portal plan reads charge locations only when the feature is on")
    func portalPlanFollowsChargeLocationsFeature() {
        #expect(PolestarPortalFetchPlan(features: FeatureSelection(enabled: [.chargingDetails, .chargingSchedule]),
                                        budget: 20).needsChargeLocations == false)
        #expect(PolestarPortalFetchPlan(features: FeatureSelection(enabled: [.chargeLocations]),
                                        budget: 20).needsChargeLocations)
    }
}

private actor PathRecordingTransport: PolestarGRPCTransport {
    nonisolated let supportsTrailers = true
    private var paths: [String] = []
    private let failing: [String]
    private let delays: [String: Duration]

    init(failing: [String], delays: [String: Duration] = [:]) {
        self.failing = failing
        self.delays = delays
    }

    func count(of fragment: String) -> Int { paths.filter { $0.contains(fragment) }.count }

    func execute(for request: URLRequest, live: Bool,
                 onPart: @escaping @Sendable (PolestarGRPCResponsePart) async throws -> Bool) async throws {
        let path = request.url?.path ?? ""
        paths.append(path)
        if let delay = delays.first(where: { path.contains($0.key) })?.value {
            try await Task.sleep(for: delay)
        }
        guard try await onPart(.headers(.init(httpStatus: 200, metadata: [:]))) else { return }
        if failing.contains(where: { path.contains($0) }) {
            _ = try await onPart(.status(.init(code: 4, message: "deadline exceeded", metadata: [:])))
            return
        }
        let body: Data
        if path.contains("OtaDiscoveryService") {
            body = Protobuf.messageField(1, Protobuf.stringField(1, "software-id"))
        } else if path.contains("ChargeLocationService") {
            body = Protobuf.messageField(3, Data())
        } else {
            body = Protobuf.messageField(1, Data())
        }
        guard try await onPart(.message(body)) else { return }
        _ = try await onPart(.status(.init(code: 0, message: nil, metadata: [:])))
    }
}

private final class RefreshDiscoveryProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"c3":{"grpcHost":"grpc.example","grpcPort":443}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
