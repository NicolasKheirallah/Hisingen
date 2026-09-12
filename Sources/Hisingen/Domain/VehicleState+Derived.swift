import Foundation

extension VehicleState {
    var totalCombinedRangeKm: Int? {
        switch powertrain {
        case .bev:
            return rangeKm
        case .ice:
            return fuelRangeKm
        case .phev, .mildHybrid:
            if let e = rangeKm, let f = fuelRangeKm { return e + f }
            return rangeKm ?? fuelRangeKm
        case .unknown:
            if let e = rangeKm, let f = fuelRangeKm { return e + f }
            return rangeKm ?? fuelRangeKm
        }
    }

    var primaryRangeKm: Int? {
        totalCombinedRangeKm ?? rangeKm ?? fuelRangeKm
    }

    /// Whether the backend explicitly reports the signed-in account as the vehicle's owner.
    /// Tri-state on purpose: `false` only when `GetMyCars` returned `userIsOwner == false`;
    /// `nil` (absent flag, Volvo, or pre-capability snapshot) means unknown and must never
    /// block a command.
    var accountOwnsVehicle: Bool? {
        otaCapabilities?.userIsOwner
    }

    var isAwaitingVehicleConfirmation: Bool {
        commandState.receipts.contains { $0.status.isAwaiting }
    }

    var formattedBuildWeek: String? {
        guard let raw = structureWeek?.trimmingCharacters(in: .whitespacesAndNewlines), raw.count >= 6 else {
            return structureWeek
        }
        let year = raw.prefix(4)
        let week = raw.suffix(2)
        return "\(year) · W\(week)"
    }

    var formattedServiceTrigger: String? {
        guard let raw = serviceTrigger?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw.contains("CALENDAR") || raw.contains("TIME") {
            return L10n.text("Time")
        } else if raw.contains("DISTANCE") || raw.contains("MILE") || raw.contains("KM") {
            return L10n.text("Distance")
        } else if raw.contains("HOUR") || raw.contains("ENGINE") {
            return L10n.text("Operating hours")
        }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var formattedSteeringOrientation: String? {
        guard let raw = steeringOrientation?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let upper = raw.uppercased()
        if upper == "LEFT" || upper.contains("LHD") {
            return L10n.text("Left-hand drive")
        } else if upper == "RIGHT" || upper.contains("RHD") {
            return L10n.text("Right-hand drive")
        }
        return raw.capitalized
    }

    var isCharging: Bool { chargingState.isActivelyCharging }

    var isClimateActive: Bool {
        guard let activity = climateStatus?.activity else { return false }
        return activity == .active || activity == .heating || activity == .cooling || activity == .ventilating || activity == .starting
    }

    /// Year/powertrain-aware refinement on top of `VehicleModelFamily.nominalBatteryCapacityKwh`
    /// (the base per-model table) — not an independent capacity table. Falls through to the base
    /// table for anything without a known year-specific pack revision or a PHEV-specific figure.
    var factoryNominalBatteryCapacityKwh: Double {
        guard model.isKnown else { return 0.0 }
        let yearInt = modelYear.flatMap(Int.init)
        if (model == .polestar2 || model == .volvoXC40 || model == .volvoEX40 || model == .volvoC40 || model == .volvoEC40),
           let yearInt, yearInt >= 2024 {
            return 82.0
        }
        if powertrain == .phev {
            guard let yearInt else { return model.nominalBatteryCapacityKwh }
            return yearInt >= 2022 ? 18.8 : 11.6
        }
        return model.nominalBatteryCapacityKwh
    }

    var factoryUsableBatteryCapacityKwh: Double {
        guard model.isKnown else { return 0.0 }
        let yearInt = modelYear.flatMap(Int.init)
        if (model == .polestar2 || model == .volvoXC40 || model == .volvoEX40 || model == .volvoC40 || model == .volvoEC40),
           let yearInt, yearInt >= 2024 {
            return 79.0
        }
        if powertrain == .phev {
            guard let yearInt else { return model.nominalUsableCapacityKwh }
            return yearInt >= 2022 ? 14.9 : 9.1
        }
        return model.nominalUsableCapacityKwh
    }

    var batteryDegradationPercent: Double? {
        // Neither provider exposes a validated measured capacity or SoH value. This property
        // represents that absence and stays nil. The separate BatteryHealthEstimate type holds
        // Hisingen's remembered full-charge range calculation.
        return nil
    }

    var configuredUsableBatteryCapacityKwh: Double {
        // This value is suitable for nominal charging-energy estimates only.
        return factoryUsableBatteryCapacityKwh
    }

    /// Every capacity figure below is interpolated from `factoryNominalBatteryCapacityKwh`/
    /// `factoryUsableBatteryCapacityKwh` — the same computed values shown elsewhere in the UI —
    /// rather than restated as separate hardcoded numbers, so this description can't silently
    /// drift out of sync with them. Only the chemistry/module/voltage prose is hand-authored.
    ///
    /// Some branches below (Polestar 2 and Volvo XC40-family "Standard Range," Volvo EX30
    /// "Standard Range") describe real-world pack variants that exist in the market but that
    /// `VehicleModelFamily.nominalBatteryCapacityKwh` has no signal to distinguish from the
    /// higher-capacity variant of the same model — the current capacity table only knows one
    /// figure per model family (plus year), not per-trim. Those branches are therefore currently
    /// unreachable; they're left in place, clearly labelled, rather than silently deleted, in
    /// case a future capability signal makes the distinction possible.
    var batteryPackDescription: String {
        let nominal = factoryNominalBatteryCapacityKwh
        let usable = factoryUsableBatteryCapacityKwh
        // Formatted with the plain (locale-invariant) `String(format:)` overload — matching
        // `Format.swift`'s convention for every other numeric readout in the app — rather than
        // `L10n.format`, whose `locale:` argument follows the interface language/system region
        // and would otherwise render these as "78,0 kWh" under a comma-decimal locale.
        let nominalText = String(format: "%.1f", nominal)
        let usableText = String(format: "%.1f", usable)
        let nominalWhole = String(format: "%.0f", nominal)
        switch model {
        case .polestar2:
            if nominal >= 80.0 {
                return L10n.format("%@ kWh Long Range (CATL · 27 Modules / 324 Cells · 400V)", nominalText)
            } else if nominal >= 75.0 {
                return L10n.format("%@ kWh Long Range (LG Energy / CATL · 27 Modules / 324 Cells · 400V)", nominalText)
            } else {
                // Unreachable with the current capacity table — see the type-level comment above.
                return L10n.text("69.0 kWh Standard Range (CATL · 24 Modules / 288 Cells · 400V)")
            }
        case .polestar3:
            return L10n.format("%@ kWh Extended Range (CATL · 17 Modules / 204 Cells · 400V)", nominalText)
        case .polestar4:
            return L10n.format("%@ kWh Long Range (CATL / VREMT · %@ kWh Nominal · 400V)", nominalWhole, nominalWhole)
        case .polestar1:
            return L10n.format("%@ kWh High-Output Hybrid (%@ kWh Usable · Triple Pack)", nominalText, usableText)
        case .volvoEX30:
            if nominal >= 65.0 {
                return L10n.format("%@ kWh Extended Range (NMC · %@ kWh Usable · 400V)", nominalText, usableText)
            } else {
                // Unreachable with the current capacity table — see the type-level comment above.
                return L10n.text("51.0 kWh Standard Range (LFP · 49.0 kWh Usable · 400V)")
            }
        case .volvoEX90, .volvoES90:
            return L10n.format("%@ kWh Extended Range (CATL · %@ kWh Usable · 400V)", nominalText, usableText)
        case .volvoXC40, .volvoEX40, .volvoC40, .volvoEC40:
            if nominal >= 80.0 {
                return L10n.format("%@ kWh Long Range (CATL · %@ kWh Usable · 400V)", nominalText, usableText)
            } else if nominal >= 75.0 {
                return L10n.format("%@ kWh Long Range (LG Energy / CATL · %@ kWh Usable · 400V)", nominalText, usableText)
            } else {
                // Unreachable with the current capacity table — see the type-level comment above.
                return L10n.text("69.0 kWh Standard Range (CATL · 64.0 kWh Usable · 400V)")
            }
        case .volvoXC60, .volvoXC90, .volvoS60, .volvoS90, .volvoV60, .volvoV90:
            if powertrain == .phev {
                if nominal >= 16.0 {
                    return L10n.format("%@ kWh T8 Recharge PHEV (96 Cells · %@ kWh Usable)", nominalText, usableText)
                } else {
                    return L10n.format("%@ kWh T8 Twin Engine PHEV (%@ kWh Usable)", nominalText, usableText)
                }
            }
            return L10n.format("%@ kWh High-Voltage Pack", nominalText)
        default:
            if nominal > 0 {
                return L10n.format("%@ kWh Lithium-ion Pack", nominalText)
            }
            return L10n.text("High-Voltage Traction Battery")
        }
    }

    /// Derived label. Because neither provider exposes a measured SoH (see
    /// `batteryDegradationPercent`), this currently always reads "Unavailable" — it exists so
    /// a future verified source plugs into exactly one place.
    var batteryHealthStatus: String {
        guard powertrain.hasElectricRange, let deg = batteryDegradationPercent else {
            return L10n.text("Unavailable")
        }
        let soh = max(50.0, min(100.0, 100.0 - deg))
        if soh >= 95.0 { return L10n.text("Optimal") }
        if soh >= 85.0 { return L10n.text("Good") }
        if soh >= 75.0 { return L10n.text("Normal") }
        return L10n.text("Service Advised")
    }

    var stateSummary: VehicleStateSummary {
        if exteriorStatus?.alarmTriggered == true {
            return VehicleStateSummary(message: L10n.text("Alarm triggered"), severity: .critical)
        }
        if let battery = batteryPercentage, battery <= 15, !isCharging, powertrain.hasElectricRange {
            return VehicleStateSummary(message: L10n.text("Low battery"), severity: .critical)
        }
        if let fuel = fuelLevelPercent, fuel <= 12, powertrain.hasFuelRange {
            return VehicleStateSummary(message: L10n.text("Low fuel"), severity: .critical)
        }
        if let openings = exteriorStatus?.itemsNeedingAttention, !openings.isEmpty {
            if openings.count == 1, let only = openings.first {
                return VehicleStateSummary(message: L10n.format("%@ open", only.displayName), severity: .warning)
            }
            return VehicleStateSummary(message: L10n.format("%d items open", openings.count), severity: .warning)
        }
        if exteriorStatus?.isLocked == false {
            return VehicleStateSummary(message: L10n.text("Unlocked"), severity: .warning)
        }
        if chargingState == .fault {
            return VehicleStateSummary(message: L10n.text("Charging fault"), severity: .warning)
        }
        if serviceWarning {
            return VehicleStateSummary(message: L10n.text("Service warning"), severity: .warning)
        }
        if let fluid = fluidWarnings.first {
            return VehicleStateSummary(message: fluid, severity: .warning)
        }
        if let warning = healthDetails?.warnings.first {
            return VehicleStateSummary(message: warning.displayName, severity: .warning)
        }
        if healthDetails?.tyres.contains(where: { $0.warning.needsAttention }) == true {
            return VehicleStateSummary(message: L10n.text("Tyre pressure warning"), severity: .warning)
        }
        if softwareInfo?.hasActionableFailure() == true {
            return VehicleStateSummary(message: L10n.text("Software update failed"), severity: .warning)
        }
        if case .unavailable = availability {
            return VehicleStateSummary(message: availability.displayName, severity: .warning)
        }
        if isEngineRunning == true {
            return VehicleStateSummary(message: L10n.text("Engine running"), severity: .good)
        }
        if exteriorStatus?.isLocked == true {
            return VehicleStateSummary(message: L10n.text("Vehicle secured"), severity: .good)
        }
        return VehicleStateSummary(message: L10n.text("No active warnings reported"), severity: .neutral)
    }

    var capabilityProfile: VehicleCapabilityProfile {
        VehicleCapabilityProfile(modelName: modelName, vin: vin, probed: probedCapabilities,
                                 advertised: otaCapabilities?.advertisedCapabilities ?? [:])
    }

    var isPluggedIn: Bool? {
        switch chargerConnection {
        case .connected, .fault: return true
        case .disconnected: return false
        case .unknown: return nil
        }
    }

    var isComplete: Bool {
        if chargingState == .complete { return true }
        guard let batteryPercentage else { return false }
        if let chargeTargetPercentage {
            return batteryPercentage >= Double(chargeTargetPercentage) - 0.5
        }
        return batteryPercentage >= 99.5
    }

    var model: VehicleModel { VehicleModel(modelName: modelName) }

    var isVolvo: Bool {
        vin.uppercased().hasPrefix("YV")
    }

    /// Current vehicle-reported range at the present SOC compared with a WLTP reference at the
    /// same SOC — the model-family table, or a VIN-specific `specification` override entered in
    /// Settings when one exists. This is a range comparison, not battery State of Health.
    /// `battery >= 20` matches the same low-SOC cutoff `BatteryHealthEstimator`'s range signal
    /// uses, since the vehicle's own range readout gets noisier as it approaches empty.
    func currentRangeVsModelWltpPercent(specification: VehicleSpecificationOverride? = nil) -> Double? {
        guard let battery = batteryPercentage, battery >= 20,
              let range = rangeKm, range > 0 else { return nil }
        let referenceRange = specification?.wltpRangeKm
            ?? (model.hasModelReferenceSpecs ? model.nominalWltpRangeKm : nil)
        guard let referenceRange, referenceRange > 0 else { return nil }
        let expectedRangeAtCurrentSoC = referenceRange * (battery / 100.0)
        guard expectedRangeAtCurrentSoC > 0 else { return nil }
        return (Double(range) / expectedRangeAtCurrentSoC * 1000).rounded() / 10
    }

    var estimatedChargingCompletion: Date? {
        guard isCharging, let minutes = remainingChargingMinutes, minutes > 0 else { return nil }
        guard !isStale() else { return nil }
        let completion = (reportedDate(for: .charging) ?? vehicleReportedAt ?? fetchedAt).addingTimeInterval(TimeInterval(minutes * 60))
        return completion > Date() ? completion : nil
    }

    var formattedCompletionTime: String? {
        guard let minutes = remainingChargingMinutes, minutes > 0, isCharging else { return nil }
        return Format.completionTime(from: minutes, baseDate: reportedDate(for: .charging) ?? vehicleReportedAt ?? fetchedAt)
    }

    func formattedChargingRate(unit: DistanceUnit) -> String? {
        guard let watts = chargingPowerWatts, watts > 0, isCharging else { return nil }


        guard let consumption = model.averageConsumptionWhPerKm else { return nil }
        return Format.chargingRateFormatted(powerWatts: watts, consumptionWhPerKm: consumption, unit: unit)
    }

    var freshnessDescription: String {
        if isStale() {
            return L10n.format("Vehicle asleep · Updated %@", Format.relativeAge(since: dataTimestamp))
        }
        return L10n.format("Updated %@", Format.relativeAge(since: dataTimestamp))
    }

    var dataTimestamp: Date { vehicleReportedAt ?? fetchedAt }

    func isStale(at date: Date = Date()) -> Bool {


        if date.timeIntervalSince(fetchedAt) < 120 { return false }
        let threshold: TimeInterval = isCharging ? 15 * 60 : 60 * 60
        return date.timeIntervalSince(dataTimestamp) > threshold
    }
}
