import Foundation

struct GrpcHealthReport: Equatable, Sendable {
    let details: VehicleHealthDetails
    let daysToService: Int?
    let distanceToServiceKm: Int?
    let serviceWarning: Bool
}

struct GrpcOdometerReport: Equatable, Sendable {
    let odometerKm: Int?
    let manualTripKm: Double?
    let automaticTripKm: Double?
}

extension PolestarGRPC {
    private static let exteriorPath = "/services.vehiclestates.exterior.ExteriorService/GetLatestExterior"
    private static let exteriorStreamPath = "/services.vehiclestates.exterior.ExteriorService/GetExterior"
    private static let healthPath = "/services.vehiclestates.health.HealthService/GetHealth"
    private static let odometerPath = "/services.vehiclestates.odometer.OdometerService/GetOdometer"
    private static let dashboardPath = "/services.vehiclestates.dashboard.DashboardService/GetLatestDashboard"
    private static let softwarePath = "/ota_mobcache.OtaDiscoveryService/GetSoftwareInfo"
    private static let softwareSchedulePath = "/ota_mobcache.SchedulerService/GetSchedule"
    private static let globalChargeTimerPath = "/pccs.chronos.services.v2.GlobalChargeTimerService/GetGlobalChargeTimerStream"
    private static let chargeLocationsPath = "/pccs.chronos.services.v1.ChargeLocationService/GetChargeLocations"
    private static let climatePath = "/services.vehiclestates.parkingclimatization.ParkingClimatizationService/GetLatestParkingClimatization"
    private static let climateTimersPath = "/pccs.chronos.services.v1.ParkingClimateTimerService/GetTimers"
    private static let preCleaningPath = "/services.vehiclestates.precleaning.PreCleaningService/GetPreCleaning"
    private static let locationPath = "/dtlinternet.DtlInternetService/GetLastKnownLocation"
    private static let weatherPath = "/weather.WeatherService/GetWeatherReport"
    private static let errorsPath = "/chronos.services.v1.ErrorService/GetErrors"
    private static let myCarsPath = "/car_information.CarInformation/GetMyCars"

    func fetchExterior(vin: String, accessToken: String) async throws -> ExteriorSnapshot? {
        let path = useStreaming ? Self.exteriorStreamPath : Self.exteriorPath
        let body = try await firstMessage(path: path, message: Self.vehicleRequest(vin),
                                           vin: vin, accessToken: accessToken)
        guard let payload = Self.message(body, field: 3) else { return nil }
        let current = Self.parseExterior(payload)
        guard let current else { return exteriorCache[vin] }
        let merged = current.merging(previous: exteriorCache[vin])
        exteriorCache[vin] = merged
        return merged
    }

    func fetchHealth(vin: String, accessToken: String) async throws -> GrpcHealthReport? {
        let body = try await firstMessage(path: Self.healthPath, message: Self.healthRequest(vin),
                                          vin: vin, accessToken: accessToken)
        guard let payload = Self.message(body, field: 3) else { return nil }
        return Self.parseHealth(payload)
    }

    func fetchOdometer(vin: String, accessToken: String) async throws -> GrpcOdometerReport? {
        do {
            let body = try await firstMessage(path: Self.odometerPath, message: Self.healthRequest(vin),
                                              vin: vin, accessToken: accessToken)
            if let payload = Self.message(body, field: 3) {
                let result = Self.parseOdometer(payload)
                if result.odometerKm != nil || result.manualTripKm != nil || result.automaticTripKm != nil {
                    return result
                }
            }
        } catch {

        }
        let body = try await firstMessage(path: Self.dashboardPath, message: Self.vehicleRequest(vin),
                                          vin: vin, accessToken: accessToken)
        guard let dashboard = Self.message(body, field: 2),
              let data = Self.message(dashboard, field: 1) else { return nil }
        return Self.parseDashboardOdometer(data)
    }

    func fetchSoftware(vin: String, accessToken: String, locale: String) async throws -> VehicleSoftwareInfo? {
        var request = Data()
        request.append(Protobuf.stringField(1, vin))
        request.append(Protobuf.stringField(2, locale))
        var info: VehicleSoftwareInfo?
        var firstError: Error?
        do {
            let body = try await firstMessage(path: Self.softwarePath, message: request,
                                              vin: vin, accessToken: accessToken)
            if let payload = Self.message(body, field: 1) {
                rememberSoftwareID(Self.string(Protobuf.fields(payload), 1), vin: vin)
                let parsed = Self.parseSoftware(payload)
                otaSoftwareStates[vin] = parsed.state
                otaRawSoftwareStates[vin] = parsed.rawState
                info = parsed
            }
        } catch { firstError = error }

        // `Scheduler`: 1 status, 2 relative_time, 3 scheduled_time, 4 software_id, 5 set_by.
        // This is a second source of the software id — it stays populated for a scheduled
        // install even when GetSoftwareInfo has nothing to report, which is what makes
        // "cancel a scheduled installation" reachable.
        var scheduledAt: Date?
        var scheduleSetBy: ScheduleSetBy?
        do {
            let body = try await firstMessage(path: Self.softwareSchedulePath,
                                              message: Protobuf.stringField(1, vin),
                                              vin: vin, accessToken: accessToken)
            if let scheduler = Self.message(body, field: 1) {
                let fields = Protobuf.fields(scheduler)
                scheduledAt = Self.timestamp(Self.message(fields, field: 3))
                rememberSoftwareID(Self.string(fields, 4), vin: vin)
                if let setByValue = Self.varint(fields, 5), let setBy = ScheduleSetBy(rawValue: Int(setByValue)) {
                    scheduleSetBy = setBy
                }
                if scheduledAt != nil, otaSoftwareStates[vin] == nil {
                    otaSoftwareStates[vin] = .scheduled
                }
            }
        } catch {
            if firstError == nil { firstError = error }
        }

        if let info {
            var merged = info
            merged.scheduledAt = info.scheduledAt ?? scheduledAt
            merged.scheduleSetBy = scheduleSetBy
            return merged
        }
        if let scheduledAt {
            // A schedule exists but GetSoftwareInfo returned nothing, so the target version is
            // genuinely unknown here. Report the schedule and leave every version field nil
            // rather than inventing one.
            return VehicleSoftwareInfo(state: .scheduled, scheduledAt: scheduledAt,
                                       scheduleSetBy: scheduleSetBy)
        }
        if let firstError { throw firstError }
        return nil
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
        let body = try await firstMessage(path: Self.chargeLocationsPath,
                                          message: Self.chronosRequest(vin),
                                          vin: vin, accessToken: accessToken, host: .pccs)
        return Self.parseChargeLocations(body)
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
                ampLimit: Int(varint(f, 5) ?? 0),
                minimumSoc: Int(varint(f, 6) ?? 0),
                optimisedChargingEnabled: (varint(f, 7) ?? 0) == 1,
                kind: Int(varint(f, 12) ?? 0)
            )
        }
    }

    func fetchChargingSchedules(vin: String, accessToken: String) async throws -> [VehicleSchedule] {        var schedules: [VehicleSchedule] = []
        var errors: [Error] = []
        do {
            let body = try await firstMessage(path: Self.globalChargeTimerPath,
                                              message: Self.chronosRequest(vin),
                                              vin: vin, accessToken: accessToken, host: .pccs)
            if let timer = Self.message(body, field: 1), let parsed = Self.parseGlobalChargeTimer(timer) {
                schedules.append(parsed)
            }
        } catch { errors.append(error) }
        do {
            let body = try await firstMessage(path: Self.chargeLocationsPath,
                                              message: Self.chronosRequest(vin),
                                              vin: vin, accessToken: accessToken, host: .pccs)
            schedules.append(contentsOf: Self.parseChargeLocationSchedules(body))
        } catch { errors.append(error) }


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

    /// Fetches vehicle service errors from `chronos.services.v1.ErrorService/GetErrors` (C3).
    /// The response is a oneof-style message where exactly one per-service error
    func fetchErrors(vin: String, accessToken: String) async throws -> [VehicleChronosError] {
        // ErrorService is server-streaming and may take longer than the default 10s request
        // timeout to return the first frame on PCCS — use a dedicated session with a longer
        // timeout. The service is not deployed on all backends/regions; if it returns
        // UNAVAILABLE (14) or UNIMPLEMENTED (12), treat it as "no errors" rather than failing.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        let longSession = URLSession(configuration: config)
        let base = try await resolvedHost(.c3, accessToken: accessToken)
        var request = URLRequest(url: base.appendingPathComponent(Self.errorsPath))
        request.httpMethod = "POST"
        request.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
        request.setValue("grpc-java-okhttp/1.68.2", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(vin, forHTTPHeaderField: "vin")
        request.httpBody = Protobuf.grpcFrame(Self.chronosEnvelope(vin: vin))

        do {
            let (bytes, response) = try await longSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                return []
            }
            if let status = http.value(forHTTPHeaderField: "grpc-status"), status != "0" {
                // 12=UNIMPLEMENTED, 14=UNAVAILABLE — service not deployed; no errors to report.
                if status == "12" || status == "14" { return [] }
                throw PolestarError.invalidResponse(operation: "gRPC errors status \(status)")
            }
            guard http.statusCode == 200 else { return [] }
            var header = [UInt8]()
            var body = Data()
            var expected: Int?
            for try await byte in bytes {
                if expected == nil {
                    header.append(byte)
                    guard header.count == 5 else { continue }
                    expected = Int(header[1]) << 24 | Int(header[2]) << 16
                        | Int(header[3]) << 8 | Int(header[4])
                    if expected == 0 { break }
                    continue
                }
                body.append(byte)
                if let frameSize = expected, body.count == frameSize { break }
            }
            guard !body.isEmpty else { return [] }
            return Self.parseErrors(body)
        } catch let error as URLError where error.code == .timedOut {
            // Server-streaming timeout — service didn't respond; treat as no errors.
            return []
        }
    }

    /// Fetches vehicle information from `car_information.CarInformation/GetMyCars` (C3 gRPC).
    /// Returns backend-authoritative capability flags and the **actually installed** software
    /// version (`consumerSoftwareVersion`) — which `GetSoftwareInfo` does not provide during
    /// a rollout.
    func fetchMyCars(vin: String, accessToken: String) async throws -> VehicleOTACapabilities? {
        let body = try await firstMessage(path: Self.myCarsPath, message: Data(),
                                          vin: vin, accessToken: accessToken)
        let capabilities = Self.parseMyCars(body, vin: vin)
        // Cache the backend-reported charging bounds so command validation can use the same
        // limits the vehicle itself advertises instead of hardcoded fallbacks.
        if let capabilities { capabilityLimits[vin] = capabilities }
        return capabilities
    }

    func fetchClimate(vin: String, accessToken: String) async throws -> VehicleClimateStatus? {
        let body = try await firstMessage(path: Self.climatePath, message: Self.vehicleRequest(vin),
                                          vin: vin, accessToken: accessToken)
        guard let payload = Self.message(body, field: 3) else { return nil }
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
        guard let payload = Self.message(body, field: 3) else { return nil }
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
            networkType: Self.varint(fields, 3).flatMap { network[Int($0)] },
            signalStrength: signalRaw.flatMap { signal[Int($0)] },
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
                                                  vin: vin, accessToken: accessToken, host: host)
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
        let errorRaw = Int(varint(fields, 13) ?? 0)
        let errorKind = AirCleaningError(rawValue: errorRaw) ?? (errorRaw > 0 ? .generic : nil)
        let hasAnyValue = [9, 10, 11, 14, 15, 16].contains { varint(fields, $0) != nil }
            || varint(fields, 6) != nil
        guard hasAnyValue else { return nil }
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
            startReason: varint(fields, 7).flatMap { AirCleaningStartReason(rawValue: Int($0)) },
            lastCycleValid: varint(fields, 8).map { $0 != 0 },
            errorKind: errorKind
        )
    }


    func fetchLocation(vin: String, accessToken: String) async throws -> VehicleLocation? {
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

                let candidates = [
                    body,
                    Self.message(body, field: 5),
                    Self.message(body, field: 1),
                    Self.message(body, field: 3),
                    Self.message(body, field: 2),
                    Self.message(body, field: 4)
                ].compactMap { $0 }

                for candidate in candidates {
                    if let loc = Self.parseLocation(candidate) {
                        return loc
                    }
                }
            } catch {
                continue
            }
        }
        return nil
    }


    func fetchWeather(vin: String, accessToken: String) async throws -> VehicleWeather? {
        if let location = try? await fetchLocation(vin: vin, accessToken: accessToken),
           let lat = location.latitude, let lon = location.longitude,
           abs(lat) > 0.001, abs(lon) > 0.001 {
            if let weather = await fetchOpenMeteoWeather(latitude: lat, longitude: lon) {
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
                let candidates = [
                    body,
                    Self.message(body, field: 1),
                    Self.message(body, field: 3),
                    Self.message(body, field: 2)
                ].compactMap { $0 }
                for candidate in candidates {
                    if let weather = Self.parseWeather(candidate) {
                        return weather
                    }
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private func fetchOpenMeteoWeather(latitude: Double, longitude: Double) async -> VehicleWeather? {
        guard let url = Self.openMeteoURL(latitude: latitude, longitude: longitude) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any] else { return nil }

        let temp = current["temperature_2m"] as? Double
        let feelsLike = current["apparent_temperature"] as? Double
        let humidity = current["relative_humidity_2m"] as? Int
        let code = current["weather_code"] as? Int
        let condition = code.map(Self.wmoWeatherDescription)

        return VehicleWeather(
            temperatureCelsius: temp,
            condition: condition,
            apparentTemperatureCelsius: feelsLike,
            relativeHumidity: humidity,
            timestamp: Date()
        )
    }

    static func openMeteoURL(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.open-meteo.com"
        components.path = "/v1/forecast"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,relative_humidity_2m,apparent_temperature")
        ]
        return components.url
    }

    private static func wmoWeatherDescription(for code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly Cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing Drizzle"
        case 61, 63, 65: return "Rain"
        case 66, 67: return "Freezing Rain"
        case 71, 73, 75: return "Snow"
        case 77: return "Snow Grains"
        case 80, 81, 82: return "Rain Showers"
        case 85, 86: return "Snow Showers"
        case 95, 96, 99: return "Thunderstorm"
        default: return "Partly Cloudy"
        }
    }


    static func parseExterior(_ data: Data) -> ExteriorSnapshot? {
        let fields = Protobuf.fields(data)
        let isDigitalTwin = fields.contains { (2...16).contains($0.number) && $0.wire == 0 }
        var readings: [OpeningReading] = []
        var locked: Bool?
        var alarm: Bool?
        if isDigitalTwin {
            if let value = varint(fields, 2) { locked = value == 2 ? true : (value == 1 ? false : nil) }
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
        guard !readings.isEmpty || locked != nil || alarm != nil else { return nil }
        return ExteriorSnapshot(openings: readings, isLocked: locked, alarmTriggered: alarm)
    }

    static func parseHealth(_ data: Data) -> GrpcHealthReport {
        let fields = Protobuf.fields(data)
        let warningFields = [9, 10, 11, 12]
        // The documented positions are FL/FR/RL/RR at fields 39–42 (verified against
        // Polestar 3-era captures). The reference Polestar 2 capture returned warning level
        // only — but that is a backend/firmware fact for ONE car, not a platform law. Before
        // giving up on numeric pressures, scan a bounded neighbouring window for a coherent
        // quadruple: four CONSECUTIVE numeric fields whose values all sit in a plausible kPa
        // band (150–400; cold-to-hot passenger-tyre range). Read-only and deterministic, so
        // the worst case is identical to today's behaviour.
        let pressureFields = Self.discoverPressureQuadruple(fields, window: 36...52)
        let positions = TyrePosition.allCases
        var tyres: [TyrePressure] = []
        for index in positions.indices {
            let warningRaw = varint(fields, warningFields[index])
            let warning = tyreWarning(warningRaw)
            let pressure = pressureFields.flatMap { pFields in
                numeric(fields, pFields[index]).flatMap { $0 > 0 ? $0 : nil }
            }
            tyres.append(TyrePressure(position: positions[index], kilopascals: pressure, warning: warning))
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
            14: L10n.text("Left low beam"),
            15: L10n.text("Right low beam"),
            16: L10n.text("Left high beam"),
            17: L10n.text("Right high beam"),
            18: L10n.text("Left front indicator"),
            19: L10n.text("Right front indicator"),
            20: L10n.text("Left rear indicator"),
            21: L10n.text("Right rear indicator"),
            22: L10n.text("Left daytime running light"),
            23: L10n.text("Right daytime running light"),
            24: L10n.text("Left position light"),
            25: L10n.text("Right position light"),
            26: L10n.text("Left brake light"),
            27: L10n.text("Right brake light"),
            28: L10n.text("Center brake light"),
            29: L10n.text("Left reversing light"),
            30: L10n.text("Right reversing light"),
            31: L10n.text("Left fog light"),
            32: L10n.text("Right fog light"),
            33: L10n.text("Rear fog light"),
            34: L10n.text("License plate light"),
            35: L10n.text("Side marker light")
        ]
        for fieldNum in 14...35 {
            if varint(fields, fieldNum) == 2, let desc = lightDescriptions[fieldNum] {
                lightFailures.append(desc)
            }
        }
        if (14...35).contains(where: { varint(fields, $0) != nil }) {
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
        // must be folded into `warnings` explicitly — otherwise `Notifier.warningLabels` (which
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
            serviceWarning: warnings.contains(.service)
        )
    }

    static func parseOdometer(_ data: Data) -> GrpcOdometerReport {
        let fields = Protobuf.fields(data)
        return GrpcOdometerReport(
            odometerKm: positiveInt(varint(fields, 2)).map { $0 / 1_000 },
            manualTripKm: positive(numeric(fields, 3)),
            automaticTripKm: positive(numeric(fields, 4))
        )
    }

    static func parseDashboardOdometer(_ data: Data) -> GrpcOdometerReport {
        let fields = Protobuf.fields(data)
        return GrpcOdometerReport(
            odometerKm: positive(numeric(fields, 17)).map { Int($0.rounded()) },
            manualTripKm: positive(numeric(fields, 18)),
            automaticTripKm: positive(numeric(fields, 19))
        )
    }


    /// Parses an `ota_mobcache` `CarSoftwareInfo`:
    /// `1 software_id`, `2 description{1 name, 2 short, 3 long}`, `3 qb_code`, `4 state`,
    /// `5 install_info{1 estimated_duration_seconds}`, `6 new_sw_version`,
    /// `8 schedule_info{2 scheduled_at}`, `10 state_timestamp{1 seconds}`, `11 originator`.
    ///
    /// Field 5 is a nested message (not a scalar varint) — confirmed by
    /// `testDecodeGetSoftwareInfoRecursively`: `f5: msg(3){f1: varint=5400}`.
    static func parseSoftware(_ data: Data) -> VehicleSoftwareInfo {
        let fields = Protobuf.fields(data)
        let description = message(fields, field: 2).map(Protobuf.fields)
        let rawStateValue = varint(fields, 4) ?? 0
        let rawState = SoftwareStateRaw(rawValue: Int(rawStateValue)) ?? .unknown
        let state = rawState.coarseState
        let schedule = message(fields, field: 8).flatMap { message($0, field: 2) }
        let advertisedVersion = string(fields, 6).nilIfEmpty
        let parsedTitle = description.flatMap { string($0, 1).nilIfEmpty } ?? advertisedVersion

        // Field 5 is a nested message: `{1: estimated_install_duration_seconds}`.
        let installDuration = message(fields, field: 5)
            .flatMap { Protobuf.fields($0).first(where: { $0.number == 1 })?.varint }
            .map { Int($0) }

        // `new_sw_version` is the only version string the backend returns, and its meaning
        // depends on `state`: while an update is pending it is the *target* version, and the
        // running version is not reported at all. Only in the settled states does it describe
        // what is actually on the car. Anything not settled leaves `installedVersion` nil —
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
            latestAvailableVersion: describesInstalled ? nil : advertisedVersion
        )
    }

    /// `ota_mobcache.SoftwareState`. The enum it mirrors runs 0…14; 15 is an extra value this
    /// backend has been observed emitting for an update that has been *announced* but not yet
    /// *authorized for download* — distinct from 1 (`DOWNLOAD_READY`, which means the payload
    /// has been downloaded and is ready to install). Both collapse into `.available` here for
    /// UI continuity; the precise distinction is preserved in `VehicleSoftwareInfo.rawState`
    /// (see `SoftwareStateRaw`). Pinned by
    /// `testSoftwareVersionRepresentsAvailableUpdateNotInstalledVersion` and
    /// `testDecodeGetSoftwareInfoRecursively`. Anything else is reported as unknown rather
    /// than guessed at.
    static func softwareState(_ value: UInt64) -> SoftwareUpdateState {
        switch value {
        case 1, 15: return .available // DOWNLOAD_READY, UPDATE_AVAILABLE
        case 2: return .downloading   // DOWNLOAD_STARTED
        case 3: return .downloaded    // DOWNLOAD_COMPLETED
        case 4: return .failed        // DOWNLOAD_FAILED
        case 5, 6: return .installing // INSTALLATION_INITIATED, INSTALLATION_STARTED
        case 7, 8, 11: return .failed // ABORTED, FAILED, FAILED_CRITICAL
        case 9: return .completed     // INSTALLATION_COMPLETED
        case 10: return .deferred     // INSTALLATION_DEFERRED
        case 12: return .scheduled    // INSTALLATION_SCHEDULED
        case 13: return .installing   // INSTALLATION_SCHEDULE_TRIGGERED
        default: return .unknown      // 0 UNKNOWN, 14 INSTALLATION_UNKNOWN
        }
    }

    /// Parses a `pccs.chronos.messages.error.v1.GetErrorsResponse`:
    /// `1 id`, `2 vin`, oneof serviceError { `3 ampLimitError{1 error}`, `4 chargeLocationError{1 error, 2 action}`,
    /// `5 chargeNowError{1 error, 2 action}`, `6 globalChargeTimerError{1 error}`, `7 parkingClimateTimerError{1 error, 2 action}`,
    /// `8 targetSocError{1 error}` }.
    /// The oneof is identified by which field number is present (3-8). Each sub-error's
    /// field 1 is an `Error` enum int; field 2 (where present) is an `Action` enum int.
    static func parseErrors(_ data: Data) -> [VehicleChronosError] {
        let fields = Protobuf.fields(data)
        var errors: [VehicleChronosError] = []

        let serviceMap: [(field: Int, service: VehicleChronosError.Service)] = [
            (3, .ampLimit), (4, .chargeLocation), (5, .chargeNow),
            (6, .globalChargeTimer), (7, .parkingClimateTimer), (8, .targetSoc),
        ]
        for (fieldNum, service) in serviceMap {
            guard let errorData = message(fields, field: fieldNum) else { continue }
            let subFields = Protobuf.fields(errorData)
            let errorCodeInt = Int(varint(subFields, 1) ?? 0)
            let errorCode = VehicleChronosError.Code(rawValue: errorCodeInt) ?? .unknown
            let actionCode = subFields.first(where: { $0.number == 2 && $0.wire == 0 }).map { Int($0.varint) }
            errors.append(VehicleChronosError(service: service, errorCode: errorCode,
                                               actionCode: actionCode))
        }
        return errors
    }

    /// Parses a `GetMyCarsResponse`: `{1: [MyCar]}` where `MyCar` = `{1: Car, 2: userIsLinked,
    /// 3: userIsOwner, 4: registrationPlate}`. Extracts the `Car` matching the VIN and reads
    /// the OTA + capability fields. The `Car` proto uses nested capability messages:
    /// `36: Locks{5: supportsWindowControl, 6: supportsSunroofControl, 7: supportsTrunkControl,
    ///  10: supportsTrunkUnlock}`, `35: Charging{1: supportsChargingFunctions, 9: amperageLimitSettings,
    ///  8: targetChargeLevelSettings, 15: supportsChargeNow, 29: supportsPlugAndCharge}`,
    /// `34: AirPurification{1: supportsRemoteStart}`, `16: honkFlashType (enum)`.
    static func parseMyCars(_ data: Data, vin: String) -> VehicleOTACapabilities? {
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
            // Field 16: honkFlashType (enum): 0=UNSPECIFIED, 2=NONE, 3=HONK_AND_FLASH,
            // 4=HONK_AND_OR_FLASH, 5=HONK, 6=FLASH
            let honkFlashType = varint(car, 16) ?? 0
            let supportsHonkAndFlash = honkFlashType == 3 || honkFlashType == 4
            let supportsFlash = honkFlashType == 4 || honkFlashType == 6

            // Nested Locks message (field 36)
            let locksData = message(car, field: 36).map(Protobuf.fields)
            let supportsWindowsControl = locksData?.first(where: { $0.number == 5 })?.varint == 1
            let supportsTrunkControl = locksData?.first(where: { $0.number == 7 })?.varint == 1
            let supportsTrunkUnlock = locksData?.first(where: { $0.number == 10 })?.varint == 1

            // Nested Charging message (field 35)
            let chargingData = message(car, field: 35).map(Protobuf.fields)
            let supportsChargingFunctions = chargingData?.first(where: { $0.number == 1 })?.varint == 1
            let supportsGlobalChargeAmperageLimit = chargingData?.first(where: { $0.number == 9 })?.varint == 1
            let supportsTargetChargeLevel = chargingData?.first(where: { $0.number == 8 })?.varint == 1
            let supportsChargeNowTimerOverride = chargingData?.first(where: { $0.number == 15 })?.varint == 1
            let supportsPlugAndCharge = chargingData?.first(where: { $0.number == 29 })?.varint == 1

            // Nested AirPurification message (field 34)
            let airData = message(car, field: 34).map(Protobuf.fields)
            let supportsAirPurificationRemoteStart = airData?.first(where: { $0.number == 1 })?.varint == 1

            return VehicleOTACapabilities(
                installedSoftwareVersion: installedVersion,
                supportsFullOtaUpdates: supportsFullOtaUpdates,
                supportsRemoteOtaInstallSchedule: supportsRemoteOtaInstallSchedule,
                supportsCloudBasedOtaDownloadConsent: supportsCloudBasedOtaDownloadConsent,
                supportsUpdateStatus: supportsUpdateStatus,
                hasPerformanceSoftwareUpgrade: hasPerformanceSoftwareUpgrade,
                supportsTrunkControl: supportsTrunkControl,
                supportsTrunkUnlock: supportsTrunkUnlock,
                supportsHonkAndFlash: supportsHonkAndFlash,
                supportsFlash: supportsFlash,
                supportsChargingFunctions: supportsChargingFunctions,
                supportsGlobalChargeAmperageLimit: supportsGlobalChargeAmperageLimit,
                supportsTargetChargeLevel: supportsTargetChargeLevel,
                supportsChargeNowTimerOverride: supportsChargeNowTimerOverride,
                supportsWindowsControl: supportsWindowsControl,
                supportsAirPurificationRemoteStart: supportsAirPurificationRemoteStart,
                supportsPlugAndCharge: supportsPlugAndCharge
            )
        }
        return nil
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
        let driverSeat = varint(fields, 10).flatMap { $0 > 0 ? Int($0) : nil }
        let passengerSeat = varint(fields, 11).flatMap { $0 > 0 ? Int($0) : nil }
        let steeringWheel = varint(fields, 12).flatMap { $0 > 0 ? Int($0) : nil }
        let activity: ClimateActivity
        if digitalTwin {


            let active = running == 1
            let starting = running == 3
            if active || starting {
                if (varint(fields, 6) ?? 0) != 0 {
                    activity = .ventilating
                } else if let current = interiorTemperature, let requested = requestedTemperature,
                          requested != current {
                    activity = requested > current ? .heating : .cooling
                } else {
                    activity = active ? .active : .starting
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
        return VehicleClimateStatus(activity: activity, timeRemainingMinutes: remaining,
                                    timerTriggered: timerTriggered,
                                    interiorTemperatureCelsius: interiorTemperature,
                                    requestedTemperatureCelsius: requestedTemperature,
                                    driverSeatHeatingLevel: driverSeat,
                                    passengerSeatHeatingLevel: passengerSeat,
                                    steeringWheelHeatingLevel: steeringWheel)
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
                                         index: Int(varint(values, 2) ?? 0),
                                         kind: .climate, startHour: time.0, startMinute: time.1,
                                         endHour: nil, endMinute: nil,
                                         weekdays: weekdays(message(values, field: 6)),
                                         isActive: varint(values, 4) == 1)
        }
        return timers.keys.sorted().compactMap { timers[$0] }
    }


    static func parseLocation(_ data: Data) -> VehicleLocation? {
        let fields = Protobuf.fields(data)

        var lon: Double?
        var lat: Double?
        var tsMillis: UInt64?

        if let f1 = fields.first(where: { $0.number == 1 }), f1.wire == 1 || f1.wire == 5 {
            lon = numeric(fields, 1)
            lat = numeric(fields, 2)
            if let tsMsg = message(fields, field: 3) {
                let tsFields = Protobuf.fields(tsMsg)
                if let sec = varint(tsFields, 1) {
                    tsMillis = sec * 1_000 + (varint(tsFields, 2) ?? 0) / 1_000_000
                }
            } else {
                tsMillis = varint(fields, 3)
            }
        } else {
            lon = numeric(fields, 2)
            lat = numeric(fields, 3)
            tsMillis = varint(fields, 4)
        }

        if (lat == nil || lon == nil), let subData = message(fields, field: 5) ?? message(fields, field: 1) ?? message(fields, field: 3) {
            let subFields = Protobuf.fields(subData)
            lon = lon ?? numeric(subFields, 1) ?? numeric(subFields, 2)
            lat = lat ?? numeric(subFields, 2) ?? numeric(subFields, 3)
            if tsMillis == nil {
                if let tsSub = message(subFields, field: 3) {
                    let tsFields = Protobuf.fields(tsSub)
                    if let sec = varint(tsFields, 1) {
                        tsMillis = sec * 1_000 + (varint(tsFields, 2) ?? 0) / 1_000_000
                    }
                } else {
                    tsMillis = varint(subFields, 3) ?? varint(subFields, 4)
                }
            }
        }

        if lat == nil && lon == nil {
            lon = numeric(fields, 1)
            lat = numeric(fields, 2)
        }

        if let rawLat = lat, abs(rawLat) > 180 {
            lat = rawLat > 1_000_000_000 ? rawLat / 10_000_000.0 : (rawLat > 100_000 ? rawLat / 1_000_000.0 : rawLat)
        }
        if let rawLon = lon, abs(rawLon) > 180 {
            lon = rawLon > 1_000_000_000 ? rawLon / 10_000_000.0 : (rawLon > 100_000 ? rawLon / 1_000_000.0 : rawLon)
        }

        guard let validLat = lat, let validLon = lon, (abs(validLat) > 0.0001 || abs(validLon) > 0.0001) else {
            return nil
        }

        let heading = [numeric(fields, 4), numeric(fields, 6), numeric(fields, 7), numeric(fields, 8)]
            .compactMap { $0 }
            .first(where: { val in
                guard val >= 0 && val <= 360 else { return false }
                if let ts = tsMillis, ts > 10_000_000 {
                    return abs(val - Double(ts)) > 1000
                }
                return true
            })
        let speed = [numeric(fields, 5), numeric(fields, 7), numeric(fields, 8), numeric(fields, 9)]
            .compactMap { $0 }
            .first(where: { $0 >= 0 && $0 <= 300 })
        let date = tsMillis.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0) / 1_000) : nil }
        let altitude = numeric(fields, 6) ?? numeric(fields, 8)
        let accuracy = numeric(fields, 7) ?? numeric(fields, 9)
        let parkingBrake = varint(fields, 8).map { $0 != 0 } ?? varint(fields, 10).map { $0 != 0 }
        let gear: String? = {
            guard let g = varint(fields, 9) ?? varint(fields, 11) else { return nil }
            switch g {
            case 1: return "P"
            case 2: return "R"
            case 3: return "N"
            case 4: return "D"
            default: return nil
            }
        }()

        return VehicleLocation(
            latitude: validLat,
            longitude: validLon,
            heading: heading,
            speed: speed,
            timestamp: date,
            altitudeMeters: altitude,
            accuracyMeters: accuracy,
            parkingBrakeEngaged: parkingBrake,
            gear: gear
        )
    }


    static func parseWeather(_ data: Data) -> VehicleWeather? {
        let fields = Protobuf.fields(data)
        let subData = message(fields, field: 1) ?? data
        let subFields = Protobuf.fields(subData)

        let millis = varint(subFields, 1).flatMap { $0 > 0 ? $0 : nil }
        let timestamp = millis.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
        let temp = numeric(subFields, 2)
        let code = varint(subFields, 3).map(Int.init)
        let condition = code.map(Self.wmoWeatherDescription)

        guard timestamp != nil || temp != nil else { return nil }
        return VehicleWeather(temperatureCelsius: temp, condition: condition, timestamp: timestamp)
    }


    private static func vehicleRequest(_ vin: String) -> Data {
        var data = Data()
        data.append(Protobuf.stringField(1, UUID().uuidString))
        data.append(Protobuf.stringField(2, vin))
        return data
    }

    private static func healthRequest(_ vin: String) -> Data { Protobuf.stringField(2, vin) }

    private static func chronosRequest(_ vin: String) -> Data {
        var chronos = Data()
        chronos.append(Protobuf.stringField(1, UUID().uuidString))
        chronos.append(Protobuf.stringField(2, vin))
        chronos.append(Protobuf.stringField(3, "RCS"))
        chronos.append(Protobuf.messageField(4, Protobuf.intField(1, TimeZone.current.secondsFromGMT() / 60)))
        return Protobuf.messageField(1, chronos)
    }

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
    private static func tyreWarning(_ value: UInt64?) -> TyrePressureWarning {
        switch value { case 1: return .none; case 2: return .veryLow; case 3: return .low; case 4: return .high; default: return .unknown }
    }

    /// Finds four consecutive numeric fields inside `window` whose values all sit in the
    /// plausible kPa band. Returns the field numbers in ascending order, or nil. A single
    /// stray value can never qualify — all four neighbours must agree, which is what makes
    /// this safe to run against an undocumented layout.
    static func discoverPressureQuadruple(
        _ fields: [Protobuf.Field], window: ClosedRange<Int>
    ) -> [Int]? {
        let numericFields: [Int: Double] = {
            var map: [Int: Double] = [:]
            for field in fields where window.contains(field.number)
                && (field.wire == 0 || field.wire == 1 || field.wire == 5) {
                // Last one wins on repeated field numbers; protobuf decoders commonly take
                // the final occurrence for scalar fields.
                if let value = numeric(fields, field.number) { map[field.number] = value }
            }
            return map
        }()
        var run: [Int] = []
        for number in window.lowerBound...window.upperBound {
            if let value = numericFields[number], value >= 150, value <= 400 {
                run.append(number)
                if run.count == 4 { return run }
            } else {
                run.removeAll()
            }
        }
        return nil
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
        return packedVarints(data).compactMap { VehicleWeekday(rawValue: Int($0)) }
    }
    private static func packedVarints(_ data: Data) -> [UInt64] {
        var result: [UInt64] = []
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            var value: UInt64 = 0, shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]; index += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { result.append(value); break }
                shift += 7
            }
        }
        return result
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
