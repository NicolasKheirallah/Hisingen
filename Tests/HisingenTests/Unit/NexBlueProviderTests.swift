import Foundation
import Testing
@testable import Hisingen

private let root = "/third_party/openapi"
private let serial = "NX123"
private let now = Date(timeIntervalSince1970: 1_780_000_000)
private let credentials = DirectChargerCredentials(username: " owner@example.com ", password: "secret-password")

private func cloud() -> MockHomeAssistantTransport {
    let transport = MockHomeAssistantTransport()
    transport.route("POST", root + "/account/login", .json(
        #"{"access_token":"access","refresh_token":"refresh","expires_in":3600,"token_type":"Bearer"}"#))
    transport.route("POST", root + "/account/refresh_token", .json(
        #"{"access_token":"renewed","expires_in":3600,"token_type":"Bearer"}"#))
    transport.route("GET", root + "/chargers", .json(#"{"data":[{"serial_number":"NX123","role":0}]}"#))
    return transport
}

private func provider(_ transport: MockHomeAssistantTransport) -> NexBlueProvider {
    NexBlueProvider(transport: transport, now: { now }) { transport in
        try await NexBlueProvider.refresh("refresh", transport: transport).bearer
    }
}

struct NexBlueProviderTests {
    @Test func signsInAndListsChargersWithTheReturnedToken() async throws {
        let transport = cloud()
        let result = try await NexBlueProvider.signIn(credentials, transport: transport)
        #expect(result.chargers.map(\.id) == [serial])
        #expect(result.refreshToken == "refresh")
        let login = try #require(transport.requests(path: root + "/account/login").first)
        let body = try #require(login.httpBody)
        let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(login.url?.host == "api.nexblue.com")
        #expect(login.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(fields["username"] as? String == "owner@example.com")
        #expect(fields["password"] as? String == credentials.password)
        #expect(fields["account_type"] as? Int == 0)
        #expect(transport.requests(path: root + "/chargers").first?.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(transport.requests(path: root + "/account/refresh_token").isEmpty)
    }

    @Test func rejectsInvalidGrantsAndDoesNotForwardRawErrorMessages() async throws {
        let transport = cloud()
        transport.route("POST", root + "/account/login", .json(#"{"code":1501,"message":"secret-password"}"#, status: 400))
        transport.route("POST", root + "/account/refresh_token", .json(#"{"code":1502,"message":"refresh"}"#, status: 400))
        await #expect(throws: DirectChargerError.unauthorized) {
            _ = try await NexBlueProvider.signIn(credentials, transport: transport)
        }
        await #expect(throws: DirectChargerError.unauthorized) { _ = try await provider(transport).chargers() }
        #expect(transport.requests(path: root + "/account/refresh_token").count == 1)
    }

    @Test func refreshesOnceWhenAccessIsRejectedAndSurfacesRateLimits() async throws {
        let transport = cloud()
        let listPath = root + "/chargers"
        transport.route({ $0.url?.path == listPath }) { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer renewed"
                ? .json(#"{"data":[{"serial_number":"NX123"}]}"#)
                : .json("{}", status: 401)
        }
        let provider = NexBlueProvider(transport: transport, now: { now },
                                      initialToken: .init(value: "expired", lifetime: 3_600)) { transport in
            try await NexBlueProvider.refresh("refresh", transport: transport).bearer
        }
        #expect(try await provider.chargers().map(\.id) == [serial])
        #expect(transport.requests(path: listPath).count == 2)
        #expect(transport.requests(path: root + "/account/refresh_token").count == 1)

        transport.route("GET", listPath, .json("{}", status: 429))
        await #expect(throws: DirectChargerError.rateLimited(retryAfter: nil)) { _ = try await provider.chargers() }
        #expect(transport.requests(path: root + "/account/refresh_token").count == 1)
    }

    @Test(arguments: [HomeChargerStatus.unplugged, .pluggedIn, .charging, .finished, .error,
                      .waitingForPower, .delayedStart, .waitingForVehicle].enumerated().map { ($0.offset, $0.element) })
    func mapsChargerStatus(code: Int, expected: HomeChargerStatus) async throws {
        let transport = cloud()
        transport.route("GET", root + "/chargers/NX123/cmd/status", .json(
            #"{"charging_state":\#(code),"power":7.2,"energy":3.4,"lifetime_energy":100.5,"current_limit":16,"is_lock":true}"#))
        let telemetry = try await provider(transport).telemetry(chargerID: serial, now: now)
        #expect(telemetry.status == .init(value: expected, timestamp: now))
        #expect(telemetry.powerKw?.value == 7.2)
        #expect(telemetry.sessionEnergyKwh?.value == 3.4)
        #expect(telemetry.lifetimeEnergyKwh?.value == 100.5)
        #expect(telemetry.currentLimitAmps?.value == 16)
        #expect(telemetry.cableLocked?.value == true)
    }

    @Test func startAndStopValidateTheCommandResult() async throws {
        let transport = cloud()
        let start = root + "/chargers/NX123/cmd/start_charging"
        let stop = root + "/chargers/NX123/cmd/stop_charging"
        transport.route("POST", start, .json(#"{"result":0}"#))
        transport.route("POST", stop, .json(#"{"result":5}"#))
        let provider = provider(transport)
        try await provider.send(.start, chargerID: serial, telemetry: .init())
        await #expect(throws: DirectChargerError.rejected(status: 200, message: L10n.text("Another user is using this charger."))) {
            try await provider.send(.pause, chargerID: serial, telemetry: .init())
        }
        let request = try #require(transport.requests(path: start).first)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpBody == Data("{}".utf8))
        #expect(transport.requests(path: stop).count == 1)
        #expect(transport.requests(path: root + "/account/refresh_token").count == 1)
    }

    @Test(arguments: [1, 2, 3, 4, 5]) func commandRefusalsHaveSpecificReasons(code: Int) async {
        let transport = cloud()
        transport.route("POST", root + "/chargers/NX123/cmd/start_charging", .json("{\"result\":\(code)}"))
        let error: DirectChargerError
        switch code {
        case 2: error = .forbidden
        case 3: error = .rejected(status: 200, message: L10n.text("The charger's safety self-test failed."))
        case 4: error = .rejected(status: 200, message: L10n.text("Charging is disabled on this charger."))
        case 5: error = .rejected(status: 200, message: L10n.text("Another user is using this charger."))
        default: error = .rejected(status: 200, message: "")
        }
        await #expect(throws: error) { try await provider(transport).send(.start, chargerID: serial, telemetry: .init()) }
    }

    @Test func offlineChargerHasUnavailableTelemetryAndRejectsCommands() async throws {
        let transport = cloud()
        let status = root + "/chargers/NX123/cmd/status"
        transport.route("GET", status, .json(#"{"code":2105}"#, status: 400))
        transport.route("POST", root + "/chargers/NX123/cmd/start_charging", .json(#"{"code":2105}"#, status: 400))
        let provider = provider(transport)
        let telemetry = try await provider.telemetry(chargerID: serial, now: now)
        #expect(telemetry.status?.value == .unavailable)
        #expect(telemetry.powerKw == nil)
        await #expect(throws: DirectChargerError.chargerOffline) {
            try await provider.send(.start, chargerID: serial, telemetry: telemetry)
        }
    }

    @Test func historyUsesFinishedWindowsAndNormalizesEpochUnits() async throws {
        let transport = cloud()
        let path = root + "/sessions/charger/" + serial
        transport.route("GET", path, .json("""
            {"data":[
                {"start_timestamp":1779996400,"end_timestamp":1779998200,"consumption":5.5},
                {"start_timestamp":1779996400000,"end_timestamp":1779998200000,"consumption":5.5},
                {"start_timestamp":1779996400,"consumption":7.25},
                {"start_timestamp":1779996300,"end_timestamp":1780000001,"consumption":3},
                {"start_timestamp":1779996300,"end_timestamp":1779996900,"consumption":0}
            ]}
            """))
        let from = now.addingTimeInterval(-2_700)
        let candidates = try await provider(transport).sessions(chargerID: serial, from: from, to: now)
        #expect(candidates.count == 2)
        let first = try #require(candidates.first)
        #expect(candidates.allSatisfy { $0.key == first.key && $0.keyKind == .vendorWindow && $0.energyKwh == 5.5 })
        #expect(first.startedAt < from)
        #expect(first.intervals.isEmpty)
        let request = try #require(transport.requests(path: path).first)
        let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "from_date" }?.value == DirectChargerDates.format(from.addingTimeInterval(-86_400)))
        #expect(query?.first { $0.name == "to_date" }?.value == DirectChargerDates.format(now))
    }

    @Test func historyBatchesOlderRangesWithoutDuplicatingBoundarySessions() async throws {
        let transport = cloud()
        let path = root + "/sessions/charger/" + serial
        let from = now.addingTimeInterval(-60 * 86_400)
        let boundary = from.addingTimeInterval(29 * 86_400)
        let boundaryEpoch = Int(boundary.timeIntervalSince1970)
        transport.route("GET", path, .json("""
          {"data":[{"start_timestamp":\(boundaryEpoch - 1800),"end_timestamp":\(boundaryEpoch),"consumption":5.5}]}
          """))
        let records = try await provider(transport).sessions(chargerID: serial, from: from, to: now)
        #expect(records.count == 1)
        #expect(records.first?.endedAt == boundary)
        let requests = transport.requests(path: path)
        #expect(requests.count == 3)
        let intervals = requests.compactMap { request -> TimeInterval? in
            guard let url = request.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  let fromValue = items.first(where: { $0.name == "from_date" })?.value,
                  let toValue = items.first(where: { $0.name == "to_date" })?.value,
                  let from = DirectChargerDates.parse(fromValue), let to = DirectChargerDates.parse(toValue) else { return nil }
            return to.timeIntervalSince(from)
        }
        let day: TimeInterval = 86_400
        let expected = [30 * day, 30 * day, 3 * day]
        #expect(intervals == expected)
    }

    @Test func scheduleReadbackPreservesTheExistingSlotAndResolvesAnUncertainWrite() async throws {
        let transport = cloud()
        let detail = root + "/chargers/" + serial
        let path = detail + "/cmd/schedule"
        let old = #"{"start_hour":21,"start_minute":0,"stop_hour":22,"stop_minute":0,"repeat_days":[1],"enabled":false,"schedule_current_limit":16}"#
        let added = #"{"start_hour":23,"start_minute":0,"stop_hour":1,"stop_minute":0,"repeat_days":[],"enabled":true,"schedule_current_limit":32}"#
        transport.route("GET", detail, .json(
            #"{"role":0,"online":true,"device_operator_type":0,"place_data":{"country":"SE","tz_id":"Europe/Stockholm"}}"#))
        transport.route({ $0.httpMethod == "GET" && MockHomeAssistantTransport.encodedPath($0) == path }, { [weak transport] _ in
            let hasWrite = transport?.requests(path: path).contains { $0.httpMethod == "PUT" } == true
            let items = hasWrite ? "\(old),\(added)" : old
            return .json("{\"schedule_mode\":2,\"charge_schedules\":[\(items)]}")
        })
        transport.route("PUT", path, .json(#"{"code":2101}"#, status: 400))
        let charger = provider(transport)
        let schedule = try await charger.schedule(chargerID: serial)
        let start = try #require(DirectChargerDates.parse("2026-11-17T22:00:00Z"))
        let reference = start.addingTimeInterval(-3600)
        let preview = NexBlueTimerPreview(chargerID: serial, zone: .se3, schedule: schedule,
                                          window: DateInterval(start: start, duration: 2 * 3600))
        try await charger.saveTimer(preview, now: { reference }, canWrite: { true })
        let writes = transport.requests(path: path).filter { $0.httpMethod == "PUT" }
        #expect(writes.count == 1)
        let body = try #require(writes.first?.httpBody)
        let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let item = try #require(fields["schedule_item"] as? [String: Any])
        #expect(fields["schedule_index"] as? Int == 1)
        #expect(item["start_hour"] as? Int == 23)
        #expect(item["stop_hour"] as? Int == 1)
        #expect(item["repeat_days"] as? [Int] == [])
        #expect(item["schedule_current_limit"] == nil)
        #expect(transport.requests(path: path).filter { $0.httpMethod == "GET" }.count == 3)
        await #expect(throws: NexBlueTimerError.activeSchedule) {
            try await charger.saveTimer(preview, now: { reference }, canWrite: { true })
        }
        #expect(transport.requests(path: path).filter { $0.httpMethod == "PUT" }.count == 1)
    }

    @Test func scheduleAcknowledgmentWithoutMatchingReadbackIsUnconfirmed() async throws {
        let transport = cloud()
        let detail = root + "/chargers/" + serial
        let path = detail + "/cmd/schedule"
        transport.route("GET", detail, .json(
            #"{"role":0,"online":true,"device_operator_type":0,"place_data":{"country":"SE","tz_id":"Europe/Stockholm"}}"#))
        transport.route("GET", path, .json(#"{"schedule_mode":2,"charge_schedules":[]}"#))
        transport.route("PUT", path, .json(#"{"result":0}"#))
        let charger = provider(transport)
        let schedule = try await charger.schedule(chargerID: serial)
        let start = try #require(DirectChargerDates.parse("2026-11-17T22:00:00Z"))
        let preview = NexBlueTimerPreview(chargerID: serial, zone: .se3, schedule: schedule,
                                          window: DateInterval(start: start, duration: 3600))
        await #expect(throws: NexBlueTimerError.changed) {
            try await charger.saveTimer(preview, now: { start.addingTimeInterval(-3600) }, canWrite: { false })
        }
        #expect(transport.requests(path: path).allSatisfy { $0.httpMethod == "GET" })
        await #expect(throws: NexBlueTimerError.unconfirmed) {
            try await charger.saveTimer(preview, now: { start.addingTimeInterval(-3600) }, canWrite: { true })
        }
        #expect(transport.requests(path: path).filter { $0.httpMethod == "PUT" }.count == 1)
    }

    @Test func scheduleLeavesBothOccupiedSlotsIntactAndRejectsEcoMode() async throws {
        let transport = cloud()
        let detail = root + "/chargers/" + serial
        let path = detail + "/cmd/schedule"
        transport.route("GET", detail, .json(
            #"{"role":0,"online":true,"device_operator_type":0,"place_data":{"country":"SE","tz_id":"Europe/Stockholm"}}"#))
        transport.route("GET", path, .json(#"{"schedule_mode":1,"charge_schedules":[]}"#))
        let charger = provider(transport)
        await #expect(throws: NexBlueTimerError.unsupported) { try await charger.schedule(chargerID: serial) }
        let item = #"{"start_hour":23,"start_minute":0,"stop_hour":1,"stop_minute":0,"repeat_days":[],"enabled":false}"#
        transport.route("GET", path, .json("{\"schedule_mode\":2,\"charge_schedules\":[\(item),\(item)]}"))
        let schedule = try await charger.schedule(chargerID: serial)
        #expect(throws: NexBlueTimerError.noSlot) { try schedule.checkAvailable() }
        #expect(transport.requests(path: path).allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func timerUsesCompletePricesAndRejectsAmbiguousClockTimes() throws {
        let zone = try #require(TimeZone(identifier: "Europe/Stockholm"))
        let schedule = NexBlueSchedule(timeZone: zone, items: [])
        let evening = try #require(DirectChargerDates.parse("2026-11-17T17:00:00Z"))
        let cheap = evening.addingTimeInterval(5 * 3600)
        let prices = (0..<52).map { index in
            let start = evening.addingTimeInterval(Double(index) * 900)
            return ElectricityPricePoint(startDate: start, endDate: start.addingTimeInterval(900),
                                         sekPerKwh: index >= 20 && index < 28 ? 0.2 : 1.5)
        }
        let preview = try NexBlueTimerPreview.make(chargerID: serial, schedule: schedule, zone: .se3,
                                                   prices: prices, hours: 2, now: evening.addingTimeInterval(-3600))
        #expect(preview.window.start == cheap)
        #expect(preview.item.startHour == 23)
        #expect(preview.item.stopHour == 1)
        #expect(throws: NexBlueTimerError.missingPrices) {
            try NexBlueTimerPreview.make(chargerID: serial, schedule: schedule, zone: .se3,
                                         prices: Array(prices.dropLast()), hours: 2, now: evening.addingTimeInterval(-3600))
        }

        let fall = try #require(DirectChargerDates.parse("2026-10-24T21:00:00Z"))
        let ambiguousStart = try #require(DirectChargerDates.parse("2026-10-25T00:30:00Z"))
        let afterChange = try #require(DirectChargerDates.parse("2026-10-25T02:00:00Z"))
        #expect(!NexBlueTimerPreview.canRepresent(DateInterval(start: ambiguousStart, duration: 3600), in: zone, after: fall))
        #expect(!NexBlueTimerPreview.canRepresent(DateInterval(start: ambiguousStart.addingTimeInterval(3600), duration: 3600),
                                                  in: zone, after: fall))
        #expect(NexBlueTimerPreview.canRepresent(DateInterval(start: afterChange, duration: 3600), in: zone, after: fall))
        let spring = try #require(DirectChargerDates.parse("2026-03-29T00:00:00Z"))
        #expect(!NexBlueTimerPreview.canRepresent(DateInterval(start: spring, duration: 7200),
                                                  in: zone, after: spring.addingTimeInterval(-3600)))
    }

    @Test @MainActor func pairsAndRestoresFromRefreshTokenWithoutHomeAssistant() async throws {
        let transport = cloud()
        let path = root + "/chargers/NX123/cmd/status"
        transport.route("GET", path, .json(#"{"charging_state":1,"power":0,"energy":0}"#))
        transport.route("POST", root + "/chargers/NX123/cmd/start_charging", .json(#"{"result":0}"#))
        transport.route("GET", root + "/sessions/charger/NX123", .json(
            #"{"data":[{"start_timestamp":1779996400,"end_timestamp":1779998200,"consumption":5.5}]}"#))
        transport.route("POST", root + "/account/refresh_token", .json(
            #"{"access_token":"renewed","refresh_token":"rotated","expires_in":3600,"token_type":"Bearer"}"#))
        let scoped = ScopedPreferences(label: "nexblue")
        let database = VehicleDatabase.inMemory()
        scoped.store.storeChargingHistory = true
        let dependencies = HomeChargingModel.Dependencies(
            transport: transport, socketConnector: nil, now: { now },
            wait: { _ in try await Task.sleep(for: .seconds(3_600)) },
            spotPrices: { _ in [] },
            timerPrices: { _ in [
                ElectricityPricePoint(startDate: now.addingTimeInterval(-3_600), endDate: now.addingTimeInterval(12 * 3_600),
                                      sekPerKwh: 1)
            ] }, observesWake: false)
        let setup = HomeChargingModel(preferences: scoped.store, database: database, dependencies: dependencies)
        let chargers = try await setup.connectDirect(.nexBlue, credentials: credentials)
        #expect(chargers.map(\.id) == [serial])
        #expect(try scoped.keychain.readChargerCredentials(vendor: "nexblue") == "refresh")
        let store = HomeChargingStore(defaults: scoped.defaults, keychain: scoped.keychain)
        store.pairing = HomeChargingPairing(
            baseURL: "", chargerID: serial, chargerName: "Garage", entities: .init(), vin: "VIN",
            locationID: nil, locationAlias: "Home", timeZoneIdentifier: "Europe/Stockholm", source: .nexBlue)
        let restored = HomeChargingModel(preferences: scoped.store, database: database, dependencies: dependencies)
        defer { restored.stop(); store.eraseAll() }
        await restored.send(.start)
        #expect(transport.requests(path: root + "/chargers/NX123/cmd/start_charging").isEmpty)
        restored.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while restored.historyRevision == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(restored.link == .live)
        #expect(!restored.supportsPlans)
        #expect(restored.telemetry.status?.value == .pluggedIn)
        #expect(try scoped.keychain.readChargerCredentials(vendor: "nexblue") == "rotated")
        #expect(database.charging.recentChargingSessions(for: "VIN").first?.wallbox?.energyKwh == 5.5)
        let receipt = try #require(restored.lastNexBlueImport)
        #expect(receipt.importedAt == now)
        #expect(receipt.range.duration == 30 * 86_400)
        await restored.syncSessions()
        #expect(database.charging.recentChargingSessions(for: "VIN").count == 1)
        await restored.send(.start)
        #expect(restored.command.isPending)
        transport.route("GET", path, .json(#"{"charging_state":2,"power":7.2,"energy":0.1}"#))
        restored.refreshNow()
        let confirmationDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while restored.command.isPending, ContinuousClock.now < confirmationDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(restored.telemetry.status?.value == .charging)
        #expect(!restored.command.isPending)
        #expect(transport.requests.allSatisfy { $0.url?.host == "api.nexblue.com" })
        #expect(transport.requests(path: root + "/account/login").count == 1)
        #expect(transport.requests(path: root + "/account/refresh_token").count == 1)
        let detail = root + "/chargers/" + serial
        let schedulePath = detail + "/cmd/schedule"
        transport.route({ $0.httpMethod == "GET" && MockHomeAssistantTransport.encodedPath($0) == detail }, { _ in
            .json(#"{"role":0,"online":true,"device_operator_type":0,"place_data":{"country":"SE","tz_id":"Europe/Stockholm"}}"#)
        })
        transport.route({ $0.httpMethod == "GET" && MockHomeAssistantTransport.encodedPath($0) == schedulePath }, { [weak transport] _ in
            let put = transport?.requests(path: schedulePath).last { $0.httpMethod == "PUT" }
            let body = (try? JSONSerialization.jsonObject(with: put?.httpBody ?? Data())) as? [String: Any]
            let savedItem = body?["schedule_item"] as? [String: Any]
            let reply: [String: Any] = ["schedule_mode": 2, "charge_schedules": savedItem.map { [$0] } ?? []]
            return .init(status: 200, body: (try? JSONSerialization.data(withJSONObject: reply)) ?? Data())
        })
        transport.route("PUT", schedulePath, .json(#"{"result":0}"#))
        let timer = try await restored.previewNexBlueTimer(hours: 2)
        #expect(timer.window.duration == 7200)
        #expect(timer.schedule.timeZone.identifier == "Europe/Stockholm")
        #expect(transport.requests(path: schedulePath).allSatisfy { $0.httpMethod == "GET" })
        try await restored.saveNexBlueTimer(timer)
        #expect(transport.requests(path: schedulePath).filter { $0.httpMethod == "PUT" }.count == 1)
        let backfillStart = now.addingTimeInterval(-49 * 86_400)
        let backfillEnd = now.addingTimeInterval(-46 * 86_400)
        let earlier = Int(backfillStart.addingTimeInterval(3_600).timeIntervalSince1970)
        let outside = Int(backfillEnd.timeIntervalSince1970)
        let history = root + "/sessions/charger/" + serial
        transport.route("GET", history, .json("""
          {"data":[
            {"start_timestamp":\(earlier - 1800),"end_timestamp":\(earlier),"consumption":2.5},
            {"start_timestamp":\(outside - 1800),"end_timestamp":\(outside),"consumption":7.0}
          ]}
          """))
        let range = DateInterval(start: backfillStart, end: backfillEnd)
        await restored.syncSessions(backfill: range)
        #expect(restored.lastNexBlueImport?.range == range)
        #expect(database.charging.recentChargingSessions(for: "VIN").count == 2)
        await restored.syncSessions(backfill: range)
        #expect(database.charging.recentChargingSessions(for: "VIN").count == 2)
        transport.route("GET", history, .json("{}", status: 500))
        await restored.syncSessions(backfill: DateInterval(start: backfillStart.addingTimeInterval(-86_400), end: backfillEnd))
        #expect(restored.lastNexBlueImport?.range == range)
        #expect(HomeChargingModel(preferences: scoped.store, database: database, dependencies: dependencies).lastNexBlueImport
            == restored.lastNexBlueImport)
        let state = vehicle(vin: "VIN", battery: 50, connection: .connected, target: 80)
        var staleInput = try #require(restored.cardInput(for: state))
        staleInput.now = now.addingTimeInterval(HomeChargerTelemetry.defaultStaleAfter + 1)
        #expect(HomeChargingCardModel.make(staleInput).actions.isEmpty)
        restored.stop()
        let disconnectedInput = try #require(restored.cardInput(for: state))
        let pause = HomeChargingCardModel.make(disconnectedInput).actions.first { $0.kind == .pause }
        #expect(pause?.isEnabled == false)
        await restored.send(.pause)
        #expect(transport.requests(path: root + "/chargers/NX123/cmd/stop_charging").isEmpty)
        restored.signOutDirect()
        #expect(restored.lastNexBlueImport == nil)
        #expect(try scoped.keychain.readChargerCredentials(vendor: "nexblue") == nil)
    }
}
