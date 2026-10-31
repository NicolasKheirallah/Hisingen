import Foundation
import Testing
@testable import Hisingen

struct PolestarCapabilityHardeningTests {
    @Test func emptyProbeEvictsPreviousValue() {
        let authority = PolestarCapabilityAuthority()
        authority.recordSuccess(reading: "climate-status", vin: "A", value: 42)
        if case .serveCached = authority.decision(reading: "climate-status", vin: "A") {} else {
            Issue.record("Expected cached reading")
        }
        authority.recordSuccess(reading: "climate-status", vin: "A", value: nil)
        if case .probe = authority.decision(reading: "climate-status", vin: "A") {} else {
            Issue.record("Empty success must evict the previous reading")
        }
    }

    @Test func preservesObservationTimeAndScopesKeys() {
        let authority = PolestarCapabilityAuthority()
        let observed = Date(timeIntervalSince1970: 123)
        authority.recordSuccess(reading: "c", vin: "a|b", value: 1, fetchedAt: observed)
        authority.recordSuccess(reading: "b|c", vin: "a", value: 2)
        #expect(authority.observedAt(reading: "c", vin: "a|b") == observed)
        if case .serveCached(let value) = authority.decision(reading: "c", vin: "a|b") {
            #expect(value as? Int == 1)
        } else { Issue.record("Expected cached reading") }
    }
}

@Suite(.serialized)
struct PolestarGRPCResetHardeningTests {
    @Test func liveStreamCannotConnectAfterReset() async throws {
        let gate = GRPCResetGate()
        GRPCResetProtocol.gate = gate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GRPCResetProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionPolestarGRPCTransport(requestSession: session, liveSession: session)
        let grpc = PolestarGRPC(defaultsSuiteName: "grpc.live-reset.\(UUID())", session: session,
                                diagnosticLog: APIDiagnosticLogStore(), transport: transport)
        let stream = try await grpc.liveUpdates(vin: "VIN-A", accessToken: "token", purpose: .charging)
        let result = Task { () -> Bool in
            do { for try await _ in stream { return true }; return false }
            catch { return false }
        }
        await gate.waitForRequest()
        await grpc.invalidateDiscoveredHost()
        gate.release()
        #expect(await result.value == false)
    }

    @Test func delayedMyCarsCannotRepopulateAfterReset() async throws {
        let gate = GRPCResetGate()
        GRPCResetProtocol.gate = gate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GRPCResetProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let grpc = PolestarGRPC(defaultsSuiteName: "grpc.reset.\(UUID())", session: session,
                                diagnosticLog: APIDiagnosticLogStore())
        let request = Task { try await grpc.fetchMyCars(vin: "VIN-A", accessToken: "token") }
        await gate.waitForRequest()
        await grpc.invalidateDiscoveredHost()
        gate.release()
        _ = try? await request.value
        #expect(await grpc.capabilityLimits["VIN-A"] == nil)
        #expect(await grpc.myCarsInFlight.isEmpty)
    }
}

private final class GRPCResetGate: @unchecked Sendable {
    private let lock = NSLock()
    private var arrived = false
    private var waiter: CheckedContinuation<Void, Never>?
    private let releaseSignal = DispatchSemaphore(value: 0)

    func waitForRequest() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if arrived { lock.unlock(); continuation.resume() }
            else { waiter = continuation; lock.unlock() }
        }
    }

    func markArrived() {
        lock.lock()
        arrived = true
        let continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume()
    }

    func waitForRelease() { releaseSignal.wait() }
    func release() { releaseSignal.signal() }
}

private final class GRPCResetProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var gate: GRPCResetGate?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url else { return }
        if url.host == "cnepmob.volvocars.com" {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"c3":{"grpcHost":"grpc.example","grpcPort":443}}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        guard let gate = Self.gate else { return }
        gate.markArrived()
        DispatchQueue.global().async {
            gate.waitForRelease()
            let car = Protobuf.stringField(1, "VIN-A") + Protobuf.stringField(9, "5.1.9")
            let payload = Protobuf.messageField(1, Protobuf.messageField(1, car))
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Protobuf.grpcFrame(payload))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
}

private actor CapabilityProbeGate {
    private(set) var calls = 0
    private var continuation: CheckedContinuation<Int?, Never>?
    func probe() async -> Int? {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: 80); continuation = nil }
}

extension PolestarAPI {
    fileprivate func targetProbeJoinCount(vin: String) -> Int {
        capabilityAuthority.joinedCount(PolestarReading<Int>.targetSOC, vin: vin)
    }
}

extension PolestarCapabilityHardeningTests {
    @MainActor
    @Test func concurrentProbeIsSharedAndOneWaiterCanCancel() async throws {
        let gate = CapabilityProbeGate()
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.probe.\(UUID())")
        let api = PolestarAPI(keychain: keychain, diagnosticLog: APIDiagnosticLogStore())
        let first = Task {
            try await api.optionalCapability(PolestarReading<Int>.targetSOC, enabled: true, vin: "VIN-A") {
                await gate.probe()
            }
        }
        while await gate.calls == 0 { await Task.yield() }
        let second = Task {
            try await api.optionalCapability(PolestarReading<Int>.targetSOC, enabled: true, vin: "VIN-A") {
                await gate.probe()
            }
        }
        var joined = false
        for _ in 0..<100_000 {
            if await api.targetProbeJoinCount(vin: "VIN-A") == 2 { joined = true; break }
            await Task.yield()
        }
        #expect(joined)
        first.cancel()
        do { _ = try await first.value; Issue.record("Canceled waiter returned a reading") }
        catch { #expect(error is CancellationError) }
        await gate.release()
        let result = try await second.value
        #expect(result.value == 80)
        #expect(await gate.calls == 1)
    }
}

extension PolestarAPI {
    fileprivate func invalidateProbeCache(vin: String) {
        capabilityAuthority.invalidateTransientCaches(forVIN: vin)
    }
    fileprivate func targetProbeIsUncached(vin: String) -> Bool {
        if case .probe = capabilityAuthority.decision(reading: PolestarReading<Int>.targetSOC, vin: vin) { return true }
        return false
    }
}

extension PolestarCapabilityHardeningTests {
    @MainActor
    @Test func commandInvalidationRejectsOlderProbeCompletion() async throws {
        let gate = CapabilityProbeGate()
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.invalidated-probe.\(UUID())")
        let api = PolestarAPI(keychain: keychain, diagnosticLog: APIDiagnosticLogStore())
        let request = Task {
            try await api.optionalCapability(PolestarReading<Int>.targetSOC, enabled: true, vin: "VIN-A") {
                await gate.probe()
            }
        }
        while await gate.calls == 0 { await Task.yield() }
        await api.invalidateProbeCache(vin: "VIN-A")
        await gate.release()
        do { _ = try await request.value; Issue.record("Invalidated reading was accepted") }
        catch { #expect(error is CancellationError) }
        #expect(await api.targetProbeIsUncached(vin: "VIN-A"))
    }
}
