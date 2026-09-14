import Foundation

/// Which display-only field of `VehicleState` a command's result owns. One column serves
/// two purposes: the optimistic patch writes the field, and presentation keeps the
/// optimistic value for any field whose command is still awaiting telemetry.
enum CommandDisplayField: Hashable, Sendable {
    case climateStatus
    case airQuality
    case exterior
    case chargeTarget
    case chargingCurrentLimit
    case chargingState
}

/// One row per Remote Command: what the command touches, and how the vehicle proves it
/// took effect. Written once; the optimistic patch (`CommandCoordinator`), telemetry
/// confirmation (`CommandReceipt`), presentation preservation (`RefreshCoordinator`), and
/// supersession all read the same row instead of re-encoding it per file.
struct CommandDescriptor: Sendable {
    /// Commands in one group describe a single desired end state; a newer command
    /// supersedes any older pending command in the same group, including its opposite verb.
    /// `nil` for commands that never conflict.
    let conflictGroup: String?
    /// The optimistic display field the command owns. `nil` when success is only visible
    /// through a later refresh.
    let displayField: CommandDisplayField?
    /// The telemetry reading that proves the command took effect. `nil` when the command
    /// has no telemetry confirmation path and provider acknowledgement is terminal.
    let proofReading: VehicleReading?
    /// Whether the proving reading currently shows the command's effect.
    let isProvenBy: @Sendable (VehicleState) -> Bool
    /// Patches display-only state to what a successful command should have produced so the
    /// UI flips immediately. Synthesized fields (an assumed 30-minute climate window) mean
    /// the patch must never be persisted. May be a no-op (e.g. Volvo unlock leaves exterior
    /// unpatched, matching the official app).
    let optimisticPatch: @Sendable (inout VehicleState, Date, VehicleBrand) -> Void

    init(
        conflictGroup: String? = nil,
        displayField: CommandDisplayField? = nil,
        proofReading: VehicleReading? = nil,
        isProvenBy: @escaping @Sendable (VehicleState) -> Bool = { _ in false },
        optimisticPatch: @escaping @Sendable (inout VehicleState, Date, VehicleBrand) -> Void = { _, _, _ in }
    ) {
        self.conflictGroup = conflictGroup
        self.displayField = displayField
        self.proofReading = proofReading
        self.isProvenBy = isProvenBy
        self.optimisticPatch = optimisticPatch
    }
}

extension RemoteCommand {
    var descriptor: CommandDescriptor {
        switch self {
        case .startClimate(let temperature, _, _, _, _, _):
            return CommandDescriptor(
                conflictGroup: "climate",
                displayField: .climateStatus,
                proofReading: .climateStatus,
                isProvenBy: { $0.isClimateActive },
                optimisticPatch: { state, _, _ in
                    state.climateStatus = VehicleClimateStatus(
                        activity: .heating,
                        timeRemainingMinutes: 30,
                        timerTriggered: false,
                        interiorTemperatureCelsius: state.climateStatus?.interiorTemperatureCelsius,
                        requestedTemperatureCelsius: Double(temperature > 0 ? temperature : 22.0)
                    )
                }
            )
        case .stopClimate:
            return CommandDescriptor(
                conflictGroup: "climate",
                displayField: .climateStatus,
                proofReading: .climateStatus,
                isProvenBy: { $0.climateStatus?.activity == .idle },
                optimisticPatch: { state, _, _ in
                    state.climateStatus = VehicleClimateStatus(
                        activity: .idle,
                        timeRemainingMinutes: nil,
                        timerTriggered: false,
                        interiorTemperatureCelsius: state.climateStatus?.interiorTemperatureCelsius,
                        requestedTemperatureCelsius: state.climateStatus?.requestedTemperatureCelsius
                    )
                }
            )
        case .startPreCleaning:
            return CommandDescriptor(
                conflictGroup: "precleaning",
                displayField: .airQuality,
                proofReading: .airQuality,
                isProvenBy: { $0.airQuality?.cleaningState == .on },
                optimisticPatch: { state, at, _ in
                    // Patch `airQuality`, not `climateStatus`; a synthesized climate session
                    // would surface a "Stop Climate" button that does not target pre-cleaning.
                    guard var air = state.airQuality else { return }
                    air = VehicleAirQuality(
                        cleaningState: .on,
                        airQualityIndex: air.airQualityIndex,
                        particulateMatter25: air.particulateMatter25,
                        particulateMatter10: air.particulateMatter10,
                        externalParticulateMatter25: air.externalParticulateMatter25,
                        filterRemainingPercent: air.filterRemainingPercent,
                        runtimeRemainingMinutes: air.runtimeRemainingMinutes,
                        hasError: air.hasError,
                        reportedAt: air.reportedAt,
                        startedAt: air.startedAt ?? at,
                        endingAt: air.endingAt,
                        startReason: air.startReason,
                        lastCycleValid: air.lastCycleValid,
                        errorKind: air.errorKind
                    )
                    state.airQuality = air
                }
            )
        case .stopPreCleaning:
            return CommandDescriptor(
                conflictGroup: "precleaning",
                displayField: .airQuality,
                proofReading: .airQuality,
                isProvenBy: { $0.airQuality?.cleaningState == .off },
                optimisticPatch: { state, _, _ in
                    guard let air = state.airQuality else { return }
                    state.airQuality = VehicleAirQuality(
                        cleaningState: .off,
                        airQualityIndex: air.airQualityIndex,
                        particulateMatter25: air.particulateMatter25,
                        particulateMatter10: air.particulateMatter10,
                        externalParticulateMatter25: air.externalParticulateMatter25,
                        filterRemainingPercent: air.filterRemainingPercent,
                        runtimeRemainingMinutes: air.runtimeRemainingMinutes,
                        hasError: air.hasError,
                        reportedAt: air.reportedAt,
                        startedAt: air.startedAt,
                        endingAt: air.endingAt,
                        startReason: air.startReason,
                        lastCycleValid: air.lastCycleValid,
                        errorKind: air.errorKind
                    )
                }
            )
        case .lock, .lockReducedGuard:
            return CommandDescriptor(
                conflictGroup: "locks",
                displayField: .exterior,
                proofReading: self == .lock ? .locks : nil,
                isProvenBy: { $0.exteriorStatus?.isLocked == true },
                optimisticPatch: { state, _, _ in
                    guard var exterior = state.exteriorStatus else { return }
                    exterior.isLocked = true
                    state.exteriorStatus = exterior
                }
            )
        case .unlock:
            return CommandDescriptor(
                conflictGroup: "locks",
                displayField: .exterior,
                proofReading: .locks,
                isProvenBy: { $0.exteriorStatus?.isLocked == false },
                optimisticPatch: { state, _, brand in
                    // Volvo unlock does not patch exterior; the official app behaves the same way.
                    guard brand != .volvo, var exterior = state.exteriorStatus else { return }
                    exterior.isLocked = false
                    state.exteriorStatus = exterior
                }
            )
        case .unlockTrunk:
            // Trunk-only unlock leaves central locking engaged, so nothing to prove or patch.
            return CommandDescriptor()
        case .openTailgate:
            return CommandDescriptor(
                conflictGroup: "tailgate",
                displayField: .exterior,
                proofReading: .openings,
                isProvenBy: {
                    $0.exteriorStatus?.openings.first { $0.opening == .tailgate }?.state == .open
                },
                optimisticPatch: { state, _, _ in
                    state.patchOpening(.tailgate, to: .open)
                }
            )
        case .closeTailgate:
            return CommandDescriptor(
                conflictGroup: "tailgate",
                displayField: .exterior,
                proofReading: .openings,
                isProvenBy: {
                    $0.exteriorStatus?.openings.first { $0.opening == .tailgate }?.state == .closed
                },
                optimisticPatch: { state, _, _ in
                    state.patchOpening(.tailgate, to: .closed)
                }
            )
        case .openWindows, .closeWindows:
            let expected: OpeningState = self == .openWindows ? .open : .closed
            let windows: [VehicleOpening] = [.frontLeftWindow, .frontRightWindow, .rearLeftWindow, .rearRightWindow]
            return CommandDescriptor(
                conflictGroup: "windows",
                displayField: .exterior,
                proofReading: .openings,
                isProvenBy: { state in
                    windows.allSatisfy { window in
                        state.exteriorStatus?.openings.first { $0.opening == window }?.state == expected
                    }
                }
            )
        case .flashLights, .honkAndFlash, .honkHorn:
            return CommandDescriptor()
        case .setChargeTarget(let target):
            return CommandDescriptor(
                conflictGroup: "charge-target",
                displayField: .chargeTarget,
                proofReading: .charging,
                isProvenBy: { $0.energy.targetPercentage == target },
                optimisticPatch: { state, _, _ in
                    state.energy.targetPercentage = target
                }
            )
        case .setAmpLimit(let amps):
            return CommandDescriptor(
                conflictGroup: "amp-limit",
                displayField: .chargingCurrentLimit,
                proofReading: .charging,
                isProvenBy: { $0.energy.currentLimitAmps == amps },
                optimisticPatch: { state, _, _ in
                    state.energy.currentLimitAmps = amps
                }
            )
        case .startChargingOverride:
            return CommandDescriptor(
                conflictGroup: "charging-override",
                displayField: .chargingState,
                proofReading: .charging,
                isProvenBy: { $0.energy.chargingState == .charging || $0.energy.chargingState == .smartCharging }
            )
        case .stopChargingOverride:
            return CommandDescriptor(conflictGroup: "charging-override", displayField: .chargingState)
        case .setGlobalChargeTimer:
            return CommandDescriptor(conflictGroup: "global-charge-timer")
        case .setClimateTimer, .deleteClimateTimer:
            return CommandDescriptor(conflictGroup: "climate-timer")
        case .scheduleOTA, .installOTANow, .cancelOTA:
            return CommandDescriptor(conflictGroup: "ota")
        case .createChargeLocationAtCar, .updateChargeLocationAlias,
             .updateChargeLocationAmpLimit, .updateChargeLocationMinimumSoc,
             .setChargeLocationOptimisedCharging, .deleteChargeLocation:
            return CommandDescriptor()
        case .startEngine, .stopEngine:
            return CommandDescriptor(conflictGroup: "engine")
        }
    }

    var confirmationConflictKey: String? { descriptor.conflictGroup }
}

extension VehicleState {
    fileprivate mutating func patchOpening(_ opening: VehicleOpening, to state: OpeningState) {
        guard var exterior = exteriorStatus else { return }
        if let index = exterior.openings.firstIndex(where: { $0.opening == opening }) {
            exterior.openings[index] = OpeningReading(opening: opening, state: state)
        } else {
            exterior.openings.append(OpeningReading(opening: opening, state: state))
        }
        exteriorStatus = exterior
    }
}
