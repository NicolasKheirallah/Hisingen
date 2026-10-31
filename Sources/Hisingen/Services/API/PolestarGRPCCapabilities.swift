import Foundation

struct GrpcHealthReport: Equatable, Sendable {
    let details: VehicleHealthDetails
    let daysToService: Int?
    let distanceToServiceKm: Int?
    let serviceWarning: Bool
    let engineHoursToService: Int?
    let reportedAt: Date?
}

struct GrpcOdometerReport: Equatable, Sendable {
    let odometerKm: Int?
    let odometerKmPrecise: Double?
    let manualTripKm: Double?
    let automaticTripKm: Double?
    let manualAverageSpeedKmH: Int?
    let automaticAverageSpeedKmH: Int?
    let sinceChargeTripKm: Double?
    let sinceChargeAverageSpeedKmH: Int?
    let reportedAt: Date?
}

extension PolestarGRPC {
    private static let exteriorPath = "/services.vehiclestates.exterior.ExteriorService/GetLatestExterior"
    private static let healthPath = "/services.vehiclestates.health.HealthService/GetHealth"
    private static let odometerPath = "/services.vehiclestates.odometer.OdometerService/GetOdometer"
    private static let dashboardPath = "/services.vehiclestates.dashboard.DashboardService/GetLatestDashboard"
    private static let softwarePath = "/ota_mobcache.OtaDiscoveryService/GetSoftwareInfo"
    private static let softwareSchedulePath = "/ota_mobcache.SchedulerService/GetSchedule"
    private static let globalChargeTimerPath = "/pccs.chronos.services.v2.GlobalChargeTimerService/GetGlobalChargeTimerStream"
    private static let chargeLocationsPath = "/pccs.chronos.services.v1.ChargeLocationService/GetChargeLocations"
    private static let climatePath = "/services.vehiclestates.parkingclimatization.ParkingClimatizationService/GetLatestParkingClimatization"
    private static let climateTimersPath = "/pccs.chronos.services.v1.ParkingClimateTimerService/GetTimers"
    private static let locationPath = "/dtlinternet.DtlInternetService/GetLastKnownLocation"
    private static let weatherPath = "/weather.WeatherService/GetWeatherReport"
    private static let myCarsPath = "/car_information.CarInformation/GetMyCars"

    static func validateKnownMessages(_ data: Data, paths: [[Int]]) throws {
        let fields = try Protobuf.decode(data)
        for field in fields where field.wire == 2 {
            let tails = paths.filter { $0.first == field.number }.map { Array($0.dropFirst()) }
            if !tails.isEmpty {
                try validateKnownMessages(field.data, paths: tails.filter { !$0.isEmpty })
            }
        }
    }

    static func validateResponse(_ data: Data, path: String) throws {
        let paths: [[Int]]
        if path == myCarsPath {
            paths = [[1], [1, 1]] + [34, 35, 36, 37, 39, 40, 42, 51, 74].map { [1, 1, $0] }
                + [[1, 1, 35, 8], [1, 1, 35, 9], [1, 1, 37, 6], [1, 1, 37, 13]]
        } else if path == softwarePath {
            paths = [[1], [1, 2], [1, 5], [1, 8], [1, 8, 2], [1, 10]]
        } else if path == softwareSchedulePath {
            paths = [[1], [1, 3]]
        } else if path == exteriorPath {
            paths = [[3], [3, 1], [3, 2], [3, 3], [3, 4], [3, 5]]
                + (1...8).flatMap { [[3, 2, $0], [3, 3, $0], [3, 4, $0], [3, 5, $0]] }
        } else if path == healthPath {
            paths = [[3], [3, 1], [3, 46]]
        } else if path == odometerPath {
            paths = [[3], [3, 1]]
        } else if path == climatePath {
            paths = [[3], [3, 1], [3, 14], [3, 16]]
        } else if path == globalChargeTimerPath {
            paths = [[1], [1, 1], [1, 2]]
        } else if path == chargeLocationsPath {
            paths = [[3], [3, 4], [3, 10], [3, 10, 3], [3, 10, 4], [3, 10, 5],
                     [3, 11], [3, 11, 3], [3, 11, 4]]
        } else if path == climateTimersPath {
            paths = [[3], [3, 3], [3, 6], [4], [4, 3], [4, 6], [5]]
        } else {
            paths = []
        }
        try validateKnownMessages(data, paths: paths)
    }

    func fetchExterior(vin: String, accessToken: String) async throws -> ExteriorSnapshot? {
        let generation = sessionGeneration
        let path = Self.exteriorPath
        let body = try await firstMessage(path: path, message: Self.vehicleRequest(vin),
                                           vin: vin, accessToken: accessToken)
        guard generation == sessionGeneration else { throw CancellationError() }
        guard let payload = try Self.responsePayload(body, expectedVIN: vin) else { return nil }
        let current = Self.parseExterior(payload)
        guard let current else { return exteriorCache[vin] }
        let merged = current.merging(previous: exteriorCache[vin])
        exteriorCache[vin] = merged
        return merged
    }

    func fetchHealth(vin: String, accessToken: String) async throws -> GrpcHealthReport? {
        let body = try await firstMessage(path: Self.healthPath, message: Self.healthRequest(vin),
                                          vin: vin, accessToken: accessToken, completion: .firstSnapshot)
        guard let payload = try Self.responsePayload(body, expectedVIN: vin) else { return nil }
        return Self.parseHealth(payload)
    }

    func fetchOdometer(vin: String, accessToken: String) async throws -> GrpcOdometerReport? {
        do {
            let body = try await firstMessage(path: Self.odometerPath, message: Self.healthRequest(vin),
                                              vin: vin, accessToken: accessToken, completion: .firstSnapshot)
            if let payload = try Self.responsePayload(body, expectedVIN: vin) {
                let result = Self.parseOdometer(payload)
                if result.odometerKm != nil || result.manualTripKm != nil || result.automaticTripKm != nil
                    || result.manualAverageSpeedKmH != nil || result.automaticAverageSpeedKmH != nil {
                    return result
                }
            }
            // A successful but empty Odometer response means this vehicle exposes no trip
            // fields there. Do not turn that into a guaranteed-failing Dashboard probe.
            return nil
        } catch let error as PolestarError {
            guard case .grpcUnimplemented = error else { throw error }
        }
        let body = try await firstMessage(path: Self.dashboardPath, message: Self.vehicleRequest(vin),
                                          vin: vin, accessToken: accessToken)
        guard let dashboard = Self.message(body, field: 2),
              let data = Self.message(dashboard, field: 1) else { return nil }
        return Self.parseDashboardOdometer(data)
    }

    func fetchSoftware(vin: String, accessToken: String, locale: String, requireComplete: Bool = false, requireSoftwareIdentity: Bool = false) async throws -> VehicleSoftwareInfo? {
        let generation = sessionGeneration
        let readGeneration = (softwareReadGeneration[vin] ?? 0) &+ 1
        softwareReadGeneration[vin] = readGeneration
        otaSoftwareIDs[vin] = nil
        otaSoftwareStates[vin] = nil
        otaRawSoftwareStates[vin] = nil
        var request = Data()
        request.append(Protobuf.stringField(1, vin))
        request.append(Protobuf.stringField(2, locale))
        var info: VehicleSoftwareInfo?
        var firstError: Error?
        do {
            let body = try await firstMessage(path: Self.softwarePath, message: request,
                                              vin: vin, accessToken: accessToken)
            guard generation == sessionGeneration && softwareReadGeneration[vin] == readGeneration else { throw CancellationError() }
            _ = try Protobuf.decode(body)
            if let payload = Self.message(body, field: 1), !payload.isEmpty {
                _ = try Protobuf.decode(payload)
                rememberSoftwareID(Self.string(Protobuf.fields(payload), 1), vin: vin)
                let parsed = Self.parseSoftware(payload)
                otaSoftwareStates[vin] = parsed.state
                otaRawSoftwareStates[vin] = parsed.rawState
                info = parsed
            }
        } catch {
            try Task.checkCancellation()
            guard Self.canTryAlternativeEndpoint(after: error) else { throw error }
            firstError = error
        }

        if requireSoftwareIdentity && otaSoftwareIDs[vin] == nil {
            throw RemoteCommandError.missingContext
        }

        // `Scheduler`: 1 status, 2 relative_time, 3 scheduled_time, 4 software_id, 5 set_by.
        // This is a second source of the software id – it stays populated for a scheduled
        // install even when GetSoftwareInfo has nothing to report, which is what makes
        // "cancel a scheduled installation" reachable.
        var scheduledAt: Date?
        var scheduleSetBy: ScheduleSetBy?
        // `relative_time` is minutes-until-install (the same bound `Schedule` enforces,
        // 2…10080). The backend answers -2 when nothing is scheduled, which must not be
        // surfaced as a countdown.
        var relativeMinutes: Int?
        do {
            let body = try await firstMessage(path: Self.softwareSchedulePath,
                                              message: Protobuf.stringField(1, vin),
                                              vin: vin, accessToken: accessToken)
            guard generation == sessionGeneration && softwareReadGeneration[vin] == readGeneration else { throw CancellationError() }
            _ = try Protobuf.decode(body)
            if let scheduler = Self.message(body, field: 1) {
                _ = try Protobuf.decode(scheduler)
                let fields = Protobuf.fields(scheduler)
                scheduledAt = Self.timestamp(Self.message(fields, field: 3))
                if otaSoftwareIDs[vin] == nil { rememberSoftwareID(Self.string(fields, 4), vin: vin) }
                if let rawRelative = Self.varint(fields, 2) {
                    let signed = Int(bitPattern: UInt(truncatingIfNeeded: rawRelative))
                    if signed > 0 { relativeMinutes = signed }
                }
                if let setByValue = Self.varint(fields, 5), let intValue = Int(exactly: setByValue), let setBy = ScheduleSetBy(rawValue: intValue) {
                    scheduleSetBy = setBy
                }
                if scheduledAt != nil, otaSoftwareStates[vin] == nil {
                    otaSoftwareStates[vin] = .scheduled
                }
            }
        } catch {
            try Task.checkCancellation()
            if PolestarAPI.isGlobalFailure(error) { throw error }
            if firstError == nil { firstError = error }
        }

        guard generation == sessionGeneration && softwareReadGeneration[vin] == readGeneration else { throw CancellationError() }
        if requireComplete, let firstError { throw firstError }
        if let info {
            var merged = info
            merged.scheduledAt = info.scheduledAt ?? scheduledAt
            merged.scheduleSetBy = scheduleSetBy
            merged.scheduleRelativeMinutes = relativeMinutes ?? info.scheduleRelativeMinutes
            return merged
        }
        if let scheduledAt {
            // A schedule exists but GetSoftwareInfo returned nothing, so the target version is
            // genuinely unknown here. Report the schedule and leave every version field nil
            // rather than inventing one.
            return VehicleSoftwareInfo(state: .scheduled, scheduledAt: scheduledAt,
                                       scheduleSetBy: scheduleSetBy,
                                       scheduleRelativeMinutes: relativeMinutes)
        }
        if let firstError { throw firstError }
        return VehicleSoftwareInfo(noUpdateAvailable: true)
    }

    private func rememberSoftwareID(_ id: String, vin: String) {
        guard !id.isEmpty else { return }
        otaSoftwareIDs[vin] = id
    }

    /// Reads saved charging locations from Chronos `ChargeLocationService`.
    /// `ChargeLocation` wire: `2 location_id`, `3 alias`, `4 coordinate{1 lon, 2 lat}`,
    /// `5 amp_limit`, `6 minimum_soc`, `7 optimised_charging`, `12 location_type`
    /// (1 recent / 2 saved / 3 saved third-party). Field semantics cross-checked against
    /// the independently built kildahldev/unofficial-polestar-api client.
    func fetchChargeLocations(vin: String, accessToken: String) async throws -> [ChargeLocationSnapshot] {
        Self.parseChargeLocations(try await chargeLocationsBody(vin: vin, accessToken: accessToken))
    }

    /// The token is part of the key so a waiter never receives a response fetched under another
    /// token, for example one that was refreshed or belonged to a signed-out account.
    private static func flightKey(vin: String, accessToken: String) -> String {
        "\(vin)\n\(accessToken)"
    }

    private func chargeLocationsBody(vin: String, accessToken: String) async throws -> Data {
        let key = Self.flightKey(vin: vin, accessToken: accessToken)
        let flight = SingleFlight.join(key, in: &chargeLocationsInFlight) {
            Task {
                try await self.firstMessage(path: Self.chargeLocationsPath,
                                            message: Self.chronosRequest(vin),
                                            vin: vin, accessToken: accessToken, host: .pccs)
            }
        }
        defer { SingleFlight.finish(key, flight, in: &chargeLocationsInFlight) }
        return try await flight.task.value
    }

    static func parseChargeLocations(_ data: Data) -> [ChargeLocationSnapshot] {
        Protobuf.fields(data).filter { $0.number == 3 && $0.wire == 2 }.compactMap { field in
            let f = Protobuf.fields(field.data)
            let id = string(f, 2)
            guard !id.isEmpty else { return nil }
            var latitude: Double?
            var longitude: Double?
            if let coordinate = message(f, field: 4) {
                let coords = Protobuf.fields(coordinate)
                longitude = numeric(coords, 1)
                latitude = numeric(coords, 2)
            }
            return ChargeLocationSnapshot(
                id: id,
                alias: string(f, 3),
                latitude: latitude,
                longitude: longitude,
                ampLimit: varint(f, 5).flatMap(Int.init(exactly:)) ?? 0,
                minimumSoc: varint(f, 6).flatMap(Int.init(exactly:)) ?? 0,
                optimisedChargingEnabled: (varint(f, 7) ?? 0) == 1,
                optimisedChargingMode: varint(f, 9).flatMap(Int.init(exactly:)) ?? 0,
                kind: varint(f, 12).flatMap(Int.init(exactly:)) ?? 0
            )
        }
    }

    func fetchChargingSchedules(vin: String, accessToken: String) async throws -> [VehicleSchedule] {        var schedules: [VehicleSchedule] = []
        var errors: [Error] = []
        do {
            let body = try await firstMessage(path: Self.globalChargeTimerPath,
                                              message: Self.chronosRequest(vin),
                                              vin: vin, accessToken: accessToken, host: .pccs,
                                              completion: .firstSnapshot)
            if let timer = Self.message(body, field: 1), let parsed = Self.parseGlobalChargeTimer(timer) {
                schedules.append(parsed)
            }
        } catch {
            try Task.checkCancellation()
            if PolestarAPI.isGlobalFailure(error) { throw error }
            errors.append(error)
        }
        do {
            let body = try await chargeLocationsBody(vin: vin, accessToken: accessToken)
            schedules.append(contentsOf: Self.parseChargeLocationSchedules(body))
        } catch {
            try Task.checkCancellation()
            if PolestarAPI.isGlobalFailure(error) { throw error }
            errors.append(error)
        }


        if schedules.isEmpty, errors.count == 2 {
            let hasInfrastructureError = errors.contains { error in
                if let polestarError = error as? PolestarError {
                    switch polestarError {
                    case .authenticationRequired, .network, .server, .rateLimited:
                        return true
                    default:
                        return false
                    }
                }
                return error is URLError
            }
            if hasInfrastructureError { throw errors[0] }
        }
        return schedules
    }

    /// Fetches vehicle information from `car_information.CarInformation/GetMyCars` (C3 gRPC).
    /// Returns backend-authoritative capability flags and the **actually installed** software
    /// version (`consumerSoftwareVersion`) – which `GetSoftwareInfo` does not provide during
    /// a rollout.
    func fetchMyCars(vin: String, accessToken: String) async throws -> VehicleOTACapabilities? {
        let generation = sessionGeneration
        let body = try await myCarsBody(vin: vin, accessToken: accessToken)
        guard generation == sessionGeneration else { throw CancellationError() }
        let capabilities = Self.parseMyCars(body, vin: vin)
        // Cache the backend-reported charging bounds so command validation can use the same
        // limits the vehicle itself advertises instead of hardcoded fallbacks.
        capabilityLimits[vin] = capabilities
        return capabilities
    }

    /// Single-flight for the capability document. One sweep resolves it from more than one
    /// consumer, and each miss was a separate `GetMyCars` round trip – two recorded failures
    /// per launch in the diagnostic log where one explained the other.
    func myCarsBody(vin: String, accessToken: String) async throws -> Data {
        let key = Self.flightKey(vin: vin, accessToken: accessToken)
        let flight = SingleFlight.join(key, in: &myCarsInFlight) {
            Task {
                try await self.firstMessage(path: Self.myCarsPath,
                                            message: Self.myCarsRequest(vin: vin),
                                            vin: vin, accessToken: accessToken)
            }
        }
        defer { SingleFlight.finish(key, flight, in: &myCarsInFlight) }
        return try await flight.task.value
    }

    func fetchClimate(vin: String, accessToken: String) async throws -> VehicleClimateStatus? {
        let body = try await firstMessage(path: Self.climatePath, message: Self.vehicleRequest(vin),
                                          vin: vin, accessToken: accessToken)
        guard let payload = try Self.responsePayload(body, expectedVIN: vin) else { return nil }
        return Self.parseClimate(payload)
    }

    func fetchClimateTimers(vin: String, accessToken: String) async throws -> [VehicleSchedule] {
        let body = try await firstMessage(path: Self.climateTimersPath,
                                          message: Self.chronosRequest(vin),
                                          vin: vin, accessToken: accessToken, host: .pccs)
        return Self.parseClimateTimers(body)
    }


    func fetchConnectivity(vin: String, accessToken: String) async throws -> VehicleConnectivity? {
        let body = try await firstMessage(path: Self.dashboardPath, message: Self.vehicleRequest(vin),
                                          vin: vin, accessToken: accessToken)
        guard let payload = try Self.responsePayload(body, expectedVIN: vin) else { return nil }
        let fields = Protobuf.fields(payload)
        let status: ConnectivityState
        switch Self.varint(fields, 1) {
        case 1: status = .unavailable
        case 2: status = .disconnected
        case 3: status = .connected
        default: status = .unknown
        }
        let network = [1: "Unknown", 2: "CDMA 1X", 3: "CDMA EVDO", 4: "WCDMA", 5: "GSM", 6: "LTE", 7: "5G"]
        let signal = [1: "Unknown", 2: "Poor", 3: "Good", 4: "Strong"]
        let signalRaw = Self.varint(fields, 4)
        let bars: Int? = signalRaw.flatMap {
            switch $0 {
            case 2: return 1
            case 3: return 3
            case 4: return 4
            default: return nil
            }
        }
        let wake = Self.varint(fields, 6).flatMap { val -> String? in
            switch val {
            case 1: return L10n.text("Scheduled Climate")
            case 2: return L10n.text("Charging Active")
            case 3: return L10n.text("Telemetry Poll")
            default: return nil
            }
        }
        return VehicleConnectivity(
            state: status,
            networkType: Self.positiveInt(Self.varint(fields, 3)).flatMap { network[$0] },
            signalStrength: Self.positiveInt(signalRaw).flatMap { signal[$0] },
            updatedAt: Self.timestamp(Self.message(fields, field: 2)),
            signalBars: bars,
            wakeReason: wake
        )
    }

    /// Read paths probed in order. `GetPreCleaning` is the verified production spelling; the
    /// alternates follow the same `services.vehiclestates.<domain>` naming pattern every other
    /// C3 state service uses (`GetLatest*` one-shot + streaming `Get*`), so if Polestar renames
    /// or promotes the service the app degrades gracefully instead of losing the card.
    static let airQualityPaths: [(String, GRPCHost)] = [
        ("/services.vehiclestates.precleaning.PreCleaningService/GetPreCleaning", .c3),
        ("/services.vehiclestates.precleaning.PreCleaningService/GetLatestPreCleaning", .c3),
        ("/services.vehiclestates.airquality.AirQualityService/GetLatestAirQuality", .c3),
        ("/services.vehiclestates.airquality.AirQualityService/GetAirQuality", .c3)
    ]

    func fetchAirQuality(vin: String, accessToken: String) async throws -> VehicleAirQuality? {
        var firstError: Error?
        for (path, host) in Self.airQualityPaths {
            do {
                let body = try await firstMessage(path: path, message: Self.healthRequest(vin),
                                                  vin: vin, accessToken: accessToken, host: host,
                                                  completion: path == Self.airQualityPaths[0].0 ? .firstSnapshot : .terminalStatus)
                // The payload sits at field 3 on the verified response shape; probe the usual
                // wrapper fields too so an alternate spelling still decodes.
                let candidates = [
                    Self.message(body, field: 3),
                    Self.message(body, field: 1),
                    body
                ].compactMap { $0 }
                for candidate in candidates {
                    if let parsed = Self.parseAirQuality(candidate) { return parsed }
                }
            } catch {
                try Task.checkCancellation()
                guard Self.canTryAlternativeEndpoint(after: error) else { throw error }
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        return nil
    }

    /// Parses a C3 `PreCleaningInfo` payload:
    /// `1 timestamp`, `4 started_at`, `5 ending_at`, `6 running_status`,
    /// `7 start_reason`, `8 last_cycle_valid`, `9 measured_air_quality_index`,
    /// `10 measured_particulate_matter_2_5`, `11 runtime_left_minutes`,
    /// `13 error` (0 none / 1 generic / 2 interrupted), plus live-observed
    /// `14 particulate_matter_10`, `15 external_particulate_matter_2_5`,
    /// `16 filter_remaining_percent`.
    ///
    /// Field semantics for 1/4/5/6/7/8/13 cross-checked against the independently built
    /// `kildahldev/unofficial-polestar-api` proto schema; 14–16 were observed live by Hisingen.
    static func parseAirQuality(_ data: Data) -> VehicleAirQuality? {
        let fields = Protobuf.fields(data)
        let state: AirCleaningState
        switch varint(fields, 6) {
        case 1: state = .on
        case 2: state = .off
        case 3: state = .pending
        default: state = .unknown
        }
        let errorRaw = varint(fields, 13).flatMap(Int.init(exactly:)) ?? 0
        let errorKind = AirCleaningError(rawValue: errorRaw) ?? (errorRaw > 0 ? .generic : nil)
        let hasAnyValue = [9, 10, 11, 14, 15, 16].contains { varint(fields, $0) != nil }
            || varint(fields, 6) != nil
        guard hasAnyValue else { return nil }
        // Same posture as the climate parser: a field the decode did not consume stays
        // visible as raw wire data instead of disappearing. Field 3 is classified (it
        // duplicates field 1), so it is not unknown; a running status outside 1…3 or an
        // error ordinal outside the decoded 0…5 is.
        let decodedAirQualityFields: Set<Int> = [1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 14, 15, 16]
        let unknownWireFields = fields.filter { field in
            if field.number == 6 {
                return field.wire != 0 || !(1...3).contains(field.varint)
            }
            if field.number == 13 {
                switch field.wire {
                case 0: return !(0...5).contains(field.varint)
                case 2:
                    let values = Protobuf.packedVarints(field.data) ?? []
                    return values.isEmpty || !values.allSatisfy { (0...5).contains($0) }
                default: return true
                }
            }
            return !decodedAirQualityFields.contains(field.number)
        }.map(PolestarGRPC.rawField)
        return VehicleAirQuality(
            cleaningState: state,
            airQualityIndex: positiveInt(varint(fields, 9)),
            particulateMatter25: positiveInt(varint(fields, 10)),
            particulateMatter10: positiveInt(varint(fields, 14)),
            externalParticulateMatter25: positiveInt(varint(fields, 15)),
            filterRemainingPercent: positiveInt(varint(fields, 16)),
            runtimeRemainingMinutes: positiveInt(varint(fields, 11)),
            hasError: errorKind == .generic || errorKind == .interrupted,
            reportedAt: timestamp(message(fields, field: 1)),
            startedAt: timestamp(message(fields, field: 4)),
            endingAt: timestamp(message(fields, field: 5)),
            startReason: varint(fields, 7).flatMap(Int.init(exactly:)).flatMap(VehicleStartReason.init(rawValue:)),
            lastCycleValid: varint(fields, 8).map { $0 != 0 },
            errorKind: errorKind,
            // Field 2 verified live: it advances on vehicle wakes and at cycle end, i.e. the
            // last time the cabin air was actually measured (distinct from field 1, the
            // frame report time). Field 3 duplicates field 1 and stays ignored.
            measuredAt: timestamp(message(fields, field: 2)),
            unknownWireFields: unknownWireFields.isEmpty ? nil : unknownWireFields
        )
    }


    func fetchLocation(vin: String, accessToken: String) async throws -> VehicleLocation? {
        let key = Self.flightKey(vin: vin, accessToken: accessToken)
        let flight = SingleFlight.join(key, in: &locationInFlight) {
            Task { try await self.fetchLocationUncached(vin: vin, accessToken: accessToken) }
        }
        defer { SingleFlight.finish(key, flight, in: &locationInFlight) }
        return try await flight.task.value
    }

    private func fetchLocationUncached(vin: String, accessToken: String) async throws -> VehicleLocation? {
        let paths: [(String, GRPCHost)] = [
            (Self.locationPath, .c3),
            ("/services.vehiclestates.location.LocationService/GetLatestLocation", .c3),
            ("/dtlinternet.DtlInternetService/GetLocation", .c3),
            ("/pccs.chronos.services.v1.LocationService/GetLocation", .pccs),
            ("/services.vehiclestates.location.LocationService/GetLocation", .c3)
        ]

        let message = Protobuf.stringField(1, vin)
        for (path, host) in paths {
            do {
                let body = try await firstMessage(path: path,
                                                  message: message,
                                                  vin: vin, accessToken: accessToken, host: host)

                if let location = Self.parseLocation(body) { return location }
            } catch {
                try Task.checkCancellation()
                guard Self.canTryAlternativeEndpoint(after: error) else { throw error }
            }
        }
        return nil
    }


    func fetchWeather(vin: String, accessToken: String) async throws -> VehicleWeather? {
        if let location = try await fetchLocation(vin: vin, accessToken: accessToken),
           let lat = location.latitude, let lon = location.longitude,
           lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) {
            if let weather = await OpenMeteoWeatherClient(session: session, diagnosticLog: diagnosticLog)
                .weatherWithForecast(latitude: lat, longitude: lon) {
                return weather
            }
        }

        let weatherPaths: [(String, GRPCHost)] = [
            (Self.weatherPath, .c3),
            ("/services.vehiclestates.weather.WeatherService/GetLatestWeather", .c3),
            ("/weather.WeatherService/GetWeatherReport", .pccs)
        ]

        let message = Protobuf.stringField(1, vin)
        for (path, host) in weatherPaths {
            do {
                let body = try await firstMessage(path: path,
                                                  message: message,
                                                  vin: vin, accessToken: accessToken, host: host)
                if let weather = Self.parseWeather(body) { return weather }
            } catch {
                try Task.checkCancellation()
                guard Self.canTryAlternativeEndpoint(after: error) else { throw error }
            }
        }
        return nil
    }

    static func parseExterior(_ data: Data) -> ExteriorSnapshot? {
        let paths = [[1], [2], [3], [4], [5], [6], [7]]
            + (1...4).flatMap { [[2, $0], [3, $0]] } + [[5, 1], [6, 1]]
        guard (try? validateKnownMessages(data, paths: paths)) != nil,
              let fields = try? Protobuf.decode(data) else { return nil }
        let isDigitalTwin = fields.contains { (2...16).contains($0.number) && $0.wire == 0 }
        var readings: [OpeningReading] = []
        var locked: Bool?
        var alarm: Bool?
        // `Exterior.tailgate_lock` (field 16) is an independent LockStatus in the upstream
        // schema – it says whether the tailgate itself is locked, which is not derivable
        // from field 12 (whether the tailgate is open) and must not be inferred from it.
        var tailgateLocked: Bool?
        var reportedAt: Date?
        if isDigitalTwin {
            if let value = varint(fields, 15) {
                alarm = value == 2 ? true : (value == 1 ? false : nil)
            }
            if let value = varint(fields, 2) { locked = value == 2 ? true : (value == 1 ? false : nil) }
            if let value = varint(fields, 16) { tailgateLocked = value == 2 ? true : (value == 1 ? false : nil) }
            // Only the digital-twin shape has `Timestamp timestamp = 1`; in the legacy
            // shape field 1 is the central-lock message, so reading it as a timestamp
            // there would fabricate a bogus reading time.
            reportedAt = timestamp(message(fields, field: 1))
            let mapping: [(Int, VehicleOpening)] = [
                (3, .frontLeftDoor), (4, .frontRightDoor), (5, .rearLeftDoor), (6, .rearRightDoor),
                (7, .frontLeftWindow), (8, .frontRightWindow), (9, .rearLeftWindow), (10, .rearRightWindow),
                (11, .hood), (12, .tailgate), (13, .chargeLid), (14, .sunroof)
            ]
            readings = mapping.compactMap { field, opening in
                varint(fields, field).map { OpeningReading(opening: opening, state: openState($0)) }
            }
        } else {
            if let central = message(fields, field: 1), let value = varint(Protobuf.fields(central), 1) {
                locked = value == 2 ? true : (value == 1 ? false : nil)
            }
            if let doors = message(fields, field: 2) {
                let doorFields = Protobuf.fields(doors)
                let positions: [VehicleOpening] = [.frontLeftDoor, .frontRightDoor, .rearLeftDoor, .rearRightDoor]
                for (index, opening) in positions.enumerated() {
                    guard let status = message(doorFields, field: index + 1) else { continue }
                    let values = Protobuf.fields(status)
                    if let value = varint(values, 2) {
                        readings.append(OpeningReading(opening: opening, state: openState(value)))
                    }
                    if varint(values, 3) == 1 { alarm = true }
                }
            }
            if let windows = message(fields, field: 3) {
                let windowFields = Protobuf.fields(windows)
                let positions: [VehicleOpening] = [.frontLeftWindow, .frontRightWindow, .rearLeftWindow, .rearRightWindow]
                for (index, opening) in positions.enumerated() {
                    guard let status = message(windowFields, field: index + 1),
                          let value = varint(Protobuf.fields(status), 1) else { continue }
                    readings.append(OpeningReading(opening: opening, state: openState(value)))
                }
            }
            let nested: [(Int, VehicleOpening)] = [(4, .sunroof), (5, .hood), (6, .tailgate), (7, .chargeLid)]
            for (field, opening) in nested {
                guard let wrapper = message(fields, field: field) else { continue }
                var statusFields = Protobuf.fields(wrapper)
                if (field == 5 || field == 6), let status = message(statusFields, field: 1) {
                    statusFields = Protobuf.fields(status)
                }
                if let value = varint(statusFields, field == 4 || field == 7 ? 1 : 2) {
                    readings.append(OpeningReading(opening: opening, state: openState(value)))
                }
                if (field == 5 || field == 6), varint(statusFields, 3) == 1 { alarm = true }
            }
        }
        guard !readings.isEmpty || locked != nil || alarm != nil || tailgateLocked != nil else { return nil }
        return ExteriorSnapshot(openings: readings, isLocked: locked, alarmTriggered: alarm,
                                isTailgateLocked: tailgateLocked,
                                reportedAt: reportedAt)
    }

    static func parseHealth(_ data: Data) -> GrpcHealthReport {
        let fields = Protobuf.fields(data)
        let warningFields = [9, 10, 11, 12]
        // Polestar 5.11.1 Health: individual kPa readings are fields 39–42.
        // Reference pressures at 43/44 and nested statuses must never become wheel readings.
        // They are the car's target for the axle, kept separate so "38 psi" can be read
        // against "42 psi" instead of standing alone.
        let pressureFields = [39, 40, 41, 42]
        let frontReference = positive(numeric(fields, 43))
        let rearReference = positive(numeric(fields, 44))
        let positions = TyrePosition.allCases
        var tyres: [TyrePressure] = []
        for index in positions.indices {
            let warningRaw = varint(fields, warningFields[index])
            let warning: TyrePressureWarning
            if let warningRaw {
                warning = tyreWarning(warningRaw) ?? .unknown
            } else {
                warning = .unknown
            }
            let pressure = numeric(fields, pressureFields[index]).flatMap {
                $0.isFinite && $0 > 0 ? $0 : nil
            }
            let reference = index < 2 ? frontReference : rearReference
            tyres.append(TyrePressure(
                position: positions[index],
                kilopascals: pressure,
                warning: warning,
                referenceKilopascals: reference
            ))
        }
        var warnings: [VehicleWarning] = []
        var reportedWarnings: [VehicleWarning] = []
        if let value = varint(fields, 5), value > 1 { warnings.append(.service) }
        let warningFieldsByType: [(Int, VehicleWarning)] = [
            (6, .brakeFluid), (7, .engineCoolant), (8, .oil), (13, .washerFluid)
        ]
        for (field, warning) in warningFieldsByType {
            if let value = varint(fields, field) {
                reportedWarnings.append(warning)
                if value > 1 { warnings.append(warning) }
            }
        }
        var lightFailures: [String] = []
        let lightDescriptions: [Int: String] = [
            14: L10n.text("Left brake light"),
            15: L10n.text("Center brake light"),
            16: L10n.text("Right brake light"),
            17: L10n.text("Front fog light"),
            18: L10n.text("Rear fog light"),
            19: L10n.text("Front-left position light"),
            20: L10n.text("Front-right position light"),
            21: L10n.text("Rear-left position light"),
            22: L10n.text("Rear-right position light"),
            23: L10n.text("Left high beam"),
            24: L10n.text("Right high beam"),
            25: L10n.text("Left low beam"),
            26: L10n.text("Right low beam"),
            27: L10n.text("Left daytime running light"),
            28: L10n.text("Right daytime running light"),
            30: L10n.text("Left front indicator"),
            31: L10n.text("Right front indicator"),
            32: L10n.text("Left rear indicator"),
            33: L10n.text("Right rear indicator"),
            34: L10n.text("License plate light"),
            35: L10n.text("Side marker light")
        ]
        for fieldNum in 14...35 {
            if varint(fields, fieldNum) == 2, let desc = lightDescriptions[fieldNum] {
                lightFailures.append(desc)
            }
        }
        let nestedLights = message(fields, field: 46).map(Protobuf.fields) ?? []
        for field in nestedLights where field.wire == 0 && field.varint == 2 {
            if let name = VehicleLightCoverage.healthName(field.number), !lightFailures.contains(name) {
                lightFailures.append(name)
            }
        }
        if (14...35).contains(where: { varint(fields, $0) != nil })
            || nestedLights.contains(where: { $0.wire == 0 && VehicleLightCoverage.healthName($0.number) != nil && (1...2).contains($0.varint) }) {
            reportedWarnings.append(.exteriorLight)
            if !lightFailures.isEmpty || (14...35).contains(where: { varint(fields, $0) == 2 }) {
                warnings.append(.exteriorLight)
            }
        }
        if let lowVoltage = varint(fields, 38) {
            reportedWarnings.append(.lowVoltageBattery)
            if lowVoltage == 2 { warnings.append(.lowVoltageBattery) }
        }
        // Tyre pressure warnings live on `tyres[].warning`, not a dedicated proto field, so they
        // must be folded into `warnings` explicitly – otherwise `Notifier.warningLabels` (which
        // only reads `healthDetails.warnings`) never sees a flagged tyre and no notification
        // fires even though the UI already shows it under "Needs Attention."
        if tyres.contains(where: { $0.warning != .unknown }) {
            reportedWarnings.append(.tyrePressure)
            if tyres.contains(where: { $0.warning.needsAttention }) { warnings.append(.tyrePressure) }
        }
        return GrpcHealthReport(
            details: VehicleHealthDetails(
                tyres: tyres,
                warnings: warnings,
                reportedWarnings: reportedWarnings,
                lightFailures: lightFailures
            ),
            daysToService: positiveInt(varint(fields, 3)),
            distanceToServiceKm: positiveInt(varint(fields, 4)),
            serviceWarning: warnings.contains(.service),
            // Field 2 is `engine_hours_to_service` in the upstream Health schema. The
            // ServiceWarning enum includes ENGINE_HOURS_* triggers, so this is a real
            // service-interval input even on a battery-electric vehicle.
            engineHoursToService: positiveInt(varint(fields, 2)),
            reportedAt: timestamp(message(fields, field: 1))
        )
    }

    static func parseOdometer(_ data: Data) -> GrpcOdometerReport {
        let fields = Protobuf.fields(data)
        // Field 2 is metres. Keep the fraction for the precise odometer and the integer
        // kilometre for the existing, coarser surfaces.
        let odometerMetres = positiveInt(varint(fields, 2))
        return GrpcOdometerReport(
            odometerKm: odometerMetres.map { $0 / 1_000 },
            odometerKmPrecise: odometerMetres.map { Double($0) / 1_000 },
            manualTripKm: positive(numeric(fields, 3)),
            automaticTripKm: positive(numeric(fields, 4)),
            manualAverageSpeedKmH: positiveInt(varint(fields, 5)),
            automaticAverageSpeedKmH: positiveInt(varint(fields, 6)),
            // Since-charge trip and average speed. Absent on cars that do not report them;
            // never synthesize a zero.
            sinceChargeTripKm: positive(numeric(fields, 7)),
            sinceChargeAverageSpeedKmH: positiveInt(varint(fields, 8)),
            reportedAt: timestamp(message(fields, field: 1))
        )
    }

    static func parseDashboardOdometer(_ data: Data) -> GrpcOdometerReport {
        let fields = Protobuf.fields(data)
        return GrpcOdometerReport(
            odometerKm: positive(numeric(fields, 17)).flatMap { Int(exactly: $0.rounded()) },
            odometerKmPrecise: positive(numeric(fields, 17)),
            manualTripKm: positive(numeric(fields, 18)),
            automaticTripKm: positive(numeric(fields, 19)),
            manualAverageSpeedKmH: nil,
            automaticAverageSpeedKmH: nil,
            sinceChargeTripKm: nil,
            sinceChargeAverageSpeedKmH: nil,
            reportedAt: nil
        )
    }


    /// Parses an `ota_mobcache` `CarSoftwareInfo`:
    /// `1 software_id`, `2 description{1 name, 2 short, 3 long}`, `3 qb_code`, `4 state`,
    /// `5 install_info{1 estimated_duration_seconds}`, `6 new_sw_version`,
    /// `8 schedule_info{2 scheduled_at}`, `10 state_timestamp{1 seconds}`, `11 originator`.
    ///
    /// Field 5 is a nested message (not a scalar varint) – confirmed by
    /// `testDecodeGetSoftwareInfoRecursively`: `f5: msg(3){f1: varint=5400}`.
    static func parseSoftware(_ data: Data) -> VehicleSoftwareInfo {
        let fields = Protobuf.fields(data)
        let description = message(fields, field: 2).map(Protobuf.fields)
        let rawStateValue = varint(fields, 4) ?? 0
        let rawState = Int(exactly: rawStateValue).flatMap { SoftwareStateRaw(rawValue: $0) } ?? .unknown
        let state = rawState.coarseState
        let schedule = message(fields, field: 8).flatMap { message($0, field: 2) }
        let advertisedVersion = string(fields, 6).nilIfEmpty
        let parsedTitle = description.flatMap { string($0, 1).nilIfEmpty } ?? advertisedVersion

        // Field 5 is a nested message: `{1: estimated_install_duration_seconds}`.
        let installDuration = message(fields, field: 5)
            .flatMap { Protobuf.fields($0).first(where: { $0.number == 1 })?.varint }
            .flatMap { Int(exactly: $0) }

        // `new_sw_version` is the only version string the backend returns, and its meaning
        // depends on `state`: while an update is pending it is the *target* version, and the
        // running version is not reported at all. Only in the settled states does it describe
        // what is actually on the car. Anything not settled leaves `installedVersion` nil –
        // `VehicleState.merged` carries the last settled reading forward so the UI can still
        // show "installed → available" during a rollout.
        let describesInstalled: Bool
        switch state {
        case .unknown, .completed:
            describesInstalled = true
        case .available, .downloading, .downloaded, .installing, .scheduled, .deferred, .failed:
            describesInstalled = false
        }

        return VehicleSoftwareInfo(
            version: advertisedVersion,
            title: parsedTitle,
            state: state,
            rawState: rawState,
            estimatedInstallDurationSeconds: installDuration,
            scheduledAt: timestamp(schedule),
            updatedAt: timestamp(message(fields, field: 10)),
            installedVersion: describesInstalled ? advertisedVersion : nil,
            latestAvailableVersion: describesInstalled ? nil : advertisedVersion,
            qbCode: string(fields, 3).nilIfEmpty,
            originator: string(fields, 11).nilIfEmpty,
            shortDescription: description.flatMap { string($0, 2).nilIfEmpty },
            longDescription: description.flatMap { string($0, 3).nilIfEmpty }
        )
    }

    /// Parses a `GetMyCarsResponse`: `{1: [MyCar]}` where `MyCar` = `{1: Car, 2: userIsLinked,
    /// 3: userIsOwner, 4: registrationPlate}`. Extracts the `Car` matching the VIN and reads
    /// the OTA + capability fields. The `Car` proto uses nested capability messages:
    /// `36: Locks{1: lockType, 2: unlockType, 5: supportsWindowControl, 6: supportsSunroofControl,
    ///  7: supportsTrunkControl, 10: supportsTrunkUnlock}`, `35: Charging{1: supportsChargingFunctions,
    ///  9: amperageLimitSettings, 8: targetChargeLevelSettings, 10: chargeTimerType,
    ///  13/16/17/18: per-location limits, 15: supportsChargeNow, 20: plugAndChargePcid,
    ///  29: supportsPlugAndCharge}`, `34: AirPurification{1: supportsRemoteStart}`,
    /// `37: ParkingClimatization{1: type, 3: maxRuntime}`, `16: honkFlashType (enum)`.
    static func myCarsRequest(vin: String) -> Data {
        vehicleRequest(vin)
    }

    /// Wire fields on the `GetMyCars` Car message whose meaning Hisingen has decoded. Any
    /// field number outside this set (and the nested sets below) is preserved raw in
    /// `VehicleOTACapabilities.unknownWireFields` so the richest raw surface the backend
    /// offers loses nothing silently – mirroring the battery parser's unknown-field capture.
    static let decodedCarFields: Set<Int> = [
        1, 2, 5, 6, 7, 9, 10, 16, 17, 20, 22, 26, 27, 29, 32, 33, 34, 35, 36, 37, 38, 39,
        40, 42, 43, 44, 46, 47, 50, 51, 53, 55, 57, 62, 63, 68, 70, 73, 74, 79, 87
    ]

    /// Known sub-message field numbers by parent wire field. Parent numbers must all appear
    /// in `decodedCarFields`.
    static let decodedNestedCarFields: [Int: Set<Int>] = [
        34: [1, 2, 3, 7, 8],                              // AirPurification
        35: [1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 13, 15, 16, 17, 18, 20, 27, 29, 36, 40, 41],   // Charging
        36: [1, 2, 5, 6, 7, 10],                         // Locks
        37: [1, 2, 3, 6, 8, 9, 10, 12, 13],              // ParkingClimatization capabilities
        38: [1, 2],                                      // AccountLinking
        39: [1, 3],                                      // DigitalKey
        40: [1, 5, 6],                                   // Propulsion
        42: [6],                                         // Infotainment
        63: [1, 2, 3],                                   // Trips
        74: [6]                                          // RestrictedSoftware
    ]

    /// Collects every undecoded field on the Car message, top-level and nested, as raw wire
    /// records. Nested fields carry their parent number so diagnostics can show `35.5`.
    static func unknownCapabilityFields(_ car: [Protobuf.Field]) -> [VehicleRawWireField] {
        var unknowns: [VehicleRawWireField] = []
        func retain(_ fields: [Protobuf.Field], parent: Int?, known: Set<Int>) {
            for field in fields where !known.contains(field.number) {
                var raw = PolestarGRPC.rawField(field)
                raw.subfield = parent
                unknowns.append(raw)
            }
        }
        retain(car, parent: nil, known: decodedCarFields)
        for (parent, known) in decodedNestedCarFields.sorted(by: { $0.key < $1.key }) {
            if let nested = message(car, field: parent) {
                retain(Protobuf.fields(nested), parent: parent, known: known)
            }
        }
        return unknowns.sorted { ($0.subfield ?? 0, $0.field) < ($1.subfield ?? 0, $1.field) }
    }

    static func parseMyCars(_ data: Data, vin: String) -> VehicleOTACapabilities? {
        guard (try? validateResponse(data, path: myCarsPath)) != nil else { return nil }
        let outer = Protobuf.fields(data)
        for myCarField in outer where myCarField.number == 1 && myCarField.wire == 2 {
            let myCar = Protobuf.fields(myCarField.data)
            guard let carData = myCar.first(where: { $0.number == 1 && $0.wire == 2 })?.data else { continue }
            let car = Protobuf.fields(carData)
            let carVin = string(car, 1)
            guard carVin.uppercased() == vin.uppercased() else { continue }

            // Direct fields on Car
            let installedVersion = string(car, 9).nilIfEmpty
            let supportsUpdateStatus = varint(car, 32) == 1
            let supportsRemoteOtaInstallSchedule = varint(car, 33) == 1
            let supportsFullOtaUpdates = varint(car, 57) == 1
            let supportsCloudBasedOtaDownloadConsent = varint(car, 62) == 1
            let hasPerformanceSoftwareUpgrade = varint(car, 70) == 1
            let honkFlashMode = varint(car, 16).flatMap(Int.init(exactly:)).flatMap(VehicleHonkFlashMode.init(rawValue:))
            let supportsHonkAndFlash = honkFlashMode?.permits(.honkAndFlash) == true
            let supportsFlash = honkFlashMode?.permits(.flashLights) == true

            // Nested Locks message (field 36)
            let locksData = message(car, field: 36).map(Protobuf.fields)
            let climate = message(car, field: 37).map(Protobuf.fields)
            // 36.2 RemoteUnlockType and 36.7/10 trunk booleans answer different questions: a car
            // whose unlock type is TRUNK_ONLY still unlocks the tailgate, but not the doors.
            let unlockType = intValue(locksData, 2).flatMap(RemoteUnlockType.init(rawValue:))
            let supportsWindowsControl = locksData?.first(where: { $0.number == 5 })?.varint == 1
            let supportsTrunkControl = locksData?.first(where: { $0.number == 7 })?.varint == 1
            let supportsTrunkUnlock = locksData?.first(where: { $0.number == 10 })?.varint == 1
            // Sunroof remote control (field 6) – captured as tri-state: nil when the field
            // is absent so older vehicles don't read as "unsupported".
            let supportsSunroofControl: Bool? = locksData?.first(where: { $0.number == 6 })
                .map { $0.varint == 1 }

            // Nested Charging message (field 35)
            let chargingData = message(car, field: 35).map(Protobuf.fields)
            let supportsChargingFunctions = chargingData?.first(where: { $0.number == 1 })?.varint == 1
            // Newer app schemas changed these two fields from booleans to settings
            // messages. The nested messages carry the limits while older vehicles still
            // return a scalar `true`; accept both wire shapes.
            let amperageSettings = message(chargingData ?? [], field: 9).map(Protobuf.fields)
            let targetSettings = message(chargingData ?? [], field: 8).map(Protobuf.fields)
            let supportsGlobalChargeAmperageLimit = amperageSettings.map { varint($0, 1) == 1 } == true
                || chargingData?.first(where: { $0.number == 9 && $0.wire == 0 })?.varint == 1
            let supportsTargetChargeLevel = targetSettings.map { varint($0, 1) == 1 } == true
                || chargingData?.first(where: { $0.number == 8 && $0.wire == 0 })?.varint == 1
            let supportsChargeNowTimerOverride = chargingData?.first(where: { $0.number == 15 })?.varint == 1
            let supportsPlugAndCharge = chargingData?.first(where: { $0.number == 29 })?.varint == 1
            let plugAndChargePcid = string(chargingData ?? [], 20).nilIfEmpty

            // Polestar 5.11.1 generated settings schemas: field 1 is the support flag.
            // Field numbers are repo-internal; docs/research/POLESTAR_FIELDS.md records what the
            // live frame corroborates and what stays unverified.
            let chargeAmperageMinLimit = plausibleLimit(
                amperageSettings, field: 3, range: 2...64
            )
            let advertisedAmpMaximum = plausibleLimit(
                amperageSettings, field: 4, range: 2...64
            )
            let chargeAmperageMaxLimit = advertisedAmpMaximum >= chargeAmperageMinLimit
                ? advertisedAmpMaximum : 0
            let targetChargeLevelPercentageMinLimit = plausibleLimit(
                targetSettings, field: 2, range: 20...100
            )

            // Nested AirPurification message (field 34)
            let airData = message(car, field: 34).map(Protobuf.fields)
            let supportsAirPurificationRemoteStart = airData?.first(where: { $0.number == 1 })?.varint == 1

            var capabilities = VehicleOTACapabilities(
                installedSoftwareVersion: installedVersion,
                identity: VehicleBackendIdentity(modelName: string(car, 6).nilIfEmpty,
                                                 modelYear: string(car, 7).nilIfEmpty,
                                                 market: string(car, 10).nilIfEmpty),
                supportsFullOtaUpdates: supportsFullOtaUpdates,
                supportsRemoteOtaInstallSchedule: supportsRemoteOtaInstallSchedule,
                supportsCloudBasedOtaDownloadConsent: supportsCloudBasedOtaDownloadConsent,
                supportsUpdateStatus: supportsUpdateStatus,
                hasPerformanceSoftwareUpgrade: hasPerformanceSoftwareUpgrade,
                supportsTrunkControl: supportsTrunkControl,
                supportsTrunkUnlock: supportsTrunkUnlock || unlockType == .trunkOnly,
                supportsHonkAndFlash: supportsHonkAndFlash,
                supportsFlash: supportsFlash,
                supportsChargingFunctions: supportsChargingFunctions,
                supportsGlobalChargeAmperageLimit: supportsGlobalChargeAmperageLimit,
                supportsTargetChargeLevel: supportsTargetChargeLevel,
                supportsChargeNowTimerOverride: supportsChargeNowTimerOverride,
                chargeAmperageMinLimit: chargeAmperageMinLimit,
                chargeAmperageMaxLimit: chargeAmperageMaxLimit,
                targetChargeLevelPercentageMinLimit: targetChargeLevelPercentageMinLimit,
                supportsWindowsControl: supportsWindowsControl,
                supportsAirPurificationRemoteStart: supportsAirPurificationRemoteStart,
                supportsPlugAndCharge: supportsPlugAndCharge,
                plugAndChargeIdentifier: plugAndChargePcid,
                supportsSunroofControl: supportsSunroofControl,
                climatizationType: intValue(climate, 1).flatMap(VehicleClimatizationType.init(rawValue:)),
                climatizationHeatingType: intValue(climate, 2).flatMap(VehicleClimatizationHeatingType.init(rawValue:)),
                climatizationMaximumRuntimeMinutes: positiveInt(varint(climate ?? [], 3)),
                supportsAutomaticSeatAndWheelHeating: varint(climate ?? [], 12).map { $0 != 0 },
                userIsLinked: varint(myCar, 2).map { $0 != 0 },
                userIsOwner: varint(myCar, 3).map { $0 != 0 },
                registrationPlate: string(myCar, 4).nilIfEmpty
            )
            capabilities.honkFlashMode = honkFlashMode
            capabilities.equipment = parseEquipment(car)
            capabilities.unknownWireFields = unknownCapabilityFields(car)
            var advertised: [VehicleCapability: Bool] = [:]
            func record(_ capability: VehicleCapability, _ fields: [Protobuf.Field]?, _ number: Int) {
                if let raw = varint(fields ?? [], number) { advertised[capability] = raw != 0 }
            }
            record(.chargeTarget, targetSettings, 1)
            record(.chargingCurrentLimit, amperageSettings, 1)
            record(.chargingSchedule, chargingData, 11)
            record(.chargingScheduleOverride, chargingData, 15)
            record(.windows, locksData, 5)
            record(.preCleaning, airData, 1)
            record(.tyrePressureValues, car, 50)
            record(.serviceWarnings, car, 87)
            record(.engineStart, car, 27)
            let temperature = message(climate ?? [], field: 6).map(Protobuf.fields)
            record(.climateTemperature, temperature, 1)
            let frontSeats = varint(climate ?? [], 8).map { $0 != 0 }
            let rearSeats = varint(climate ?? [], 9).map { $0 != 0 }
            if frontSeats == true || rearSeats == true {
                advertised[.seatHeating] = true
            } else if frontSeats == false && rearSeats == false {
                advertised[.seatHeating] = false
            }
            record(.steeringWheelHeating, climate, 10)
            if let mode = honkFlashMode, mode != .unspecified {
                advertised[.honkAndFlash] = mode != .none
            }
            // The vehicle's own enum fields say which controls exist, and on a car where the
            // model-family table is wrong they are the only authority. Unknown ordinals are
            // ignored so a newer backend cannot disable a control by adding a value.
            switch intValue(locksData, 1) {           // Locks.lock_type
            case 1:                                  // NONE
                advertised[.locks] = false
                advertised[.reducedGuardLock] = false
            case 2:                                  // LOCK
                advertised[.locks] = true
                advertised[.reducedGuardLock] = false
            case 3:                                  // LOCK_REDUCED_GUARD
                advertised[.locks] = true
                advertised[.reducedGuardLock] = true
            default: break
            }
            switch unlockType {
            case .noUnlock:                          // NONE: locking only
                advertised[.remoteUnlock] = false
            case .trunkOnly:                         // TRUNK_ONLY: the tailgate, not the doors
                advertised[.remoteUnlock] = false
                advertised[.trunk] = true
            case .direct:                            // DIRECT: central unlock
                advertised[.remoteUnlock] = true
            default: break
            }
            switch intValue(chargingData, 10) {      // Charging.charge_timer_type
            case 1:                                  // NONE: no charge timer at all
                advertised[.chargingSchedule] = false
            case 3:                                  // LOCATION_BASED: timers live on locations
                advertised[.chargeLocations] = true
            default: break
            }
            switch intValue(climate, 1) {            // ParkingClimatization.type
            case 1:                                  // NONE
                advertised[.climateStartStop] = false
            case 2, 3:                               // HEATING, HEATING_AND_COOLING
                advertised[.climateStartStop] = true
            default: break
            }
            capabilities.advertisedCapabilities = advertised
            let timers = message(climate ?? [], field: 13).map(Protobuf.fields) ?? []
            var settings = VehicleControlSettings()
            settings.climateTimerMaximum = positiveInt(varint(timers, 7))
            settings.repeatedClimateTimers = varint(timers, 2).map { $0 != 0 }
            settings.singleClimateTimers = varint(timers, 8).map { $0 != 0 }
            settings.chargeLocationMaximum = positiveInt(varint(chargingData ?? [], 16))
            settings.timersPerLocationMaximum = positiveInt(varint(chargingData ?? [], 13))
            settings.departureTimesPerLocationMaximum = positiveInt(varint(chargingData ?? [], 18))
            settings.locationDepartureTimes = varint(chargingData ?? [], 17).map { $0 != 0 }
            settings.locationAmperage = varint(amperageSettings ?? [], 2).map { $0 != 0 }
            settings.locationOptimization = varint(chargingData ?? [], 4).map { $0 != 0 }
            settings.temperatureMinimum = positiveInt(varint(temperature ?? [], 3))
            settings.temperatureMaximum = positiveInt(varint(temperature ?? [], 2))
            settings.frontSeatSettings = varint(climate ?? [], 8).map { $0 != 0 }
            settings.rearSeatSettings = varint(climate ?? [], 9).map { $0 != 0 }
            settings.steeringWheelSettings = varint(climate ?? [], 10).map { $0 != 0 }
            capabilities.controlSettings = settings
            return capabilities
        }
        return nil
    }

    private static func parseEquipment(_ car: [Protobuf.Field]) -> VehicleEquipment {
        func nested(_ fields: [Protobuf.Field], _ number: Int) -> [Protobuf.Field] {
            message(fields, field: number).map(Protobuf.fields) ?? []
        }
        func flag(_ fields: [Protobuf.Field], _ number: Int) -> Bool? {
            varint(fields, number).map { $0 != 0 }
        }
        func integer(_ fields: [Protobuf.Field], _ number: Int) -> Int? {
            varint(fields, number).flatMap(Int.init(exactly:))
        }
        func label(_ fields: [Protobuf.Field], _ number: Int, _ labels: [Int: String]) -> String? {
            guard let value = integer(fields, number), value != 0 else { return nil }
            return labels[value] ?? L10n.format("Unknown (%d)", value)
        }
        let propulsion = nested(car, 40)
        let charging = nested(car, 35)
        let target = nested(charging, 8)
        let air = nested(car, 34)
        let key = nested(car, 39)
        var result = VehicleEquipment()
        result.brand = label(car, 2, [1: "Volvo", 2: "Polestar"])
        result.vehicleTypeCode = string(car, 5).nilIfEmpty
        result.drivetrain = label(propulsion, 1, [1: "AWD", 2: "RWD", 3: "FWD"])
        result.engine = label(propulsion, 6, [1: "Electric", 2: "Diesel", 3: "Petrol", 4: "Petrol hybrid", 5: "Diesel hybrid"])
        result.driverSide = label(car, 46, [1: "Left", 2: "Right"])
        result.infotainment = label(nested(car, 42), 6, [1: "None", 2: "MCA Sensus", 3: "SPA/CMA Sensus", 4: "Android", 5: "Geely Android"])
        result.doorCount = integer(car, 43).flatMap { (1...10).contains($0) ? $0 : nil }
        result.chargePort = label(charging, 2, [1: "None", 2: "Left", 3: "Right"])
        result.batterySerial = string(charging, 3).nilIfEmpty
        result.batteryCapacityKwh = numeric(propulsion, 5).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        result.grossVehicleWeightRatingKg = numeric(car, 44).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        result.digitalKey = label(key, 1, [1: "None", 2: "Polestar 1", 3: "Polestar 2", 4: "CCC"])
        result.nfcReader = label(car, 68, [1: "None", 2: "Door handle", 3: "B-pillar"])
        let phones = nested(key, 3)
        if !phones.isEmpty {
            let names = ["Apple", "Google", "Samsung", "Huawei", "Xiaomi", "Vivo", "Oppo", "Motorola", "OnePlus"]
            result.compatiblePhones = names.enumerated().compactMap { flag(phones, $0.offset + 1) == true ? $0.element : nil }
        }
        if flag(target, 6) == true, let daily = integer(target, 5), (1...100).contains(daily) {
            result.dailyChargeTarget = daily
        }
        result.automaticBatteryPreconditioning = flag(charging, 36)
        if flag(air, 7) == true {
            result.airCleaningRuntimeMinutes = integer(air, 8).flatMap { $0 > 0 ? $0 : nil }
        }
        result.internalAirMeasurement = flag(air, 2)
        result.externalAirMeasurement = flag(air, 3)
        result.restrictedSoftwareVersion = string(nested(car, 74), 6).nilIfEmpty
        if let contentCodes = string(car, 47).nilIfEmpty {
            result.contentCodes = contentCodes.split(separator: "-").map(String.init)
        }
        // Report-support booleans. `flag` reads nil when the field is absent, which proto3
        // makes indistinguishable from false; the nil survives so the UI hides the row.
        result.reportsAvgElectricConsumption = flag(car, 20)
        result.reportsAvgSpeed = flag(car, 22)
        result.reportsAvgSpeedLastTrip = flag(car, 53)
        result.supportsDrivingJournal = flag(car, 26)
        result.supportsStolenVehicleTracking = flag(car, 29)
        result.reportsChargeLevelWhileCharging = flag(charging, 5)
        result.reportsElectricRange = flag(charging, 7)
        result.supportsChargeLocationsDepartureTimeMinChargeLevelSetting = flag(charging, 27)
        // Car 51 `notification` carries fourteen booleans; only these five subfields have a
        // verified name, so an unknown subfield never gains a guessed label.
        let notification = nested(car, 51)
        let notificationNames: [(Int, String)] = [
            (1, L10n.text("Unlocked Reminder")),
            (3, L10n.text("Charging Completed")),
            (4, L10n.text("Charging Interrupted")),
            (6, L10n.text("Climate Interrupted")),
            (9, L10n.text("Theft"))
        ]
        let kinds = notificationNames.compactMap { flag(notification, $0.0) == true ? $0.1 : nil }
        result.reportedNotificationKinds = kinds.isEmpty ? nil : kinds
        // Car 55 `end_ownership_actions` is a packed repeated enum; the frame's own order is
        // kept, and values with no verified name stay out of the list.
        let actions = repeatedVarints(car, 55).compactMap { raw -> String? in
            switch raw {
            case 1: return L10n.text("Remove App Access")
            case 2: return L10n.text("Remote Factory Reset")
            case 3: return L10n.text("Revoke Internet Agreement")
            case 6: return L10n.text("Revokes Digital Keys")
            default: return nil
            }
        }
        result.reportedEndOwnershipActions = actions.isEmpty ? nil : actions
        // Car 17 `parking_assistance_type` (`RemoteParkingAssistanceType`): only ordinal 1
        // (NONE) is recorded in repo evidence, so other ordinals fall back to the raw number.
        result.parkingAssistance = label(car, 17, [1: "None"])
        // Car 38 `account_linking`: subfield 2 carries the in-car linking type against the
        // nine-value `InCarAccountLinkingType` table. Subfield 1 (support boolean) is absent
        // on the captured frame and is not decoded.
        let accountLinking = nested(car, 38)
        result.inCarAccountLinking = label(accountLinking, 2, [
            1: "None", 2: "MCA Sensus QR", 3: "SPA CMA Sensus QR", 4: "SPA CMA Android QR",
            5: "SPA2 Android login", 6: "SPA2 Android QR", 7: "Geely Android QR",
            8: "Zeekr Android QR", 9: "SPA3 Android QR"
        ])
        // Car 63 `trips`: one row from the kinds the car actually reports; an absent fuel
        // flag on a battery-electric car must not read as a claimed capability.
        let trips = nested(car, 63)
        if !trips.isEmpty {
            var tripKinds: [String] = []
            if flag(trips, 1) == true { tripKinds.append("Electric Consumption") }
            if flag(trips, 2) == true { tripKinds.append("Regeneration") }
            if flag(trips, 3) == true { tripKinds.append("Fuel") }
            result.tripReporting = tripKinds
        }
        result.supportsDevicePairing = flag(car, 79)
        // Charging 35.40 `bidirectional_charging`: message presence is the advertisement.
        // Subfield 4 (`transfer_limit_settings`) present but empty means no limits are
        // configured; a non-empty submessage holds a layout this build cannot read and stays
        // unknown rather than guessed at.
        if let bidirectional = message(charging, field: 40) {
            result.bidirectionalCharging = true
            if let limits = message(bidirectional, field: 4), Protobuf.fields(limits).isEmpty {
                result.bidirectionalTransferLimitsConfigured = false
            }
        }
        // Charging 35.41 is a `google.protobuf.Duration`: {1: seconds (int64), 2: nanos
        // (int32)}. An empty message is a zero duration and still earns its "0 min" row;
        // an unreadable magnitude (e.g. a negative encoded duration) stays hidden.
        if let duration = message(charging, field: 41) {
            let durationFields = Protobuf.fields(duration)
            let seconds = varint(durationFields, 1) ?? 0
            let nanos = varint(durationFields, 2) ?? 0
            let totalSeconds = Double(seconds) + Double(nanos) / 1_000_000_000
            result.fastChargePreconditioningMinutes = Int(exactly: (totalSeconds / 60).rounded())
        }
        let lightFields = car.filter { $0.number == 73 }
        if !lightFields.isEmpty {
            result.supportedLightWarnings = lightFields.flatMap { field -> [UInt64] in
                if field.wire == 0 { return [field.varint] }
                guard field.wire == 2 else { return [] }
                return Protobuf.packedVarints(field.data) ?? []
            }.map(VehicleLightCoverage.name)
        }
        return result
    }

    private static func plausibleLimit(
        _ fields: [Protobuf.Field]?, field number: Int, range: ClosedRange<Int>
    ) -> Int {
        guard let raw = fields?.first(where: { $0.number == number && $0.wire == 0 })?.varint else {
            return 0
        }
        let value = Int(raw)
        return range.contains(value) ? value : 0
    }

    static func parseGlobalChargeTimer(_ data: Data) -> VehicleSchedule? {
        let fields = Protobuf.fields(data)
        let active = varint(fields, 3) == 1
        guard let start = dailyTime(message(fields, field: 1)),
              let stop = dailyTime(message(fields, field: 2)) else { return nil }
        return VehicleSchedule(kind: .globalCharging, startHour: start.0, startMinute: start.1,
                               endHour: stop.0, endMinute: stop.1, weekdays: [], isActive: active)
    }

    static func parseChargeLocationSchedules(_ data: Data) -> [VehicleSchedule] {
        Protobuf.fields(data).filter { $0.number == 3 && $0.wire == 2 }.flatMap { location -> [VehicleSchedule] in
            let fields = Protobuf.fields(location.data)
            let locName = string(fields, 2).nilIfEmpty
            let chargeTimers = fields.filter { $0.number == 10 && $0.wire == 2 }.compactMap { timer -> VehicleSchedule? in
                let values = Protobuf.fields(timer.data)
                guard let start = dailyTime(message(values, field: 3)),
                      let stop = dailyTime(message(values, field: 4)) else { return nil }
                return VehicleSchedule(kind: .locationCharging, startHour: start.0, startMinute: start.1,
                                       endHour: stop.0, endMinute: stop.1,
                                       weekdays: weekdays(message(values, field: 5)),
                                       isActive: varint(values, 2) == 1,
                                       locationName: locName)
            }
            let departures = fields.filter { $0.number == 11 && $0.wire == 2 }.compactMap { departure -> VehicleSchedule? in
                let values = Protobuf.fields(departure.data)
                guard let time = dailyTime(message(values, field: 3)) else { return nil }
                return VehicleSchedule(kind: .departure, startHour: time.0, startMinute: time.1,
                                       endHour: nil, endMinute: nil,
                                       weekdays: weekdays(message(values, field: 4)),
                                       isActive: varint(values, 2) == 1,
                                       locationName: locName)
            }
            return chargeTimers + departures
        }
    }

    static func parseClimate(_ data: Data) -> VehicleClimateStatus {
        let fields = Protobuf.fields(data)
        let digitalTwin = fields.first(where: { $0.number == 1 })?.wire == 2
        let running = varint(fields, digitalTwin ? 2 : 1) ?? 0
        let request = varint(fields, digitalTwin ? 15 : 2) ?? 0
        let remaining = positiveInt(varint(fields, 3))
        let interiorTemperature = digitalTwin ? numeric(fields, 7) : nil
        let requestedTemperature = digitalTwin ? numeric(fields, 8) : nil
        func requestedHeatingLevel(_ field: Int) -> Int? {
            guard digitalTwin, let value = varint(fields, field), (1...4).contains(value) else { return nil }
            return Int(value) - 1
        }
        let ventilation: String? = {
            guard digitalTwin else { return nil }
            switch varint(fields, 6) {
            case 1: return "VENTILATION_COOLING"
            case 2: return "VENTILATION_HEATING"
            case 3: return "VENTILATION_NEUTRAL"
            default: return nil
            }
        }()
        let sessionStartedAt = digitalTwin ? timestamp(message(fields, field: 14)) : nil
        let sessionEndsAt = digitalTwin ? timestamp(message(fields, field: 16)) : nil
        let activity: ClimateActivity
        if digitalTwin {
            if running == 3 {
                activity = .starting
            } else if running == 1 {
                switch ventilation {
                case "VENTILATION_HEATING": activity = .heating
                case "VENTILATION_COOLING": activity = .cooling
                default: activity = .active
                }
            } else {
                activity = .idle
            }
        } else {
            let actionValue = varint(fields, 4) ?? 0
            switch actionValue {
            case 2: activity = .heating
            case 3, 4: activity = .cooling
            case 5: activity = .ventilating
            default:
                let active = [4, 5, 6, 7, 8].contains(running)
                let starting = [2, 3].contains(running)
                activity = active ? .active : (starting ? .starting : (running > 0 ? .idle : .unknown))
            }
        }
        let timerTriggered = digitalTwin ? request == 3 : request == 2
        // Field 15 is `start_reason` on the digital-twin frame. Its wire numbering differs
        // from `VehicleStartReason`'s raw values (1 = car, 2 = remote, 3 = timer,
        // 4 = keep climate), so map explicitly instead of round-tripping the raw value.
        let startReason: VehicleStartReason? = {
            guard digitalTwin else { return nil }
            switch request {
            case 1: return .manuallyFromCar
            case 2: return .remote
            case 3: return .timer
            case 4: return .keepClimate
            default: return nil
            }
        }()
        // Field 4 is repeated `ErrorType` on the digital-twin frame; on the legacy frame the
        // same number is the climate action, so this is scoped to digitalTwin.
        let climateErrors: [String]? = {
            guard digitalTwin else { return nil }
            let names = repeatedVarints(fields, 4).compactMap { raw -> String? in
                switch raw {
                case 1: return L10n.text("Fuel level low")
                case 2: return L10n.text("Battery level low")
                case 3: return L10n.text("Not connected to power")
                case 4: return L10n.text("No start needed")
                case 5: return L10n.text("Service required")
                case 6: return L10n.text("Temporarily unavailable")
                case 7: return L10n.text("Persistent error")
                case 8: return L10n.text("Maximum runtime reached")
                default: return nil
                }
            }
            return names.isEmpty ? nil : names
        }()
        // Field 5 is repeated `WarningType` on the digital-twin frame. Only 1 and 2 are defined.
        let climateWarnings: [String]? = {
            guard digitalTwin else { return nil }
            let names = repeatedVarints(fields, 5).compactMap { raw -> String? in
                switch raw {
                case 1: return "BATTERY_LOW"
                case 2: return "RUN_TIME_NEARING_LIMIT"
                default: return nil
                }
            }
            return names.isEmpty ? nil : names
        }()
        let decodedClimateFields: Set<Int> = digitalTwin
            ? [1, 2, 3, 4, 5, 7, 8, 14, 15, 16]
            : [1, 2, 3, 4]
        let unknownWireFields = fields.filter { field in
            if digitalTwin && field.number == 6 {
                return field.wire != 0 || !(1...3).contains(field.varint)
            }
            if digitalTwin && (field.number == 4 || field.number == 5) {
                // ErrorType 1…8 (field 4) and WarningType 1…2 (field 5) are decoded; anything
                // else is a value this build does not understand and must stay visible in the
                // raw disclosure.
                let known: ClosedRange<UInt64> = field.number == 4 ? 1...8 : 1...2
                switch field.wire {
                case 0: return !known.contains(field.varint)
                case 2:
                    let values = Protobuf.packedVarints(field.data) ?? []
                    return values.isEmpty || !values.allSatisfy { known.contains($0) }
                default: return true
                }
            }
            if digitalTwin && (9...13).contains(field.number) {
                return field.wire != 0 || field.varint > 4
            }
            return !decodedClimateFields.contains(field.number)
        }.map(PolestarGRPC.rawField)
        return VehicleClimateStatus(activity: activity, timeRemainingMinutes: remaining,
                                    timerTriggered: timerTriggered,
                                    interiorTemperatureCelsius: interiorTemperature,
                                    requestedTemperatureCelsius: requestedTemperature,
                                    driverSeatHeatingLevel: requestedHeatingLevel(9),
                                    passengerSeatHeatingLevel: requestedHeatingLevel(10),
                                    steeringWheelHeatingLevel: requestedHeatingLevel(13),
                                    rearLeftSeatHeatingLevel: requestedHeatingLevel(11),
                                    rearRightSeatHeatingLevel: requestedHeatingLevel(12),
                                    ventilation: ventilation,
                                    sessionStartedAt: sessionStartedAt,
                                    sessionEndsAt: sessionEndsAt,
                                    unknownWireFields: unknownWireFields.isEmpty ? nil : unknownWireFields,
                                    errors: climateErrors,
                                    climateWarnings: climateWarnings,
                                    startReason: startReason)
    }

    /// Reads a repeated varint field whether the encoder wrote it packed (wire 2) or as
    /// individual varints (wire 0). Climate error and warning lists can arrive either way.
    private static func repeatedVarints(_ fields: [Protobuf.Field], _ number: Int) -> [UInt64] {
        fields.filter { $0.number == number }.flatMap { field -> [UInt64] in
            if field.wire == 0 { return [field.varint] }
            if field.wire == 2, let values = Protobuf.packedVarints(field.data) { return values }
            return []
        }
    }

    static func parseClimateTimers(_ data: Data) -> [VehicleSchedule] {
        let fields = Protobuf.fields(data)
        let deleted = Set(fields.filter { $0.number == 5 && $0.wire == 2 }.compactMap { string(Protobuf.fields($0.data), 1) })
        var timers: [String: VehicleSchedule] = [:]
        for field in fields where (field.number == 3 || field.number == 4) && field.wire == 2 {
            let values = Protobuf.fields(field.data)
            guard let id = string(values, 1).nilIfEmpty, !deleted.contains(id),
                  let time = dailyTime(message(values, field: 3)) else { continue }
            timers[id] = VehicleSchedule(backendID: id,
                                         index: varint(values, 2).flatMap(Int.init(exactly:)) ?? 0,
                                         kind: .climate, startHour: time.0, startMinute: time.1,
                                         endHour: nil, endMinute: nil,
                                         weekdays: weekdays(message(values, field: 6)),
                                         isActive: varint(values, 4) == 1,
                                         repeatsWeekly: varint(values, 5).map { $0 != 0 })
        }
        return timers.keys.sorted().compactMap { timers[$0] }
    }


    private static func timestampMilliseconds(seconds: UInt64, nanoseconds: UInt64) -> UInt64? {
        guard nanoseconds < 1_000_000_000 else { return nil }
        let (millis, overflow) = seconds.multipliedReportingOverflow(by: 1_000)
        guard !overflow else { return nil }
        let (result, additionOverflow) = millis.addingReportingOverflow(nanoseconds / 1_000_000)
        return additionOverflow ? nil : result
    }

    static func parseLocation(_ data: Data) -> VehicleLocation? {
        PolestarLocationWeatherCodec.location(data)
    }

    static func parseWeather(_ data: Data) -> VehicleWeather? {
        PolestarLocationWeatherCodec.weather(data)
    }


    private static func vehicleRequest(_ vin: String) -> Data {
        var data = Data()
        data.append(Protobuf.stringField(1, UUID().uuidString))
        data.append(Protobuf.stringField(2, vin))
        return data
    }

    private static func healthRequest(_ vin: String) -> Data { Protobuf.stringField(2, vin) }

    private static func message(_ data: Data, field: Int) -> Data? { message(Protobuf.fields(data), field: field) }
    private static func message(_ fields: [Protobuf.Field], field: Int) -> Data? {
        fields.first(where: { $0.number == field && $0.wire == 2 })?.data
    }
    private static func varint(_ fields: [Protobuf.Field], _ number: Int) -> UInt64? {
        fields.first(where: { $0.number == number && $0.wire == 0 })?.varint
    }
    private static func numeric(_ fields: [Protobuf.Field], _ number: Int) -> Double? {
        guard let field = fields.first(where: { $0.number == number }) else { return nil }
        if field.wire == 0 { return Double(field.varint) }
        if field.wire == 1 { return Protobuf.double(from: field.data) }
        if field.wire == 5 { return Protobuf.float(from: field.data).map(Double.init) }
        return nil
    }
    private static func string(_ fields: [Protobuf.Field], _ number: Int) -> String {
        guard let data = fields.first(where: { $0.number == number && $0.wire == 2 })?.data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    private static func timestamp(_ data: Data?) -> Date? {
        guard let data, let seconds = varint(Protobuf.fields(data), 1), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
    /// A numeric wire field as an `Int`, for ordinals and small limits where `UInt64` reads badly.
    private static func intValue(_ fields: [Protobuf.Field]?, _ number: Int) -> Int? {
        varint(fields ?? [], number).flatMap { Int(exactly: $0) }
    }

    private static func positiveInt(_ value: UInt64?) -> Int? {
        guard let value, value > 0, value <= UInt64(Int.max) else { return nil }
        return Int(value)
    }
    private static func positive(_ value: Double?) -> Double? {
        guard let value, value > 0, value.isFinite else { return nil }
        return value
    }
    private static func openState(_ value: UInt64) -> OpeningState {
        switch value { case 1: return .open; case 2: return .closed; case 3: return .ajar; default: return .unknown }
    }
    /// Maps a wire value to the domain warning. Returns nil for an *absent* field so the
    /// caller decides whether omission means "all clear" (substantive payload) or "unknown".
    private static func tyreWarning(_ value: UInt64?) -> TyrePressureWarning? {
        switch value {
        case 1: return TyrePressureWarning.none
        case 2: return .veryLow
        case 3: return .low
        case 4: return .high
        default: return .unknown
        }
    }

    private static func dailyTime(_ data: Data?) -> (Int, Int)? {
        guard let data else { return nil }
        let fields = Protobuf.fields(data)
        let hour = varint(fields, 1) ?? 0
        let minute = varint(fields, 2) ?? 0
        guard hour < 24, minute < 60 else { return nil }
        return (Int(hour), Int(minute))
    }
    private static func weekdays(_ data: Data?) -> [VehicleWeekday] {
        guard let data else { return [] }
        return Protobuf.packedVarints(data)?.compactMap { Int(exactly: $0) }
            .compactMap { VehicleWeekday(rawValue: $0) } ?? []
    }
}
