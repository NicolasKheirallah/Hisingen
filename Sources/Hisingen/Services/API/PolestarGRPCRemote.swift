import Foundation

extension PolestarGRPC {
    private static let invocationService = "/invocation.InvocationService"
    private static let targetSOCService = "/chronos.services.v1.TargetSocService"
    private static let ampLimitService = "/chronos.services.v1.AmpLimitService"
    private static let chargeNowService = "/chronos.services.v1.ChargeNowService"
    private static let chargeTimerService = "/chronos.services.v2.GlobalChargeTimerService"
    private static let climateTimerService = "/chronos.services.v1.ParkingClimateTimerService"
    private static let otaSchedulerService = "/ota_mobcache.SchedulerService"

    func executeRemoteCommand(_ command: RemoteCommand, vin: String,
                              accessToken: String) async throws -> RemoteCommandResult {
        switch command {
        case .startClimate(let temperature, let frontLeft, let frontRight,
                           let rearLeft, let rearRight, let steeringWheel):
            guard temperature == 0 || ((16...30).contains(temperature) && (temperature * 2).rounded() == temperature * 2) else {
                throw RemoteCommandError.rejected(nil)
            }
            return try await invocation(
                method: "ClimatizationStart",
                request: Self.climateStartRequest(vin: vin, temperature: temperature,
                                                  frontLeft: frontLeft, frontRight: frontRight,
                                                  rearLeft: rearLeft, rearRight: rearRight,
                                                  steeringWheel: steeringWheel),
                vin: vin, token: accessToken
            )
        case .stopClimate:
            return try await invocation(method: "ClimatizationStop",
                                        request: Self.invocationOnlyRequest(vin), vin: vin, token: accessToken)
        case .startPreCleaning:
            return try await invocation(method: "PreCleaning",
                                        request: Self.preCleaningRequest(vin: vin, start: true),
                                        vin: vin, token: accessToken)
        case .stopPreCleaning:
            return try await invocation(method: "PreCleaning",
                                        request: Self.preCleaningRequest(vin: vin, start: false),
                                        vin: vin, token: accessToken)
        case .lock:
            return try await invocation(method: "Lock", request: Self.lockRequest(vin),
                                        vin: vin, token: accessToken)
        case .unlock:
            return try await invocation(method: "Unlock", request: Self.unlockRequest(vin, trunkOnly: false),
                                        vin: vin, token: accessToken)
        case .unlockTrunk:
            return try await invocation(method: "Unlock", request: Self.unlockRequest(vin, trunkOnly: true),
                                        vin: vin, token: accessToken)
        case .openWindows:
            return try await invocation(method: "WindowControl", request: Self.windowRequest(vin, action: 1),
                                        vin: vin, token: accessToken)
        case .closeWindows:
            return try await invocation(method: "WindowControl", request: Self.windowRequest(vin, action: 2),
                                        vin: vin, token: accessToken)
        case .flashLights:
            return try await invocation(method: "HonkFlash", request: Self.honkFlashRequest(vin, action: 2),
                                        vin: vin, token: accessToken)
        case .honkAndFlash:
            return try await invocation(method: "HonkFlash", request: Self.honkFlashRequest(vin, action: 0),
                                        vin: vin, token: accessToken)
        case .honkHorn:
            return try await invocation(method: "HonkFlash", request: Self.honkFlashRequest(vin, action: 1),
                                        vin: vin, token: accessToken)
        case .setChargeTarget(let target):
            guard (40...100).contains(target) else { throw RemoteCommandError.rejected(nil) }
            var payload = Data()
            payload.append(Protobuf.intField(2, target))
            payload.append(Protobuf.intField(3, 1))
            let body = try await lastMessage(path: Self.targetSOCService + "/SetTargetSoc",
                                             message: Self.chronosRequest(vin, payload: payload),
                                             vin: vin, accessToken: accessToken, host: .pccs)
            return try Self.chronosResult(body, statusField: 3)
        case .setAmpLimit(let amps):
            guard (1...64).contains(amps) else { throw RemoteCommandError.rejected(nil) }
            let payload = Protobuf.intField(2, amps)
            let body = try await lastMessage(path: Self.ampLimitService + "/SetAmpLimit",
                                             message: Self.chronosRequest(vin, payload: payload),
                                             vin: vin, accessToken: accessToken, host: .pccs)
            guard let response = Self.message(body, field: 3),
                  Self.varint(response, field: 1) == UInt64(amps) else {
                throw RemoteCommandError.rejected(nil)
            }
            return RemoteCommandResult(outcome: .completed, message: nil)
        case .startChargingOverride, .stopChargingOverride:
            let method = command == .startChargingOverride
                ? "StartOverrideChargeTimer" : "StopOverrideChargeTimer"
            let body = try await lastMessage(path: Self.chargeNowService + "/\(method)",
                                             message: Self.chronosRequest(vin), vin: vin,
                                             accessToken: accessToken, host: .pccs)
            guard let response = Self.message(body, field: 3),
                  let status = Self.varint(response, field: 1), status > 0 else {
                throw RemoteCommandError.rejected(nil)
            }
            return RemoteCommandResult(outcome: .accepted, message: nil)
        case .setGlobalChargeTimer(let schedule):
            let timer = try Self.globalChargeTimer(schedule)
            var payload = Data()
            payload.append(Protobuf.messageField(2, timer))
            payload.append(Protobuf.intField(3, 0))
            let body = try await lastMessage(path: Self.chargeTimerService + "/SetGlobalChargeTimer",
                                             message: Self.chronosRequest(vin, payload: payload),
                                             vin: vin, accessToken: accessToken, host: .pccs)
            return try Self.chronosResult(body, statusField: 2)
        case .setClimateTimer(let schedule):
            let timer = try Self.climateTimer(schedule)
            let payload = Protobuf.messageField(2, timer)
            let body = try await lastMessage(path: Self.climateTimerService + "/SetTimers",
                                             message: Self.chronosRequest(vin, payload: payload),
                                             vin: vin, accessToken: accessToken, host: .pccs)
            return try Self.chronosResult(body, statusField: 3)
        case .deleteClimateTimer(let id):
            guard !id.isEmpty else { throw RemoteCommandError.missingContext }
            let body = try await lastMessage(path: Self.climateTimerService + "/DeleteTimer",
                                             message: Self.chronosRequest(vin,
                                                 payload: Protobuf.stringField(2, id)),
                                             vin: vin, accessToken: accessToken, host: .pccs)
            guard let status = Self.varint(body, field: 1), status > 0 else {
                throw RemoteCommandError.rejected(nil)
            }
            return RemoteCommandResult(outcome: .completed, message: nil)
        case .scheduleOTA(let minutes):
            guard (1...1_440).contains(minutes), let softwareID = otaSoftwareIDs[vin] else {
                throw RemoteCommandError.missingContext
            }
            var request = Data()
            request.append(Protobuf.stringField(1, vin))
            request.append(Protobuf.intField(2, minutes * 60))
            request.append(Protobuf.stringField(3, softwareID))
            return try await ota(method: "Schedule", request: request, vin: vin, token: accessToken)
        case .installOTANow:
            guard let softwareID = otaSoftwareIDs[vin] else { throw RemoteCommandError.missingContext }
            var request = Data()
            request.append(Protobuf.stringField(1, vin))
            request.append(Protobuf.stringField(2, softwareID))
            return try await ota(method: "InstallNow", request: request, vin: vin, token: accessToken)
        case .cancelOTA:
            guard let softwareID = otaSoftwareIDs[vin] else { throw RemoteCommandError.missingContext }
            var request = Data()
            request.append(Protobuf.stringField(1, vin))
            request.append(Protobuf.stringField(2, softwareID))
            return try await ota(method: "CancelSchedule", request: request, vin: vin, token: accessToken)
        }
    }

    private func invocation(method: String, request: Data, vin: String,
                            token: String) async throws -> RemoteCommandResult {
        let body = try await lastMessage(path: Self.invocationService + "/\(method)",
                                         message: request, vin: vin, accessToken: token, host: .pccs)
        return try Self.parseInvocationResult(body)
    }

    private func ota(method: String, request: Data, vin: String,
                     token: String) async throws -> RemoteCommandResult {
        let body = try await lastMessage(path: Self.otaSchedulerService + "/\(method)",
                                         message: request, vin: vin, accessToken: token, host: .c3)
        guard let scheduler = Self.message(body, field: 1),
              let status = Self.varint(scheduler, field: 1), status > 0 else {
            throw RemoteCommandError.rejected(nil)
        }
        return RemoteCommandResult(outcome: status == 3 ? .delivered : .accepted, message: nil)
    }

    static func parseInvocationResult(_ data: Data) throws -> RemoteCommandResult {
        let nested = message(data, field: 1)
        let response = nested.flatMap { varint($0, field: 3) == nil ? nil : $0 } ?? data
        let status = varint(response, field: 3) ?? 0
        let messageText = string(response, field: 4)
        switch status {
        case 1:
            return RemoteCommandResult(outcome: .accepted, message: messageText.nilIfEmpty)
        case 4:
            return RemoteCommandResult(outcome: .delivered, message: messageText.nilIfEmpty)
        case 6:
            return RemoteCommandResult(outcome: .completed, message: messageText.nilIfEmpty)
        case 9:
            throw RemoteCommandError.rejected(L10n.text("The vehicle's privacy setting prevented this command."))
        case 10:
            throw RemoteCommandError.rejected(L10n.text("The vehicle is in a mode that prevents this command."))
        case 12:
            throw RemoteCommandError.rejected(L10n.text("Another vehicle command conflicts with this request."))
        default:
            throw RemoteCommandError.rejected(messageText.nilIfEmpty)
        }
    }

    static func climateStartRequest(vin: String, temperature: Float,
                                    frontLeft: HeatingLevel, frontRight: HeatingLevel,
                                    rearLeft: HeatingLevel, rearRight: HeatingLevel,
                                    steeringWheel: HeatingLevel) -> Data {
        var request = invocationOnlyRequest(vin)
        request.append(Protobuf.intField(2, 1))


        if temperature > 0 { request.append(Protobuf.floatField(3, temperature)) }
        if frontRight != .unspecified { request.append(Protobuf.intField(4, frontRight.rawValue)) }
        if frontLeft != .unspecified { request.append(Protobuf.intField(5, frontLeft.rawValue)) }
        if rearRight != .unspecified { request.append(Protobuf.intField(6, rearRight.rawValue)) }
        if rearLeft != .unspecified { request.append(Protobuf.intField(7, rearLeft.rawValue)) }
        if steeringWheel != .unspecified { request.append(Protobuf.intField(8, steeringWheel.rawValue)) }
        return request
    }

    static func globalChargeTimer(_ schedule: VehicleSchedule) throws -> Data {
        guard schedule.kind == .globalCharging,
              let startHour = schedule.startHour, let startMinute = schedule.startMinute,
              let endHour = schedule.endHour, let endMinute = schedule.endMinute,
              (0..<24).contains(startHour), (0..<60).contains(startMinute),
              (0..<24).contains(endHour), (0..<60).contains(endMinute) else {
            throw RemoteCommandError.rejected(nil)
        }
        var timer = Data()
        timer.append(Protobuf.messageField(1, dailyTime(hour: startHour, minute: startMinute)))
        timer.append(Protobuf.messageField(2, dailyTime(hour: endHour, minute: endMinute)))
        timer.append(Protobuf.intField(3, schedule.isActive ? 1 : 0))
        return timer
    }

    static func climateTimer(_ schedule: VehicleSchedule) throws -> Data {
        guard schedule.kind == .climate,
              let hour = schedule.startHour, let minute = schedule.startMinute,
              (0..<24).contains(hour), (0..<60).contains(minute) else {
            throw RemoteCommandError.rejected(nil)
        }
        var timer = Data()
        if let id = schedule.backendID, !id.isEmpty { timer.append(Protobuf.stringField(1, id)) }
        timer.append(Protobuf.intField(2, schedule.index ?? 0))
        timer.append(Protobuf.messageField(3, dailyTime(hour: hour, minute: minute)))
        timer.append(Protobuf.intField(4, schedule.isActive ? 1 : 0))
        timer.append(Protobuf.intField(5, schedule.weekdays.isEmpty ? 0 : 1))
        if !schedule.weekdays.isEmpty {
            timer.append(Protobuf.packedIntField(6, schedule.weekdays.map(\.rawValue)))
        }
        return timer
    }

    static func invocationRequest(_ vin: String) -> Data { Protobuf.stringField(1, vin) }
    static func invocationOnlyRequest(_ vin: String) -> Data {
        Protobuf.messageField(1, invocationRequest(vin))
    }
    static func preCleaningRequest(vin: String, start: Bool) -> Data {
        var request = invocationOnlyRequest(vin)
        request.append(Protobuf.intField(2, start ? 1 : 0))
        return request
    }
    static func lockRequest(_ vin: String) -> Data {
        var request = invocationOnlyRequest(vin)
        request.append(Protobuf.intField(2, 0))
        return request
    }
    static func unlockRequest(_ vin: String, trunkOnly: Bool = false) -> Data {
        var request = invocationOnlyRequest(vin)
        request.append(Protobuf.intField(2, trunkOnly ? 1 : 0))
        return request
    }
    static func windowRequest(_ vin: String, action: Int) -> Data {
        var request = invocationOnlyRequest(vin)
        request.append(Protobuf.intField(2, action))
        return request
    }
    static func honkFlashRequest(_ vin: String, action: Int) -> Data {
        var request = invocationOnlyRequest(vin)
        request.append(Protobuf.intField(2, action))
        return request
    }
    static func dailyTime(hour: Int, minute: Int) -> Data {
        var time = Data()
        time.append(Protobuf.intField(1, hour))
        time.append(Protobuf.intField(2, minute))
        time.append(Protobuf.messageField(3,
            Protobuf.intField(1, TimeZone.current.secondsFromGMT() / 60)))
        return time
    }
    static func chronosRequest(_ vin: String, payload: Data = Data()) -> Data {
        var envelope = Data()
        envelope.append(Protobuf.stringField(1, UUID().uuidString))
        envelope.append(Protobuf.stringField(2, vin))
        envelope.append(Protobuf.stringField(3, "RCS"))
        envelope.append(Protobuf.messageField(4,
            Protobuf.intField(1, TimeZone.current.secondsFromGMT() / 60)))
        var request = Protobuf.messageField(1, envelope)
        request.append(payload)
        return request
    }
    private static func chronosResult(_ data: Data, statusField: Int) throws -> RemoteCommandResult {
        let status = varint(data, field: statusField) ?? 0
        guard [1, 2, 3, 4, 8].contains(status) else { throw RemoteCommandError.rejected(nil) }
        let outcome: RemoteCommandOutcome = status == 1 ? .accepted : (status == 2 ? .delivered : .completed)
        return RemoteCommandResult(outcome: outcome, message: nil)
    }
    private static func message(_ data: Data, field: Int) -> Data? {
        Protobuf.fields(data).first(where: { $0.number == field && $0.wire == 2 })?.data
    }
    private static func varint(_ data: Data, field: Int) -> UInt64? {
        Protobuf.fields(data).first(where: { $0.number == field && $0.wire == 0 })?.varint
    }
    private static func string(_ data: Data, field: Int) -> String {
        guard let value = message(data, field: field) else { return "" }
        return String(data: value, encoding: .utf8) ?? ""
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}


