import Foundation
import Testing
@testable import Hisingen

@Suite(.serialized)
@MainActor
struct PolestarCommandVerificationTests {
    private func makeAPI(now: @escaping @Sendable () -> Date = { Date() }) async -> (PolestarAPI, KeychainStore) {
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.hardening.\(UUID())")
        let api = PolestarAPI(keychain: keychain, diagnosticLog: APIDiagnosticLogStore(), now: now)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HardeningTransport.self]
        await api.hardeningInstall(URLSession(configuration: configuration))
        return (api, keychain)
    }

    @Test func angleChangeDownloadsTheNewSelectedImage() async throws {
        let suiteName = "io.kheirallah.hisingen.tests.artwork.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = KeychainStore(service: suiteName)
        let preferences = PreferencesStore(defaults: defaults, keychain: keychain)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CarImageCache(cacheDirectory: directory,
            database: VehicleDatabase(database: try SQLiteDatabase(path: ":memory:")))
        let api = PolestarAPI(keychain: keychain, imageCache: cache, preferences: preferences,
                              diagnosticLog: APIDiagnosticLogStore())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HardeningTransport.self]
        await api.hardeningInstall(URLSession(configuration: configuration))
        let vin = "YSMED3KA1PL000001"
        await api.restoreDiscovery(cars: [CarSummary(vin: vin, title: vin)], identities: [vin:
            PolestarAPI.CarIdentity(modelYear: "2024", pno34: "P123", structureWeek: "202401")])
        preferences.carRenderAngle = .frontThreeQuarter
        cache.save(Data([1]), for: vin, angle: 1)
        let metadata = VerificationCounter()
        HardeningTransport.handler.set { request in
            if request.url?.path == "/angle2" { return Data([2]) }
            if await metadata.next() == 1 { return Data(#"{"data":{"getCarImages":{"transparent":[]}}}"#.utf8) }
            return Data(#"{"data":{"getCarImages":{"transparent":[{"url":"https://image.example/angle2","angle":2}]}}}"#.utf8)
        }
        await api.fetchCarImage(vin: vin)
        #expect(await api.carImages[vin] == Data([1]))
        preferences.carRenderAngle = .frontDirect
        await api.fetchCarImage(vin: vin)
        #expect(await api.carImages[vin] == Data([2]))
        #expect(cache.image(for: vin, angle: 2) == Data([2]))
    }

    @Test(arguments: [true, false])
    func candidateUsesOnlyMatchingCommandAccountForVDMS(matches: Bool) async throws {
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.vdms.\(UUID())")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HardeningTransport.self]
        let api = PolestarAPI(keychain: keychain, preferences: .shared,
            diagnosticLog: APIDiagnosticLogStore(), backoffs: ProviderBackoffStore(database: .inMemory()))
        await api.hardeningInstall(URLSession(configuration: configuration))
        await api.hardeningInstallVerifiedCommand()
        let vdmsCalls = VerificationCounter()
        HardeningTransport.handler.set { request in
            if request.url?.path == "/token" {
                return Data(#"{"access_token":"candidate","refresh_token":"candidate-refresh","expires_in":3600}"#.utf8)
            }
            if request.url?.path == "/userinfo" {
                let command = request.value(forHTTPHeaderField: "Authorization") == "Bearer command"
                let account = command && !matches ? "different" : "same"
                return Data("{\"sub\":\"\(account)\"}".utf8)
            }
            if request.url?.path.contains("app-backend") == true {
                _ = await vdmsCalls.next()
                return Data(#"{"data":{"vdms":{"getVehiclesInformation":[{"vin":"YSMED3KA1PL000001","content":{"model":{"name":"Polestar 2"}}}]}}}"#.utf8)
            }
            return Data(#"{"data":{"getConsumerCarsV2":[]}}"#.utf8)
        }
        let auth = try await api.beginWebAuthorization()
        let state = try #require(PolestarAPI.queryValue("state", from: auth.authorizeURL))
        let callback = URL(string: "https://www.polestar.com/sign-in-callback?code=code&state=\(state)")!
        if matches {
            try await api.completeWebAuthorization(callbackURL: callback, features: FeatureSelection(enabled: []))
            #expect(await api.selectedVIN == "YSMED3KA1PL000001")
            #expect(await vdmsCalls.value == 1)
        } else {
            do { try await api.completeWebAuthorization(callbackURL: callback); Issue.record("Mismatched command account accepted") }
            catch { }
            #expect(await api.accessToken == "old-access")
            #expect(await vdmsCalls.value == 0)
        }
    }

    @Test func resetWhileResolvingCommandPreventsDispatch() async throws {
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.command.\(UUID())")
        try keychain.saveCommandSessionToken("command-refresh")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HardeningTransport.self]
        let transport = URLSession(configuration: configuration)
        let api = PolestarAPI(keychain: keychain, diagnosticLog: APIDiagnosticLogStore(), grpcSession: transport)
        await api.hardeningInstall(URLSession(configuration: configuration))
        let vin = "YSMED3KA1PL000001"
        await api.restoreDiscovery(cars: [CarSummary(vin: vin, title: vin)], identities: [:])
        let gate = HardeningGate()
        let dispatches = VerificationCounter()
        HardeningTransport.handler.set { request in
            if request.url?.path == "/token" {
                await gate.wait()
                return Data(#"{"access_token":"command","refresh_token":"rotated","expires_in":3600}"#.utf8)
            }
            if request.url?.path == "/userinfo" { return Data(#"{"sub":"same"}"#.utf8) }
            _ = await dispatches.next()
            return Data()
        }
        let command = Task { try await api.executeRemoteCommand(.lock, vin: vin) }
        await gate.waitForArrival()
        await api.resetSession()
        await gate.release()
        do { _ = try await command.value; Issue.record("Superseded command dispatched") }
        catch { }
        #expect(await dispatches.value == 0)
    }

    @Test func authorizationTimeoutUsesInjectedClock() async throws {
        let clock = HardeningClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (api, _) = await makeAPI(now: { clock.read() })
        let auth = try await api.beginWebAuthorization()
        let state = try #require(PolestarAPI.queryValue("state", from: auth.authorizeURL))
        let callback = URL(string: "https://www.polestar.com/sign-in-callback?code=code&state=\(state)")!
        clock.advance(601)
        do { try await api.completeWebAuthorization(callbackURL: callback); Issue.record("Expired callback accepted") }
        catch { #expect(error is PolestarError) }
        #expect(await api.accessToken == "old-access")
    }

    @Test func failedAccountVerificationIsRetriedBeforeTokenReuse() async throws {
        let (api, keychain) = await makeAPI()
        let count = VerificationCounter()
        HardeningTransport.handler.set { request in
            if request.url?.path == "/userinfo" {
                let number = await count.next()
                return number == 1 ? Data("{}".utf8) : Data(#"{"sub":"same"}"#.utf8)
            }
            return Data(#"{"access_token":"command","refresh_token":"rotated","expires_in":3600}"#.utf8)
        }
        let authorize = try await api.beginCommandAuthorization()
        let state = try #require(PolestarAPI.queryValue("state", from: authorize))
        let callback = URL(string: "polestar-explore://explore.polestar.com?code=code&state=\(state)")!
        do { try await api.completeCommandAuthorization(callbackURL: callback); Issue.record("Expected verification failure") }
        catch { }
        #expect(try keychain.readCommandSessionToken() == "rotated")
        #expect(await api.commandClientAuthorization() == .authorized("command"))
        #expect(await count.value == 3)
    }

    @Test func supersededWebCompletionCannotPublishCandidate() async throws {
        let (api, keychain) = await makeAPI()
        let gate = HardeningGate()
        HardeningTransport.handler.set { request in
            if request.url?.path == "/token" {
                await gate.wait()
                return Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8)
            }
            return Data(#"{"data":{"getConsumerCarsV2":[{"vin":"YSMED3KA1PL000001"}]}}"#.utf8)
        }
        let first = try await api.beginWebAuthorization()
        let state = try #require(PolestarAPI.queryValue("state", from: first.authorizeURL))
        let callback = URL(string: "https://www.polestar.com/sign-in-callback?code=code&state=\(state)")!
        let completion = Task { try await api.completeWebAuthorization(callbackURL: callback) }
        await gate.waitForArrival()
        _ = try await api.beginWebAuthorization()
        await gate.release()
        do { try await completion.value; Issue.record("Superseded candidate was accepted") }
        catch { #expect(error is CancellationError) }
        #expect(await api.accessToken == "old-access")
        #expect(try keychain.readSessionToken() != "new-refresh")
    }
    @Test func overlappingPasswordLoginsKeepTheNewestSession() async throws {
        let (api, keychain) = await makeAPI()
        let gate = HardeningGate()
        let counter = VerificationCounter()
        HardeningTransport.handler.set { request in
            if request.url?.path.contains("openid-configuration") == true {
                return Data(#"{"issuer":"https://polestarid.eu.polestar.com","token_endpoint":"https://polestarid.eu.polestar.com/token","authorization_endpoint":"https://polestarid.eu.polestar.com/authorize"}"#.utf8)
            }
            if request.url?.path == "/token" {
                let attempt = await counter.next()
                if attempt == 1 { await gate.wait() }
                let name = attempt == 1 ? "old-candidate" : "new-candidate"
                return Data("{\"access_token\":\"\(name)\",\"refresh_token\":\"\(name)-refresh\",\"expires_in\":3600}".utf8)
            }
            return Data(#"{"data":{"getConsumerCarsV2":[{"vin":"YSMED3KA1PL000001"}]}}"#.utf8)
        }
        let old = Task { try await api.authenticate(email: "a@example.test", password: "password", preferredVIN: nil, features: FeatureSelection(enabled: [])) }
        await gate.waitForArrival()
        try await api.authenticate(email: "b@example.test", password: "password", preferredVIN: nil, features: FeatureSelection(enabled: []))
        await gate.release()
        do { try await old.value; Issue.record("Superseded password login was accepted") }
        catch { #expect(error is CancellationError) }
        #expect(await api.accessToken == "new-candidate")
        #expect(try keychain.readSessionToken() == "new-candidate-refresh")
    }

    @Test func successfulCandidatePublishesTokenAndGarageTogether() async throws {
        let (api, keychain) = await makeAPI()
        HardeningTransport.handler.set { request in
            if request.url?.path == "/token" {
                return Data(#"{"access_token":"candidate","refresh_token":"candidate-refresh","expires_in":3600}"#.utf8)
            }
            return Data(#"{"data":{"getConsumerCarsV2":[{"vin":"YSMED3KA1PL000001"}]}}"#.utf8)
        }
        let auth = try await api.beginWebAuthorization()
        let state = try #require(PolestarAPI.queryValue("state", from: auth.authorizeURL))
        let callback = URL(string: "https://www.polestar.com/sign-in-callback?code=code&state=\(state)")!
        try await api.completeWebAuthorization(callbackURL: callback, features: FeatureSelection(enabled: []))
        #expect(await api.accessToken == "candidate")
        #expect(await api.selectedVIN == "YSMED3KA1PL000001")
        #expect(try keychain.readSessionToken() == "candidate-refresh")
    }

    @Test func signOutDuringCandidateDiscoveryCannotRestoreSession() async throws {
        let (api, keychain) = await makeAPI()
        let gate = HardeningGate()
        HardeningTransport.handler.set { request in
            if request.url?.path == "/token" {
                return Data(#"{"access_token":"candidate","refresh_token":"candidate-refresh","expires_in":3600}"#.utf8)
            }
            await gate.wait()
            return Data(#"{"data":{"getConsumerCarsV2":[{"vin":"YSMED3KA1PL000001"}]}}"#.utf8)
        }
        let auth = try await api.beginWebAuthorization()
        let state = try #require(PolestarAPI.queryValue("state", from: auth.authorizeURL))
        let callback = URL(string: "https://www.polestar.com/sign-in-callback?code=code&state=\(state)")!
        let completion = Task { try await api.completeWebAuthorization(callbackURL: callback) }
        await gate.waitForArrival()
        try await api.signOut()
        await gate.release()
        do { try await completion.value; Issue.record("Signed-out candidate was accepted") }
        catch { #expect(error is CancellationError) }
        #expect(await api.accessToken == nil)
        #expect(try keychain.readSessionToken() == nil)
    }

    @Test func failedDiscoveryLeavesPreviousSessionIntact() async throws {
        let (api, keychain) = await makeAPI()
        try keychain.saveSessionToken("old-refresh")
        HardeningTransport.handler.set { request in
            if request.url?.path == "/token" {
                return Data(#"{"access_token":"candidate","refresh_token":"candidate-refresh","expires_in":3600}"#.utf8)
            }
            return Data(#"{"data":{"getConsumerCarsV2":[]}}"#.utf8)
        }
        let auth = try await api.beginWebAuthorization()
        let state = try #require(PolestarAPI.queryValue("state", from: auth.authorizeURL))
        let callback = URL(string: "https://www.polestar.com/sign-in-callback?code=code&state=\(state)")!
        do { try await api.completeWebAuthorization(callbackURL: callback); Issue.record("Empty discovery accepted") }
        catch { }
        #expect(await api.accessToken == "old-access")
        #expect(try keychain.readSessionToken() == "old-refresh")
    }

}

private extension PolestarAPI {
    func hardeningInstallVerifiedCommand() {
        commandAccessToken = "command"
        commandRefreshToken = "command-refresh"
        commandTokenExpiry = Date().addingTimeInterval(3600)
        verifiedCommandToken = ("command", sessionEpoch, "same")
    }

    func hardeningInstall(_ transport: URLSession) {
        session.invalidateAndCancel()
        session = transport
        authorizationEndpoint = URL(string: "https://auth.example/authorize")!
        tokenEndpoint = URL(string: "https://auth.example/token")!
        userinfoEndpoint = URL(string: "https://auth.example/userinfo")!
        accessToken = "old-access"
        refreshToken = "old-refresh"
        tokenExpiry = Date().addingTimeInterval(3600)
        tokenLifetime = 3600
    }
}

private actor VerificationCounter {
    private(set) var value = 0
    func next() -> Int { value += 1; return value }
}

private actor HardeningGate {
    private var arrived = false
    private var released = false
    private var arrival: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        arrived = true
        arrival.forEach { $0.resume() }
        arrival.removeAll()
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }
    func waitForArrival() async {
        if !arrived { await withCheckedContinuation { arrival.append($0) } }
    }
    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private final class HardeningHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: @Sendable (URLRequest) async -> Data = { _ in Data() }
    func set(_ handler: @escaping @Sendable (URLRequest) async -> Data) {
        lock.lock(); defer { lock.unlock() }; self.handler = handler
    }
    func get() -> @Sendable (URLRequest) async -> Data {
        lock.lock(); defer { lock.unlock() }; return handler
    }
}

private final class HardeningTransport: URLProtocol, @unchecked Sendable {
    static let handler = HardeningHandler()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let respond = Self.handler.get()
        Task { @Sendable [self, respond] in
            let data = await respond(request)
            let responseURL: URL
            if request.url?.path == "/authorize", let state = PolestarAPI.queryValue("state", from: request.url) {
                responseURL = URL(string: "https://www.polestar.com/sign-in-callback?code=code&state=\(state)")!
            } else {
                responseURL = request.url!
            }
            let headers = request.url?.path == "/angle2" ? ["Content-Type": "image/png"] : nil
            let response = HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

private final class HardeningClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func read() -> Date { lock.withLock { date } }
    func advance(_ interval: TimeInterval) { lock.withLock { date.addTimeInterval(interval) } }
}
