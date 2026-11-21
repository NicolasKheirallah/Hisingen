import Foundation
import Testing
@testable import Hisingen

private let now = Date(timeIntervalSince1970: 1_780_000_000)
private let credentials = DirectChargerCredentials(username: "owner@example.se", password: "p+ss word&1")

private func easee(_ transport: MockHomeAssistantTransport) -> EaseeProvider {
    EaseeProvider(credentials: credentials, transport: transport, now: { now })
}

private func zaptec(_ transport: MockHomeAssistantTransport) -> ZaptecProvider {
    ZaptecProvider(credentials: credentials, transport: transport, now: { now })
}

private func easeeLogin(_ transport: MockHomeAssistantTransport, status: Int = 200) {
    transport.route("POST", "/api/accounts/login", .json(
        status == 200 ? #"{"accessToken":"AT-1","expiresIn":3600,"refreshToken":"RT-1","tokenType":"Bearer","accessClaims":["User"]}"#
                      : #"{"title":"Bad credentials"}"#, status: status))
}

private func zaptecLogin(_ transport: MockHomeAssistantTransport, status: Int = 200) {
    transport.route("POST", "/oauth/token", .json(
        status == 200 ? #"{"access_token":"ZT-1","token_type":"Bearer","expires_in":3600,"scope":"openid"}"#
                      : #"{"error":"invalid_grant"}"#, status: status))
}

private func observations(_ values: [(Int, String)]) -> Data {
    let rows = values.map { #"{"id":\#($0.0),"timestamp":"2026-11-10T08:00:00Z","dataType":3,"value":"\#($0.1)"}"# }
    return Data(#"{"observations":[\#(rows.joined(separator: ","))]}"#.utf8)
}

private func zaptecState(_ values: [(Int, String)]) -> Data {
    let rows = values.map { #"{"chargerId":"c-1","stateId":\#($0.0),"stateName":"x","timestamp":"2026-11-10T08:00:00Z","valueAsString":"\#($0.1)"}"# }
    return Data("[\(rows.joined(separator: ","))]".utf8)
}

// MARK: - Shared behaviour

@Suite("Direct charger sign-in and errors")
struct DirectChargerSessionTests {
    @Test("The login is sent once and its token is reused, so a poll is one request")
    func tokenIsReused() async throws {
        let transport = MockHomeAssistantTransport()
        easeeLogin(transport)
        transport.route("GET", "/api/chargers", .json(#"[{"id":"EH1","name":"Garage","productCode":400}]"#))
        let provider = easee(transport)
        _ = try await provider.chargers()
        _ = try await provider.chargers()
        #expect(transport.requests(path: "/api/accounts/login").count == 1)
        let listing = transport.requests(path: "/api/chargers")
        #expect(listing.count == 2)
        #expect(listing.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer AT-1" })
    }

    @Test("A token the vendor refuses is replaced once, then the answer stands")
    func reauthenticatesOnce() async throws {
        let transport = MockHomeAssistantTransport()
        easeeLogin(transport)
        let calls = CallCounter()
        transport.route({ $0.url?.path == "/api/chargers" }) { _ in
            calls.increment() == 1 ? .json("{}", status: 401) : .json(#"[{"id":"EH1","name":"Garage"}]"#)
        }
        let list = try await easee(transport).chargers()
        #expect(list.map(\.id) == ["EH1"])
        #expect(transport.requests(path: "/api/accounts/login").count == 2)
    }

    @Test("A refusal that repeats after a fresh login is reported, not retried forever")
    func persistentRefusal() async throws {
        let transport = MockHomeAssistantTransport()
        easeeLogin(transport)
        transport.route("GET", "/api/chargers", .json("{}", status: 401))
        await #expect(throws: DirectChargerError.unauthorized) { _ = try await easee(transport).chargers() }
        #expect(transport.requests(path: "/api/accounts/login").count == 2)
    }

    @Test("A wrong password is an unauthorized error that never repeats the password")
    func wrongPassword() async throws {
        let builders: [(MockHomeAssistantTransport) -> any DirectChargerProvider] = [{ easee($0) }, { zaptec($0) }]
        for build in builders {
            let transport = MockHomeAssistantTransport()
            easeeLogin(transport, status: 400)
            zaptecLogin(transport, status: 400)
            do {
                _ = try await build(transport).chargers()
                Issue.record("expected a refusal")
            } catch let error as DirectChargerError {
                #expect(error == .unauthorized)
                let text = [error.errorDescription, String(describing: error), "\(credentials)"].compactMap { $0 }.joined()
                #expect(!text.contains("p+ss"))
                #expect(!text.contains(credentials.username))
            }
        }
    }

    @Test("An unreachable service is a transient error and a throttled one asks to slow down")
    func transientErrors() async throws {
        let down = MockHomeAssistantTransport()
        down.unreachable = true
        await #expect(throws: DirectChargerError.unreachable) { _ = try await easee(down).chargers() }

        let throttled = MockHomeAssistantTransport()
        easeeLogin(throttled)
        throttled.route("GET", "/api/chargers", .json("{}", status: 429))
        await #expect(throws: DirectChargerError.rateLimited(retryAfter: nil)) { _ = try await easee(throttled).chargers() }
        #expect(DirectChargerError.rateLimited(retryAfter: nil).isTransient)
        #expect(!DirectChargerError.unauthorized.isTransient)
    }

    @Test("The stored login is a Keychain value whose description is redacted")
    func credentialsAreRedacted() {
        #expect(!String(describing: credentials).contains("example.se"))
        #expect(DirectChargerCredentials(username: " ", password: "x").isComplete == false)
        #expect(credentials.isComplete)
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
}

// MARK: - Easee

@Suite("Easee provider")
struct EaseeProviderTests {
    @Test("The login posts the account as JSON and an Equalizer is not offered as a charger")
    func loginAndList() async throws {
        let transport = MockHomeAssistantTransport()
        easeeLogin(transport)
        transport.route("GET", "/api/chargers", .json(#"[{"id":"EH1","name":"Garage","productCode":400},{"id":"EQ1","name":"Meter","productCode":1000}]"#))
        let list = try await easee(transport).chargers()
        #expect(list.map(\.id) == ["EH1"])
        let body = try #require(transport.requests(path: "/api/accounts/login").first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["userName"] == "owner@example.se")
        #expect(json["password"] == "p+ss word&1")
    }

    @Test("Operating mode, reason and dynamic current fold into the charger statuses Hisingen knows",
          arguments: [
            (0, nil, nil, HomeChargerStatus.unavailable),
            (1, nil, nil, .unplugged),
            (2, 5, 16.0, .waitingForPower),
            (2, 1, 16.0, .waitingForPower),
            (2, 54, 16.0, .delayedStart),
            (2, 0, 0.0, .pluggedIn),
            (2, nil, 16.0, .waitingForVehicle),
            (3, nil, 16.0, .charging),
            (4, nil, nil, .finished),
            (5, nil, nil, .error),
            (6, nil, nil, .waitingForVehicle),
            (7, nil, nil, .pluggedIn),
            (9, nil, nil, .unrecognised("op_mode_9"))
          ] as [(Int, Int?, Double?, HomeChargerStatus)])
    func statusMapping(_ opMode: Int, _ reason: Int?, _ dynamic: Double?, _ expected: HomeChargerStatus) {
        #expect(EaseeStatus.map(opMode: opMode, reasonForNoCurrent: reason, dynamicCurrentAmps: dynamic) == expected)
    }

    @Test("A poll yields power, energy and the limit, stamped with the poll time while the charger is online")
    func telemetry() throws {
        let data = observations([(109, "3"), (120, "7.31"), (121, "4.2"), (124, "812.5"), (48, "16"), (103, "true"), (96, "0"), (250, "true")])
        let telemetry = try EaseeProvider.telemetry(from: data, now: now)
        #expect(telemetry.status?.value == .charging)
        #expect(telemetry.powerKw?.value == 7.31)
        #expect(telemetry.sessionEnergyKwh?.value == 4.2)
        #expect(telemetry.lifetimeEnergyKwh?.value == 812.5)
        #expect(telemetry.currentLimitAmps?.value == 16)
        #expect(telemetry.cableLocked?.value == true)
        // The observation said 2026-11-10; the card must not call a quiet charger stale because of it.
        #expect(telemetry.status?.timestamp == now)
        #expect(telemetry.freshness(now: now) == .current(age: 0))
    }

    @Test("Cable rating, phase mode and the connection type fill the charger's detail rows")
    func supplyDetails() throws {
        let data = observations([(109, "3"), (120, "7.31"), (48, "16"), (104, "32"), (38, "3"), (141, "1"), (250, "true")])
        let telemetry = try EaseeProvider.telemetry(from: data, now: now)
        #expect(telemetry.cableLimitAmps?.value == 32)
        #expect(telemetry.phaseMode?.value == .threePhase)
        #expect(telemetry.network?.value == .wifi)
        // Easee measures input terminals and the documentation does not map them to phases, and it
        // publishes no circuit fuse, so those rows stay off.
        #expect(telemetry.phases == nil)
        #expect(telemetry.circuitFuseAmps == nil)

        let cellular = try EaseeProvider.telemetry(from: observations([(109, "3"), (38, "1"), (141, "0")]), now: now)
        #expect(cellular.phaseMode?.value == .singlePhase)
        #expect(cellular.network?.value == .mobile)

        // Values the documentation does not name read as nothing, never as a guess.
        let undocumented = try EaseeProvider.telemetry(from: observations([(109, "3"), (38, "2"), (141, "5"), (104, "0")]), now: now)
        #expect(undocumented.phaseMode == nil)
        #expect(undocumented.network == nil)
        #expect(undocumented.cableLimitAmps == nil)
    }

    @Test("A charger the cloud reports offline is unavailable, never a stale reading of its last state")
    func offline() throws {
        let byMode = try EaseeProvider.telemetry(from: observations([(109, "0"), (120, "7")]), now: now)
        #expect(byMode.status?.value == .unavailable)
        #expect(byMode.powerKw == nil)
        let byCloud = try EaseeProvider.telemetry(from: observations([(109, "3"), (250, "false")]), now: now)
        #expect(byCloud.status?.value == .unavailable)
        #expect(throws: DirectChargerError.malformedResponse) { _ = try EaseeProvider.telemetry(from: Data("nope".utf8), now: now) }
        #expect(try EaseeProvider.telemetry(from: observations([]), now: now).status == nil)
    }

    @Test("The poll asks the observations endpoint for the ids it reads")
    func observationRequest() async throws {
        let transport = MockHomeAssistantTransport()
        easeeLogin(transport)
        transport.route("GET", "/state/EH1/observations", .json(String(decoding: observations([(109, "1")]), as: UTF8.self)))
        let telemetry = try await easee(transport).telemetry(chargerID: "EH1", now: now)
        #expect(telemetry.status?.value == .unplugged)
        let query = try #require(transport.requests(path: "/state/EH1/observations").first?.url?.query)
        #expect(query == "ids=109%2C103%2C120%2C121%2C124%2C48%2C96%2C250%2C104%2C38%2C141")
    }

    @Test("Pause, resume, a delayed start and an authorisation-only start each use their own command")
    func commands() async throws {
        let transport = MockHomeAssistantTransport()
        easeeLogin(transport)
        transport.route("POST", "/api/chargers/EH1/commands/", .json(#"{"device":"EH1","commandId":1,"ticks":1}"#, status: 202))
        let provider = easee(transport)
        func telemetry(_ status: HomeChargerStatus) -> HomeChargerTelemetry {
            HomeChargerTelemetry(status: HomeChargerReading(value: status, timestamp: now))
        }
        try await provider.send(.pause, chargerID: "EH1", telemetry: telemetry(.charging))
        try await provider.send(.start, chargerID: "EH1", telemetry: telemetry(.pluggedIn))
        try await provider.send(.start, chargerID: "EH1", telemetry: telemetry(.delayedStart))
        let paths = transport.requests.map { MockHomeAssistantTransport.encodedPath($0) }.filter { $0.contains("/commands/") }
        #expect(paths == ["/api/chargers/EH1/commands/pause_charging", "/api/chargers/EH1/commands/resume_charging",
                          "/api/chargers/EH1/commands/override_schedule"])

        // A charger that wants authorisation refuses the resume; the start is tried instead.
        let strict = MockHomeAssistantTransport()
        easeeLogin(strict)
        strict.route("POST", "/api/chargers/EH1/commands/resume_charging", .json(#"{"title":"Not allowed"}"#, status: 400))
        strict.route("POST", "/api/chargers/EH1/commands/start_charging", .json("{}", status: 202))
        try await easee(strict).send(.start, chargerID: "EH1", telemetry: telemetry(.pluggedIn))
        #expect(strict.requests(path: "/api/chargers/EH1/commands/start_charging").count == 1)
    }

    @Test("A refused command carries the vendor's own reason")
    func refusedCommand() async throws {
        let transport = MockHomeAssistantTransport()
        easeeLogin(transport)
        transport.route("POST", "/api/chargers/EH1/commands/", .json(#"{"title":"Charger is offline","status":400}"#, status: 400))
        do {
            try await easee(transport).send(.pause, chargerID: "EH1", telemetry: HomeChargerTelemetry())
            Issue.record("expected a refusal")
        } catch DirectChargerError.rejected(let status, let message) {
            #expect(status == 400)
            #expect(message == "Charger is offline")
        }
    }

    @Test("Finished sessions become vendor-keyed candidates; a running or empty one is left out")
    func sessions() throws {
        let list: [[String: Any]] = [
            ["id": 41, "isComplete": true, "kiloWattHours": 12.5, "carConnected": "2026-11-10T20:00:00Z", "carDisconnected": "2026-11-11T06:00:00Z",
             "firstEnergyTransferPeriodStarted": "2026-11-10T22:00:00Z", "lastEnergyTransferPeriodEnd": "2026-11-11T02:00:00Z"],
            ["id": 42, "isComplete": false, "kiloWattHours": 3.0, "carConnected": "2026-11-12T20:00:00Z"],
            ["id": 43, "isComplete": true, "kiloWattHours": 0.02, "carConnected": "2026-11-13T20:00:00Z", "carDisconnected": "2026-11-13T21:00:00Z"],
            ["id": 44, "isComplete": true, "kiloWattHours": 6.0, "carConnected": "2026-11-14T20:00:00Z", "carDisconnected": "2026-11-14T23:00:00Z"]
        ]
        let candidates = EaseeProvider.candidates(from: list, chargerID: "EH1")
        #expect(candidates.map(\.key) == ["vendor:EH1:41", "vendor:EH1:44"])
        #expect(candidates.allSatisfy { $0.keyKind == .vendorSessionID })
        let first = try #require(candidates.first)
        // The energy window is the span used for matching and pricing, not the whole plug-in.
        #expect(first.endedAt.timeIntervalSince(first.startedAt) == 4 * 3_600)
        #expect(first.energyKwh == 12.5)
        #expect(first.energySource == "easee_session_api")
        #expect(first.intervals.isEmpty)
        // Plug-in times stand in when the vendor gives no energy window.
        #expect(candidates.last?.endedAt.timeIntervalSince(candidates.last!.startedAt) == 3.0 * 3_600)
    }

    @Test("The session request names the charger and the period in the path")
    func sessionRequest() async throws {
        let transport = MockHomeAssistantTransport()
        easeeLogin(transport)
        transport.route("GET", "/api/sessions/charger/EH1/sessions/", .json("[]"))
        _ = try await easee(transport).sessions(chargerID: "EH1", from: now.addingTimeInterval(-86_400), to: now)
        let path = try #require(transport.requests.map { MockHomeAssistantTransport.encodedPath($0) }.first { $0.contains("/sessions/20") })
        #expect(path.hasPrefix("/api/sessions/charger/EH1/sessions/2026-"))
    }
}

// MARK: - Zaptec

@Suite("Zaptec provider")
struct ZaptecProviderTests {
    @Test("The token request is a form with the password grant and the password encoded")
    func tokenRequest() async throws {
        let transport = MockHomeAssistantTransport()
        zaptecLogin(transport)
        transport.route("GET", "/api/chargers", .json(#"{"pages":1,"totalCount":2,"data":[{"id":"c-1","name":"Carport","installationName":"Villa","isOnline":true,"active":true},{"id":"c-2","name":"Old","active":false}]}"#))
        let list = try await zaptec(transport).chargers()
        #expect(list.map(\.id) == ["c-1"])
        #expect(list.first?.displayName == "Carport · Villa")
        let login = try #require(transport.requests(path: "/oauth/token").first)
        #expect(login.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(decoding: try #require(login.httpBody), as: UTF8.self)
        #expect(body.contains("grant_type=password"))
        #expect(body.contains("scope=openid"))
        #expect(body.contains("username=owner%40example.se"))
        #expect(body.contains("password=p%2Bss%20word%261"))
        #expect(transport.requests(path: "/api/chargers").first?.value(forHTTPHeaderField: "Authorization") == "Bearer ZT-1")
    }

    @Test("Operation mode, the final-stop flag and a schedule event fold into charger statuses",
          arguments: [
            (1, nil, false, HomeChargerStatus.unplugged),
            (2, nil, false, .pluggedIn),
            (2, nil, true, .delayedStart),
            (3, false, false, .charging),
            (5, true, false, .pluggedIn),
            (5, true, true, .delayedStart),
            (5, false, false, .finished),
            (5, nil, false, .finished),
            (4, nil, false, .unrecognised("operation_mode_4"))
          ] as [(Int, Bool?, Bool, HomeChargerStatus)])
    func statusMapping(_ mode: Int, _ finalStop: Bool?, _ scheduled: Bool, _ expected: HomeChargerStatus) {
        #expect(ZaptecStatus.map(operationMode: mode, finalStopActive: finalStop, hasScheduledEvent: scheduled) == expected)
    }

    @Test("Power arrives in watts and is shown in kilowatts; energy is already kWh")
    func telemetry() throws {
        let data = zaptecState([(710, "3"), (513, "7360"), (553, "5.5"), (708, "16"), (718, "0"), (-2, "1")])
        let telemetry = try ZaptecProvider.telemetry(from: data, now: now)
        #expect(telemetry.status?.value == .charging)
        #expect(telemetry.powerKw?.value == 7.36)
        #expect(telemetry.sessionEnergyKwh?.value == 5.5)
        #expect(telemetry.currentLimitAmps?.value == 16)
        #expect(telemetry.status?.timestamp == now)
    }

    @Test("Phase voltages and currents, the cable rating, the phases in use and the network mode fill the detail rows")
    func supplyDetails() throws {
        let data = zaptecState([(710, "3"), (513, "7360"), (708, "16"),
                                (501, "230"), (502, "231"), (503, "229"),
                                (507, "16"), (508, "15.5"), (509, "16.2"),
                                (714, "32"), (519, "4"), (150, "Wifi")])
        let telemetry = try ZaptecProvider.telemetry(from: data, now: now)
        #expect(telemetry.phases?.value.map(\.volts) == [230, 231, 229])
        #expect(telemetry.phases?.value.map(\.amps) == [16, 15.5, 16.2])
        #expect(telemetry.cableLimitAmps?.value == 32)
        #expect(telemetry.phaseMode?.value == .threePhase)
        #expect(telemetry.network?.value == .wifi)
        // Zaptec publishes no circuit-fuse state, so that row stays off.
        #expect(telemetry.circuitFuseAmps == nil)
    }

    @Test("A phase missing one of its two readings is left out, and undocumented values read as nothing")
    func partialAndUnknown() throws {
        // Phase 2 has a voltage and no current; pairing it with a neighbour would invent a reading.
        let partial = try ZaptecProvider.telemetry(from: zaptecState([(710, "3"), (501, "230"), (502, "231"),
                                                                      (503, "229"), (507, "16"), (509, "16")]), now: now)
        #expect(partial.phases?.value.count == 2)
        #expect(partial.phases?.value.map(\.volts) == [230, 229])

        // SetPhases 1 is one TN phase and 9 is all three IT phases (Zaptec's constants, PhaseIdMap).
        let single = try ZaptecProvider.telemetry(from: zaptecState([(710, "3"), (519, "1")]), now: now)
        #expect(single.phaseMode?.value == .singlePhase)
        let itThreePhase = try ZaptecProvider.telemetry(from: zaptecState([(710, "3"), (519, "9")]), now: now)
        #expect(itThreePhase.phaseMode?.value == .threePhase)

        let lte = try ZaptecProvider.telemetry(from: zaptecState([(710, "3"), (150, "LTE")]), now: now)
        #expect(lte.network?.value == .mobile)
        // PLC and a SetPhases value outside Zaptec's table are left out rather than guessed.
        let plc = try ZaptecProvider.telemetry(from: zaptecState([(710, "3"), (150, "PLC")]), now: now)
        #expect(plc.network == nil)
        let unknown = try ZaptecProvider.telemetry(from: zaptecState([(710, "3"), (519, "7"), (714, "0")]), now: now)
        #expect(unknown.phaseMode == nil)
        #expect(unknown.cableLimitAmps == nil)
    }

    @Test("Paused, scheduled and full are told apart, and offline is unavailable")
    func pausedScheduledFull() throws {
        let paused = try ZaptecProvider.telemetry(from: zaptecState([(710, "5"), (718, "1")]), now: now)
        #expect(paused.status?.value == .pluggedIn)
        #expect(paused.chargingEnabled?.value == false)
        let full = try ZaptecProvider.telemetry(from: zaptecState([(710, "5"), (718, "0")]), now: now)
        #expect(full.status?.value == .finished)
        let future = DirectChargerDates.format(now.addingTimeInterval(3_600))
        let scheduled = try ZaptecProvider.telemetry(from: zaptecState([(710, "5"), (718, "1"), (763, future)]), now: now)
        #expect(scheduled.status?.value == .delayedStart)
        let past = DirectChargerDates.format(now.addingTimeInterval(-3_600))
        let lapsed = try ZaptecProvider.telemetry(from: zaptecState([(710, "5"), (718, "1"), (763, past)]), now: now)
        #expect(lapsed.status?.value == .pluggedIn)
        let offline = try ZaptecProvider.telemetry(from: zaptecState([(710, "3"), (513, "7000"), (-2, "0")]), now: now)
        #expect(offline.status?.value == .unavailable)
        #expect(offline.powerKw == nil)
        #expect(throws: DirectChargerError.malformedResponse) { _ = try ZaptecProvider.telemetry(from: Data("{}".utf8), now: now) }
    }

    @Test("Pause is command 506 and resume 507, and a refusal inside a 200 is reported")
    func commands() async throws {
        let transport = MockHomeAssistantTransport()
        zaptecLogin(transport)
        transport.route("POST", "/api/chargers/c-1/sendCommand/", .json(#"{"Code":200,"Message":"ok"}"#))
        let provider = zaptec(transport)
        try await provider.send(.pause, chargerID: "c-1", telemetry: HomeChargerTelemetry())
        try await provider.send(.start, chargerID: "c-1", telemetry: HomeChargerTelemetry())
        let paths = transport.requests.map { MockHomeAssistantTransport.encodedPath($0) }.filter { $0.contains("sendCommand") }
        #expect(paths == ["/api/chargers/c-1/sendCommand/506", "/api/chargers/c-1/sendCommand/507"])

        let refusing = MockHomeAssistantTransport()
        zaptecLogin(refusing)
        refusing.route("POST", "/api/chargers/c-1/sendCommand/", .json(#"{"Code":528,"Message":"Charging is not Paused nor Scheduled; Resume command cannot be sent"}"#))
        do {
            try await zaptec(refusing).send(.start, chargerID: "c-1", telemetry: HomeChargerTelemetry())
            Issue.record("expected a refusal")
        } catch DirectChargerError.rejected(let status, let message) {
            #expect(status == 528)
            #expect(message.contains("Resume command cannot be sent"))
        }
    }

    @Test("Archived sessions are read page by page, a voided or replaced one is skipped, and energy details become intervals")
    func sessions() async throws {
        let transport = MockHomeAssistantTransport()
        zaptecLogin(transport)
        let page1 = """
        {"sessions":[
          {"id":"s-1","chargerId":"c-1","startDateTime":"2026-11-10T22:00:00Z","endDateTime":"2026-11-11T00:00:00Z","energy":6.0,
           "energyDetails":[{"timestamp":"2026-11-10T22:15:00Z","energy":1.5},{"timestamp":"2026-11-10T22:30:00Z","energy":3.0},
                            {"timestamp":"2026-11-10T22:45:00Z","energy":4.5},{"timestamp":"2026-11-10T23:00:00Z","energy":6.0}]},
          {"id":"s-2","chargerId":"c-1","startDateTime":"2026-11-11T22:00:00Z","endDateTime":"2026-11-11T23:00:00Z","energy":2.0,"voided":true}
        ],"cursor":"next-1","hasMore":true}
        """
        let page2 = """
        {"sessions":[
          {"id":"s-3","chargerId":"c-1","startDateTime":"2026-11-12T22:00:00Z","endDateTime":"2026-11-13T01:00:00Z","energy":9.0},
          {"id":"s-4","chargerId":"c-1","startDateTime":"2026-11-14T22:00:00Z","endDateTime":"2026-11-14T23:00:00Z","energy":3.0,"replacedBySessionId":"s-5"}
        ],"cursor":null,"hasMore":false}
        """
        transport.route({ $0.url?.path == "/api/sessions/archived" }) { request in
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "Cursor" }?.value
            return .json(cursor == "next-1" ? page2 : page1)
        }
        let candidates = try await zaptec(transport).sessions(chargerID: "c-1", from: now.addingTimeInterval(-30 * 86_400), to: now)
        #expect(candidates.map(\.key) == ["vendor:c-1:s-1", "vendor:c-1:s-3"])
        #expect(candidates.allSatisfy { $0.keyKind == .vendorSessionID && $0.energySource == "zaptec_session_api" })
        let first = try #require(candidates.first)
        #expect(first.intervals.count == 4)
        #expect(abs(first.intervalEnergyKwh - 6.0) < 1e-9)
        #expect(first.hasPriceableIntervals)
        #expect(candidates.last?.intervals.isEmpty == true)

        let requests = transport.requests.filter { $0.url?.path == "/api/sessions/archived" }
        #expect(requests.count == 2)
        let items = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "ChargerId" }?.value == "c-1")
        #expect(items.first { $0.name == "PageSize" }?.value == "200")
    }
}

// MARK: - Pairing storage

@Suite("Charger source on a pairing")
struct ChargerSourceTests {
    @Test("A pairing saved before direct chargers existed still decodes, as Home Assistant")
    func legacyPairing() throws {
        let legacy = """
        {"baseURL":"http://homeassistant.local:8123","chargerID":"NX1","chargerName":"NexBlue","entities":{},
         "vin":"YSM","locationAlias":"Home","isSharedCharger":false,"timeZoneIdentifier":"Europe/Stockholm",
         "networkFeeOrePerKwh":0,"pairedAt":"2026-11-01T10:00:00Z"}
        """
        let pairing = try JSONDecoder.iso.decode(HomeChargingPairing.self, from: Data(legacy.utf8))
        #expect(pairing.source == .homeAssistant)
        #expect(pairing.chargerRole == nil)
        #expect(pairing.canControlSchedule)
    }

    @Test("A direct pairing round-trips with its source and carries no Home Assistant address")
    func directRoundTrip() throws {
        let pairing = HomeChargingPairing(baseURL: "", chargerID: "EH1", chargerName: "Garage", entities: HomeChargerEntityMap(),
                                          vin: "YSM", locationID: nil, locationAlias: "Home", source: .easee,
                                          chargerRole: 0)
        let data = try JSONEncoder.sortedISO.encode(pairing)
        let decoded = try JSONDecoder.iso.decode(HomeChargingPairing.self, from: data)
        #expect(decoded.source == .easee)
        #expect(decoded.chargerRole == 0)
        #expect(decoded.baseURL.isEmpty)
        #expect(!String(decoding: data, as: UTF8.self).contains("password"))
    }

    @Test("Only Home Assistant runs plans; Easee and Zaptec are direct")
    func capabilities() {
        #expect(ChargerSource.homeAssistant.supportsPlans)
        #expect(!ChargerSource.easee.supportsPlans && ChargerSource.easee.isDirect)
        #expect(!ChargerSource.zaptec.supportsPlans && ChargerSource.zaptec.isDirect)
    }

    @Test("Only the owner's role keeps the schedule control")
    func scheduleControlNeedsOwner() {
        func pairing(_ role: Int?) -> HomeChargingPairing {
            HomeChargingPairing(baseURL: "", chargerID: "NX1", chargerName: "NexBlue", entities: HomeChargerEntityMap(),
                                vin: "YSM", locationID: nil, locationAlias: "Home", source: .nexBlue,
                                chargerRole: role)
        }
        #expect(pairing(0).canControlSchedule)
        #expect(!pairing(1).canControlSchedule)
        #expect(!pairing(-1).canControlSchedule)
        #expect(!pairing(2).canControlSchedule)
        // A pairing saved before the role was stored keeps the control; the provider still refuses.
        #expect(pairing(nil).canControlSchedule)
    }

    @Test("A session's energy source names the vendor cloud it came from")
    func vendorNames() {
        #expect(WallboxSessionPresentation.vendorName(for: "easee_session_api") == "Easee")
        #expect(WallboxSessionPresentation.vendorName(for: "zaptec_session_api") == "Zaptec")
        #expect(WallboxSessionPresentation.vendorName(for: "ha_session_energy_sensor") == nil)
    }
}
