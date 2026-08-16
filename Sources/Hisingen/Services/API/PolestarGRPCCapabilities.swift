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

    func fetchExterior(vin: String, accessToken: String) async throws -> ExteriorSnapshot? {
        let body = try await firstMessage(path: Self.exteriorPath, message: Self.vehicleRequest(vin),
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
                info = parsed
            }
        } catch { firstError = error }

        // `Scheduler`: 1 status, 2 relative_time, 3 scheduled_time, 4 software_id, 5 set_by.
        // This is a second source of the software id — it stays populated for a scheduled
        // install even when GetSoftwareInfo has nothing to report, which is what makes
        // "cancel a scheduled installation" reachable.
        var scheduledAt: Date?
        do {
            let body = try await firstMessage(path: Self.softwareSchedulePath,
                                              message: Protobuf.stringField(1, vin),
                                              vin: vin, accessToken: accessToken)
            if let scheduler = Self.message(body, field: 1) {
                let fields = Protobuf.fields(scheduler)
                scheduledAt = Self.timestamp(Self.message(fields, field: 3))
                rememberSoftwareID(Self.string(fields, 4), vin: vin)
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
            return merged
        }
        if let scheduledAt {
            // A schedule exists but GetSoftwareInfo returned nothing, so the target version is
            // genuinely unknown here. Report the schedule and leave every version field nil
            // rather than inventing one.
            return VehicleSoftwareInfo(state: .scheduled, scheduledAt: scheduledAt)
        }
        if let firstError { throw firstError }
        return nil
    }

    private func rememberSoftwareID(_ id: String, vin: String) {
        guard !id.isEmpty else { return }
        otaSoftwareIDs[vin] = id
    }

    func fetchChargingSchedules(vin: String, accessToken: String) async throws -> [VehicleSchedule] {
        var schedules: [VehicleSchedule] = []
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

    func fetchAirQuality(vin: String, accessToken: String) async throws -> VehicleAirQuality? {
        let body = try await firstMessage(path: Self.preCleaningPath, message: Self.healthRequest(vin),
                                          vin: vin, accessToken: accessToken)
        guard let payload = Self.message(body, field: 3) else { return nil }
        let fields = Protobuf.fields(payload)
        let state: AirCleaningState
        switch Self.varint(fields, 6) {
        case 1: state = .on
        case 2: state = .off
        case 3: state = .pending
        default: state = .unknown
        }
        return VehicleAirQuality(
            cleaningState: state,
            airQualityIndex: Self.positiveInt(Self.varint(fields, 9)),
            particulateMatter25: Self.positiveInt(Self.varint(fields, 10)),
            particulateMatter10: Self.positiveInt(Self.varint(fields, 14)),
            externalParticulateMatter25: Self.positiveInt(Self.varint(fields, 15)),
            filterRemainingPercent: Self.positiveInt(Self.varint(fields, 16)),
            runtimeRemainingMinutes: Self.positiveInt(Self.varint(fields, 11)),
            hasError: (Self.varint(fields, 13) ?? 0) > 0
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
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current=temperature_2m,weather_code,relative_humidity_2m,apparent_temperature"
        guard let url = URL(string: urlString) else { return nil }
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
        let pressureFields = [39, 40, 41, 42]
        let positions = TyrePosition.allCases
        var tyres: [TyrePressure] = []
        for index in positions.indices {
            let warningRaw = varint(fields, warningFields[index])
            let warning = tyreWarning(warningRaw)
            let pressure = numeric(fields, pressureFields[index]).flatMap { $0 > 0 ? $0 : nil }
            let effectiveWarning: TyrePressureWarning = (warning == .unknown && warningRaw == nil) ? .none : warning
            tyres.append(TyrePressure(position: positions[index], kilopascals: pressure, warning: effectiveWarning))
        }
        var warnings: [VehicleWarning] = []
        if let value = varint(fields, 5), value > 1 { warnings.append(.service) }
        if let value = varint(fields, 6), value > 1 { warnings.append(.brakeFluid) }
        if let value = varint(fields, 7), value > 1 { warnings.append(.engineCoolant) }
        if let value = varint(fields, 8), value > 1 { warnings.append(.oil) }
        if let value = varint(fields, 13), value > 1 { warnings.append(.washerFluid) }
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
        if !lightFailures.isEmpty || (14...35).contains(where: { varint(fields, $0) == 2 }) {
            warnings.append(.exteriorLight)
        }
        if varint(fields, 38) == 2 { warnings.append(.lowVoltageBattery) }
        return GrpcHealthReport(
            details: VehicleHealthDetails(tyres: tyres, warnings: warnings, lightFailures: lightFailures),
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
    /// `6 new_sw_version`, `8 schedule_info{2 scheduled_at}`, `10 state_timestamp`.
    static func parseSoftware(_ data: Data) -> VehicleSoftwareInfo {
        let fields = Protobuf.fields(data)
        let description = message(fields, field: 2).map(Protobuf.fields)
        let state = softwareState(varint(fields, 4) ?? 0)
        let schedule = message(fields, field: 8).flatMap { message($0, field: 2) }
        let advertisedVersion = string(fields, 6).nilIfEmpty
        let parsedTitle = description.flatMap { string($0, 1).nilIfEmpty } ?? advertisedVersion

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
            scheduledAt: timestamp(schedule),
            updatedAt: timestamp(message(fields, field: 10)),
            installedVersion: describesInstalled ? advertisedVersion : nil,
            latestAvailableVersion: describesInstalled ? nil : advertisedVersion
        )
    }

    /// `ota_mobcache.SoftwareState`. The enum it mirrors runs 0…14; 15 is an extra value this
    /// backend has been observed emitting for an offered update (pinned by
    /// `testSoftwareVersionRepresentsAvailableUpdateNotInstalledVersion`). Anything else is
    /// reported as unknown rather than guessed at.
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
            tsMillis = varint(fields, 3)
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
            .first(where: { $0 >= 0 && $0 <= 360 && abs($0 - Double(tsMillis ?? 0)) > 1000 })
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


