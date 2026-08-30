import Charts
import SwiftUI

extension InfoTabView {
    // MARK: - Software & updates

    var softwareUpdateCard: some View {
        guard let sw = state.softwareInfo else { return AnyView(EmptyView()) }

        let installed = (sw.installedVersion ?? sw.version)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let latest = sw.latestAvailableVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasNewer = (latest?.isEmpty == false) && latest != installed
        let failed = sw.hasActionableFailure()
        let stateLabel = (sw.rawState?.displayName ?? sw.state.displayName)

        var rows: [KVRow] = []
        if let installed, !installed.isEmpty {
            rows.append(KVRow(L10n.text("Installed Version"), installed, symbol: "checkmark.seal",
                              info: L10n.text("Unverified value from an undocumented backend field; compare it with the version shown in the vehicle.")))
        }
        if hasNewer, let latest {
            rows.append(KVRow(L10n.text("Available Version"), latest, symbol: "arrow.down.circle", valueWarning: true))
        }
        if sw.state != .unknown || sw.rawState != nil {
            rows.append(KVRow(L10n.text("Update State"), stateLabel, symbol: "gearshape.arrow.triangle.2.circlepath",
                              valueWarning: failed))
        }
        if let scheduled = sw.scheduledAt {
            var value = Format.dateTimeFormatter.string(from: scheduled)
            if let by = sw.scheduleSetBy { value += " (\(by.displayName))" }
            rows.append(KVRow(L10n.text("Install Scheduled"), value, symbol: "calendar.badge.clock"))
        }
        if let seconds = sw.estimatedInstallDurationSeconds, seconds > 0 {
            rows.append(KVRow(L10n.text("Estimated Install Time"),
                              Format.shortDuration(minutes: seconds / 60), symbol: "timer"))
        }
        if let updatedAt = sw.updatedAt {
            rows.append(KVRow(L10n.text("Status Reported"), Format.dateTimeFormatter.string(from: updatedAt), symbol: "clock"))
        }

        guard !rows.isEmpty else { return AnyView(EmptyView()) }

        let headerColor: Color = failed ? .red : (hasNewer ? .orange : .blue)

        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: failed ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath",
                               title: L10n.text("Software & Updates"), color: headerColor)
                    Spacer()
                    if failed {
                        Pill(text: L10n.text("Update failed"), color: .red, symbol: "exclamationmark.triangle.fill")
                    } else if hasNewer {
                        Pill(text: L10n.text("Update available"), color: .orange, symbol: "arrow.down.circle.fill")
                    }
                }
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
                if failed {
                    Text(L10n.text("The backend recorded a failed update event. This is an event record, not a live vehicle fault — a Polestar workshop can apply the update directly if it keeps failing."))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        })
    }

    // MARK: - Vehicle errors (Chronos)

    var vehicleErrorsCard: some View {
        let errors = state.vehicleErrors
        guard !errors.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "exclamationmark.triangle.fill", title: L10n.text("Vehicle Errors"), color: .red)
                VStack(spacing: 6) {
                    ForEach(errors.indices, id: \.self) { index in
                        let error = errors[index]
                        KVRow(error.service.displayName, error.errorCode.displayName,
                              symbol: "exclamationmark.circle",
                              valueWarning: error.errorCode != .unspecified)
                    }
                }
                Text(L10n.text("Backend error records from the vehicle's charging and climate services. Not a full diagnostic scan."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        })
    }

    // MARK: - Ambient conditions

    var ambientWeatherCard: some View {
        guard let weather = state.weather, weatherCardHasContent else { return AnyView(EmptyView()) }
        var rows: [KVRow] = []
        if let temp = weather.temperatureCelsius {
            rows.append(KVRow(L10n.text("Outside Temperature"),
                              Format.temperature(celsius: temp, unit: preferences.temperatureUnit),
                              symbol: "thermometer.medium"))
        }
        if let feels = weather.apparentTemperatureCelsius {
            rows.append(KVRow(L10n.text("Feels Like"),
                              Format.temperature(celsius: feels, unit: preferences.temperatureUnit),
                              symbol: "thermometer.sun.fill"))
        }
        if let condition = weather.condition, !condition.isEmpty {
            rows.append(KVRow(L10n.text("Condition"), L10n.text(condition), symbol: "cloud.fill"))
        }
        if let humidity = weather.relativeHumidity {
            rows.append(KVRow(L10n.text("Humidity"), "\(humidity)%", symbol: "humidity.fill"))
        }
        if let timestamp = weather.timestamp {
            rows.append(KVRow(L10n.text("Observed"), Format.dateTimeFormatter.string(from: timestamp), symbol: "clock"))
        }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "cloud.sun.fill", title: L10n.text("Ambient Conditions"), color: .cyan)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
                Text(L10n.text("Reported by the vehicle at its parked location — not a forecast."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        })
    }

    // MARK: - Battery diagnostics

    var batteryDiagnosticsRows: [KVRow] {
        guard let diag = state.batteryDiagnostics else { return [] }
        var rows: [KVRow] = []
        if diag.chargerPowerState != .unknown {
            rows.append(KVRow(L10n.text("Power Module"), diag.chargerPowerState.displayName,
                              symbol: "batteryblock", valueWarning: diag.chargerPowerState == .fault))
        }
        if let minutes = diag.timeToTargetMinutes {
            rows.append(KVRow(L10n.text("Time to Target"), Format.shortDuration(minutes: minutes), symbol: "timer",
                              info: L10n.text("Vehicle Dynamic Calculation. Estimated time until the high-voltage battery reaches the configured charge target.")))
        }
        if let minutes = diag.timeToMinimumSOCMinutes {
            rows.append(KVRow(L10n.text("Time to Min SOC"), Format.shortDuration(minutes: minutes), symbol: "battery.50percent",
                              info: L10n.text("Vehicle Dynamic Calculation. Estimated time to reach the minimum operating state of charge.")))
        }
        if let value = diag.averageConsumption {
            rows.append(KVRow(L10n.text("Avg Consumption"),
                              Format.energyConsumption(kwhPer100Km: value, unit: preferences.energyConsumptionUnit),
                              symbol: "chart.line.uptrend.xyaxis",
                              info: L10n.text("Vehicle Calculation. Long-term average energy consumption from the trip computer.")))
        }
        if let value = diag.averageConsumptionSinceCharge {
            rows.append(KVRow(L10n.text("Avg Since Last Charge"),
                              Format.energyConsumption(kwhPer100Km: value, unit: preferences.energyConsumptionUnit),
                              symbol: "chart.line.uptrend.xyaxis",
                              info: L10n.text("Vehicle Calculation. Average electric consumption recorded since the vehicle was last unplugged.")))
        }
        if let wh = diag.energyUsedSinceChargeWh {
            rows.append(KVRow(L10n.text("Energy Since Charge"), String(format: "%.1f kWh", wh / 1_000), symbol: "leaf.fill",
                              info: L10n.text("Vehicle Calculation. Total high-voltage energy used by powertrain and HVAC since the last charge.")))
        }
        return rows
    }

    var batteryDiagnosticsCard: some View {
        let rows = batteryDiagnosticsRows
        guard !rows.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "batteryblock.fill", title: L10n.text("Battery Diagnostics"), color: .green)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
            }
        })
    }

    // MARK: - Trip computer

    var tripComputerCard: some View {
        var rows: [KVRow] = []

        if let manualKm = state.tripMeterManualKm {
            rows.append(KVRow(L10n.text("Trip Meter (TM)"), Format.distance(km: Int(manualKm.rounded()), unit: preferences.distanceUnit), symbol: "m.circle.fill"))
        }
        if let autoKm = state.tripMeterAutomaticKm {
            rows.append(KVRow(L10n.text("Automatic Trip (AT)"), Format.distance(km: autoKm, unit: preferences.distanceUnit), symbol: "a.circle.fill"))
        }
        if let electricKm = state.electricDistanceKm, electricKm > 0 {
            rows.append(KVRow(L10n.text("Electric Driving"), Format.distance(km: electricKm, unit: preferences.distanceUnit), symbol: "bolt.car.fill"))
        }
        if let fuelKm = state.fuelDistanceKm, fuelKm > 0 {
            rows.append(KVRow(L10n.text("Combustion Driving"), Format.distance(km: fuelKm, unit: preferences.distanceUnit), symbol: "fuelpump.fill"))
        }
        if let regen = state.regeneratedEnergyKwh, regen > 0 {
            rows.append(KVRow(L10n.text("Regenerated Energy"), String(format: "%.2f kWh", regen), symbol: "arrow.triangle.2.circlepath"))
        }
        if let speed = state.averageSpeedKmH, speed > 0 {
            rows.append(KVRow(L10n.text("Average Speed"), Format.speed(kmH: Int(speed.rounded()), unit: preferences.distanceUnit), symbol: "gauge.with.needle.fill"))
        }
        if let odo = state.odometerKm {
            rows.append(KVRow(L10n.text("Total Distance"), Format.distance(km: odo, grouped: true, unit: preferences.distanceUnit), symbol: "speedometer"))
        }

        guard !rows.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "gauge.with.dots.needle.bottom.50percent", title: L10n.text("Trip Computer & Distance"), color: .indigo)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
            }
        })
    }

    // MARK: - Connectivity & wake

    var connectivityWakeCard: AnyView {
        let current = state.connectivity
        guard current?.wakeReason != nil || current?.networkType != nil else {
            return AnyView(EmptyView())
        }
        let history = asyncData.connectivityHistory
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "antenna.radiowaves.left.and.right",
                           title: L10n.text("Connectivity & Wake"), color: .cyan)
                if let reason = current?.wakeReason {
                    KVRow(L10n.text("Awake Because"), reason, symbol: "sun.max")
                }
                if let network = current?.networkType {
                    KVRow(L10n.text("Network"), network, symbol: "dot.radiowaves.up.forward")
                }
                if let bars = current?.signalBars {
                    KVRow(L10n.text("Signal"), "\(bars)/4", symbol: "signalbars")
                }
                if history.count >= 3 {
                    Chart(history.reversed()) { record in
                        PointMark(
                            x: .value(L10n.text("Date"), record.timestamp),
                            y: .value(L10n.text("Signal"), record.signalBars ?? 0)
                        )
                        .symbolSize(20)
                        .foregroundStyle(Color.cyan.opacity(0.8))
                    }
                    .chartYScale(domain: 0...4)
                    .chartYAxisLabel(L10n.text("Bars"))
                    .frame(height: 70)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.text("Signal strength history chart"))
                    .accessibilityValue(chartAccessibilityValue(points: history.map { Double($0.signalBars ?? 0) }))
                    let wakes = history.compactMap(\.wakeReason)
                    if !wakes.isEmpty {
                        KVRow(L10n.text("Recent Wake Reasons"),
                              Dictionary(grouping: wakes, by: { $0 })
                                  .map { "\($0.key) ×\($0.value.count)" }
                                  .sorted()
                                  .joined(separator: " · "),
                              symbol: "clock.arrow.circlepath")
                    }
                }
            }
        })
    }

    // MARK: - Fluids & lighting

    var fluidsAndLightingCard: some View {
        var rows: [KVRow] = []

        if let health = state.healthDetails {
            let hasBrake = health.warnings.contains(.brakeFluid)
            let brakeReported = health.reportedWarnings.contains(.brakeFluid)
            rows.append(KVRow(
                L10n.text("Brake Fluid"),
                hasBrake ? L10n.text("Low / Check Required") : (brakeReported ? L10n.text("No warning reported") : L10n.text("Unavailable")),
                symbol: "circle.circle",
                valueWarning: hasBrake,
                info: L10n.text("Warning status only. The provider does not report a measured brake-fluid level.")
            ))

            if let frontPads = state.frontBrakePadStatus, !frontPads.isEmpty {
                let warn = frontPads.uppercased() != "NORMAL" && !frontPads.uppercased().contains("NO_WARNING")
                rows.append(KVRow(L10n.text("Front Brake Pads"), frontPads.capitalized, symbol: "circle.circle", valueWarning: warn))
            }
            if let rearPads = state.rearBrakePadStatus, !rearPads.isEmpty {
                let warn = rearPads.uppercased() != "NORMAL" && !rearPads.uppercased().contains("NO_WARNING")
                rows.append(KVRow(L10n.text("Rear Brake Pads"), rearPads.capitalized, symbol: "circle.circle", valueWarning: warn))
            }

            let hasWasher = health.warnings.contains(.washerFluid)
            let washerReported = health.reportedWarnings.contains(.washerFluid)
            rows.append(KVRow(L10n.text("Washer Fluid"), hasWasher ? L10n.text("Low Level") : (washerReported ? L10n.text("No warning reported") : L10n.text("Unavailable")), symbol: "drop.triangle.fill", valueWarning: hasWasher, info: L10n.text("Warning status only. The provider does not report a measured washer-fluid level.")))

            let hasCoolant = health.warnings.contains(.engineCoolant)
            let coolantReported = health.reportedWarnings.contains(.engineCoolant)
            rows.append(KVRow(L10n.text("Coolant System"), hasCoolant ? L10n.text("Check Level") : (coolantReported ? L10n.text("No warning reported") : L10n.text("Unavailable")), symbol: "thermometer.sun.fill", valueWarning: hasCoolant, info: L10n.text("Warning status only. The provider does not report a measured coolant level.")))

            let hasLight = health.warnings.contains(.exteriorLight) || !health.lightFailures.isEmpty
            let lightsReported = health.reportedWarnings.contains(.exteriorLight)
            rows.append(KVRow(L10n.text("Exterior Lighting"), hasLight ? L10n.text("Bulb Failure Detected") : (lightsReported ? L10n.text("No warning reported") : L10n.text("Unavailable")), symbol: "lightbulb.fill", valueWarning: hasLight, info: L10n.text("Warning status only; this is not a live electrical test of every exterior lamp.")))

            if !health.tyres.isEmpty {
                let hasTyreWarning = health.tyres.contains { $0.warning.needsAttention }
                let allReported = health.tyres.count == 4 && health.tyres.allSatisfy { $0.kilopascals != nil || $0.warning != .unknown }
                let tyreStatus = hasTyreWarning
                    ? L10n.text("Pressure Warning")
                    : (allReported ? L10n.text("Everything looks good") : (health.tyres.contains { $0.warning != .unknown || $0.kilopascals != nil } ? L10n.text("No warnings reported") : L10n.text("Data unavailable")))
                rows.append(KVRow(L10n.text("Tyre Pressure Status"), tyreStatus, symbol: "circle.dashed", valueWarning: hasTyreWarning, info: L10n.text("Some providers expose warning status without a numeric tyre-pressure measurement.")))
            }
        } else {
            rows.append(KVRow(L10n.text("Brake Fluid"), L10n.text("Unavailable"), symbol: "circle.circle"))
            if let frontPads = state.frontBrakePadStatus, !frontPads.isEmpty {
                rows.append(KVRow(L10n.text("Front Brake Pads"), frontPads.capitalized, symbol: "circle.circle"))
            }
            if let rearPads = state.rearBrakePadStatus, !rearPads.isEmpty {
                rows.append(KVRow(L10n.text("Rear Brake Pads"), rearPads.capitalized, symbol: "circle.circle"))
            }
            rows.append(KVRow(L10n.text("Washer Fluid"), L10n.text("Unavailable"), symbol: "drop.triangle.fill"))
            rows.append(KVRow(L10n.text("Coolant System"), L10n.text("Unavailable"), symbol: "thermometer.sun.fill"))
            rows.append(KVRow(L10n.text("Exterior Lighting"), L10n.text("Unavailable"), symbol: "lightbulb.fill"))
        }

        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "checklist", title: L10n.text("Fluids & Lighting Diagnostics"), color: .orange)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
            }
        }
    }
}
