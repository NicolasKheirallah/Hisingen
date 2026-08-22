import Foundation

extension PolestarGRPC {
    // C3, not PCCS. `pccs.invocation.v1.InvocationService` exists but answers every write
    // with `Unauthenticated: Access denied` regardless of client; the C3 service accepts them.
    private static let invocationService = "/invocation.InvocationService"
    private static let targetSOCService = "/pccs.chronos.services.v1.TargetSocService"
    private static let ampLimitService = "/pccs.chronos.services.v1.AmpLimitService"
    private static let chargeNowService = "/pccs.chronos.services.v1.ChargeNowService"
    private static let chargeTimerService = "/pccs.chronos.services.v2.GlobalChargeTimerService"
    private static let climateTimerService = "/pccs.chronos.services.v1.ParkingClimateTimerService"
    private static let otaSchedulerService = "/ota_mobcache.SchedulerService"

    func executeRemoteCommand(_ command: RemoteCommand, vin: String,
                              accessToken: String,
                              commandToken: String? = nil) async throws -> RemoteCommandResult {
        // Invocation-backed commands are gated on a client-id allowlist that the primary
        // (web) client is not on, so they need the command client's token (`lp8dyrd_10`). Everything else
        // — OTA and chronos — is happy with the primary token.
        let isInvocation = isInvocationCommand(command)
        if isInvocation && commandToken == nil {
            throw RemoteCommandError.rejected(
                L10n.text("Remote commands aren't authorized yet. Open Settings → Remote Controls and choose \"Authorize Remote Commands.\"")
            )
        }
        self.activeCommandToken = commandToken ?? accessToken
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
        case .lockReducedGuard:
            throw RemoteCommandError.unsupported
        case .unlock:
            return try await invocation(method: "Unlock", request: Self.unlockRequest(vin, trunkOnly: false),
                                        vin: vin, token: accessToken)
        case .unlockTrunk:
            return try await invocation(method: "Unlock", request: Self.unlockRequest(vin, trunkOnly: true),
                                         vin: vin, token: accessToken)
        case .openTailgate:
            return try await invocation(method: "TailgateControl",
                                        request: Self.tailgateRequest(vin, open: true),
                                        vin: vin, token: accessToken)
        case .closeTailgate:
            return try await invocation(method: "TailgateControl",
                                        request: Self.tailgateRequest(vin, open: false),
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
            //  uses ChargeTargetLevelSettingType.CUSTOM (3), not DAILY (1).
            // DAILY is accepted by the backend (returns SYNCED) but doesn't actually change
            // the target SOC — it's a preset type, not an override. CUSTOM (3) is the
            // setting type that actually applies the requested target level.
            payload.append(Protobuf.intField(3, 3))  // CUSTOM
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
            return try Self.chronosResult(body, statusField: 3)
        case .startChargingOverride, .stopChargingOverride:
            let method = command == .startChargingOverride
                ? "StartOverrideChargeTimer" : "StopOverrideChargeTimer"
            let body = try await lastMessage(path: Self.chargeNowService + "/\(method)",
                                             message: Self.chronosRequest(vin), vin: vin,
                                             accessToken: accessToken, host: .pccs)
            if let status = Protobuf.fields(body).first(where: { $0.number == 1 && $0.wire == 0 })?.varint, status > 0 {
                return RemoteCommandResult(outcome: .accepted, message: nil)
            }
            return try Self.chronosResult(body, statusField: 3)
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
            // `relative_time` is in MINUTES, and the backend enforces 2…10080 (7 days) —
            // verified live, which answers it with
            // `grpc-status 3: relativeTime should be between 2 to 10080!`.
            // This previously sent `minutes * 60`, so every schedule request was rejected as
            // out of range once the delay exceeded ~2.8 hours, and was silently wrong below it.
            guard Self.otaScheduleMinutes.contains(minutes) else {
                throw RemoteCommandError.rejected(
                    L10n.format("A software installation can only be scheduled between %d minutes and %d days from now.",
                                Self.otaScheduleMinutes.lowerBound, Self.otaScheduleMinutes.upperBound / 1_440)
                )
            }
            let softwareID = try await softwareID(vin: vin, accessToken: accessToken,
                                                 requiringInstallable: true)
            var request = Data()
            request.append(Protobuf.stringField(1, vin))
            request.append(Protobuf.intField(2, minutes))
            request.append(Protobuf.stringField(3, softwareID))
            return try await ota(method: "Schedule", request: request, vin: vin, token: accessToken)
        case .installOTANow:
            let softwareID = try await softwareID(vin: vin, accessToken: accessToken,
                                                 requiringInstallable: true)
            var request = Data()
            request.append(Protobuf.stringField(1, vin))
            request.append(Protobuf.stringField(2, softwareID))
            return try await ota(method: "InstallNow", request: request, vin: vin, token: accessToken)
        case .cancelOTA:
            let softwareID = try await softwareID(vin: vin, accessToken: accessToken)
            var request = Data()
            request.append(Protobuf.stringField(1, vin))
            request.append(Protobuf.stringField(2, softwareID))
            return try await ota(method: "CancelSchedule", request: request, vin: vin, token: accessToken)
        case .startEngine, .stopEngine:
            // Remote engine start is a Volvo ICE/PHEV command; Polestar's line-up is electric
            // and its backend exposes no equivalent RPC. Mirrors `isImplemented(by: .polestar)`.
            throw RemoteCommandError.unsupported
        }
    }

    /// Every OTA write is addressed to a specific `software_id`, which only ever arrives on a
    /// `GetSoftwareInfo`/`GetSchedule` read. The id is cached per VIN, but a command issued
    /// before the first successful software read — or after the app restarted — would otherwise
    /// fail with "missing context", so fetch it on demand instead of giving up.
    private func softwareID(vin: String, accessToken: String,
                            requiringInstallable: Bool = false) async throws -> String {
        // Always re-read before a write. A cached id can name a version the car has since
        // finished installing, and `InstallNow` on that is refused by the backend in HTTP/2
        // trailers URLSession cannot surface — which reaches the user as an unexplained
        // "unexpected response" rather than anything actionable.
        _ = try? await fetchSoftware(vin: vin, accessToken: accessToken, locale: "en")
        guard let resolved = otaSoftwareIDs[vin], !resolved.isEmpty else {
            throw RemoteCommandError.missingContext
        }
        if requiringInstallable {
            // Prefer the precise raw state (preserves 15 vs 1) when available; fall back to
            // the coarse state for older cached entries. `SoftwareStateRaw.isInstallable`
            // encodes the exact installability rule; the coarse set is the equivalent.
            if let raw = otaRawSoftwareStates[vin] {
                guard raw.isInstallable else {
                    throw RemoteCommandError.rejected(Self.notInstallableMessage(raw.coarseState, rawState: raw))
                }
            } else {
                let state = otaSoftwareStates[vin] ?? .unknown
                guard Self.installableStates.contains(state) else {
                    throw RemoteCommandError.rejected(Self.notInstallableMessage(state, rawState: nil))
                }
            }
        }
        return resolved
    }

    /// Bounds the C3 scheduler enforces on `relative_time`, in minutes.
    static let otaScheduleMinutes = 2...10_080

    /// States in which the scheduler will accept an install or a schedule.
    ///
    /// `available` is deliberately excluded. Verified live: a Polestar 2 advertising an update
    /// in state 15 answers both `Schedule` and `InstallNow` with
    /// `grpc-status 3: The software with software id <id> is not ready to be scheduled!`
    /// — "available" means the update has been *offered*, not that the car has downloaded it.
    /// Only once the download completes does the scheduler accept a request.
    private static let installableStates: Set<SoftwareUpdateState> = [
        .downloaded, .deferred, .scheduled
    ]

    private static func notInstallableMessage(_ state: SoftwareUpdateState, rawState: SoftwareStateRaw?) -> String {
        // When we know the precise raw state, give a more specific message for 15 vs 1.
        if let raw = rawState {
            switch raw {
            case .updateAvailable:
                return L10n.text("This update has been announced but not yet authorized for download. The vehicle downloads it on its own once the backend authorizes it and conditions allow; installation can only be started afterwards.")
            case .downloadReady:
                return L10n.text("The update is ready to download but has not been downloaded yet. The vehicle will download it automatically; installation can only be started once the download completes.")
            case .downloadStarted:
                return L10n.text("The update is still downloading to the vehicle. Try again once it has finished.")
            case .downloadFailed:
                return L10n.text("The download failed. The vehicle will retry automatically; installation can only be started once the download completes.")
            default:
                break
            }
        }
        switch state {
        case .available:
            return L10n.text("This update has been offered to the vehicle but not downloaded yet. The car downloads it on its own once conditions allow; installation can only be started afterwards.")
        case .downloading:
            return L10n.text("The update is still downloading to the vehicle. Try again once it has finished.")
        case .installing:
            return L10n.text("The vehicle is already installing this update.")
        case .failed:
            return L10n.text("The last update attempt failed, and the vehicle has not made it available to install again.")
        case .completed, .unknown:
            return L10n.text("There is no software update waiting to be installed on this vehicle.")
        default:
            return L10n.text("The vehicle cannot install a software update right now.")
        }
    }

    private func invocation(method: String, request: Data, vin: String,
                            token: String) async throws -> RemoteCommandResult {
        let body = try await lastMessage(path: Self.invocationService + "/\(method)",
                                         message: request, vin: vin,
                                         accessToken: activeCommandToken ?? token, host: .c3)
        return try Self.parseInvocationResult(body)
    }

    /// All three scheduler writes answer with the same `Scheduler` message
    /// (`1 status, 2 relative_time, 3 scheduled_time, 4 software_id, 5 set_by`), where
    /// `status` is 0 UNKNOWN, 1 IDLE, 2 SCHEDULED, 3 INSTALL.
    private func ota(method: String, request: Data, vin: String,
                     token: String) async throws -> RemoteCommandResult {
        let body = try await lastMessage(path: Self.otaSchedulerService + "/\(method)",
                                         message: request, vin: vin, accessToken: token, host: .c3)
        guard let scheduler = Self.message(body, field: 1),
              let status = Self.varint(scheduler, field: 1), status > 0 else {
            throw RemoteCommandError.rejected(nil)
        }
        let returnedID = Self.string(scheduler, field: 4)
        if !returnedID.isEmpty { otaSoftwareIDs[vin] = returnedID }
        switch status {
        case 3: return RemoteCommandResult(outcome: .delivered, message: nil)   // INSTALL
        case 2: return RemoteCommandResult(outcome: .completed, message: nil)   // SCHEDULED
        default: return RemoteCommandResult(outcome: .completed, message: nil)  // IDLE (cancelled)
        }
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
    /// `TailgateControlRequest`: `{1: request (InvocationRequest), 2: tailgateControl (TailgateControlType)}`.
    /// `TailgateControlType`: 0=UNSPECIFIED, 1=OPEN_TAILGATE, 2=CLOSE_TAILGATE.
    static func tailgateRequest(_ vin: String, open: Bool) -> Data {
        var request = invocationOnlyRequest(vin)
        request.append(Protobuf.intField(2, open ? 1 : 2))
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
    static func chronosResult(_ data: Data, statusField: Int) throws -> RemoteCommandResult {
        let status = varint(data, field: statusField) ?? 0
        switch status {
        case 1: return RemoteCommandResult(outcome: .accepted, message: nil)
        case 2: return RemoteCommandResult(outcome: .delivered, message: nil)
        case 3, 4, 8: return RemoteCommandResult(outcome: .completed, message: nil)
        case 0: throw RemoteCommandError.rejected(L10n.text("The vehicle service reported an unknown error."))
        case 5: throw RemoteCommandError.rejected(L10n.text("The vehicle is offline. Try again when it wakes up."))
        case 6: throw RemoteCommandError.rejected(L10n.text("The vehicle reported an error processing this command."))
        case 7: throw RemoteCommandError.rejected(L10n.text("The command failed. Please try again."))
        default: throw RemoteCommandError.rejected(nil)
        }
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
    private func isInvocationCommand(_ command: RemoteCommand) -> Bool {
        switch command {
        case .startClimate, .stopClimate, .startPreCleaning, .stopPreCleaning,
             .lock, .unlock, .unlockTrunk, .openTailgate, .closeTailgate,
             .openWindows, .closeWindows,
             .flashLights, .honkAndFlash, .honkHorn:
            return true
        default:
            return false
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

