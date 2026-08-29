import AppKit
import SwiftUI
import UniformTypeIdentifiers

// `HistoryDashboardView` — period picker, overview card, month/year comparison, emissions
// card, the Export menu, and the empty / nothing-in-range states.

extension HistoryDashboardView {
    // MARK: - Period picker

    var periodPicker: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Picker(L10n.text("History Period"), selection: $period) {
                    ForEach(HistoryPeriod.allCases.filter { $0 != .custom }) { item in
                        Text(L10n.text(item.rawValue)).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(L10n.text("History Period"))

                Button {
                    showCustomRangeEditor = true
                } label: {
                    Image(systemName: period == .custom ? "calendar.badge.checkmark" : "calendar")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help(L10n.text("Pick a custom date range"))
                .accessibilityLabel(L10n.text("Custom date range"))
                .popover(isPresented: $showCustomRangeEditor, arrowEdge: .bottom) { customRangePopover }

                Button {
                    bumpRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help(L10n.text("Reload history from the local database"))
                .accessibilityLabel(L10n.text("Refresh history"))
            }

            HStack(spacing: 4) {
                Image(systemName: "info.circle").font(.system(size: 8))
                if period == .custom {
                    Text(L10n.format("Custom range: %@ – %@",
                                     Format.dateFormatter.string(from: min(customRangeStart, customRangeEnd)),
                                     Format.dateFormatter.string(from: max(customRangeStart, customRangeEnd))))
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.text("Battery health, odometer totals and lifetime cost always use full history, regardless of the range above."))
                        .font(.system(size: 8.5))
                }
                Spacer()
                if snapshot.truncated {
                    Text(L10n.text("Older rows beyond the cap are not shown."))
                        .font(.system(size: 8.5))
                        .foregroundStyle(HisingenTheme.semanticWarning.opacity(0.9))
                }
            }
            .foregroundStyle(.tertiary)
        }
    }

    var customRangePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Custom Range")).font(.system(size: 12, weight: .semibold))
            DatePicker(L10n.text("From"), selection: $customRangeStart,
                       in: ...customRangeEnd, displayedComponents: .date)
                .font(.system(size: 11))
            DatePicker(L10n.text("To"), selection: $customRangeEnd,
                       in: customRangeStart...Date(), displayedComponents: .date)
                .font(.system(size: 11))
            HStack {
                Spacer()
                Button(L10n.text("Apply")) {
                    period = .custom
                    showCustomRangeEditor = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    // MARK: - Overview

    var overviewCard: some View {
        let totalDistance = trips.reduce(0) { $0 + $1.distanceKm }
        let drivingTime = trips.reduce(0) { $0 + $1.duration }
        let energy = chargingSessions.reduce(0) { $0 + $1.energyDeliveredKwh }
        let estimatedCost = aggregateChargingCost()
        let serviceProjection = HistoryInsights.projectService(
            currentOdometerKm: state.odometerKm.map(Double.init),
            distanceToServiceKm: state.distanceToServiceKm,
            daysToService: state.daysToService,
            odometerPoints: allTimeOdometerPoints
        )
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: "chart.xyaxis.line", title: L10n.text("History Overview"), color: .indigo)
                    Spacer()
                    if state.powertrain.hasCombustionEngine {
                        Button { showFuelSheet = true } label: {
                            Label(L10n.text("Add Fuel"), systemImage: "drop.fill")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.text("Log a fill-up so fuel spend is included in cost estimates"))
                    }
                    exportMenu
                }
                HStack(spacing: 8) {
                    metric(L10n.text("Distance"), Format.distance(km: totalDistance, decimals: 1, unit: preferences.distanceUnit), "road.lanes")
                    metric(L10n.text("Trips"), Format.count(trips.count), "car.side")
                    metric(L10n.text("Driving"), Format.shortDuration(minutes: Int(drivingTime / 60)), "clock")
                }
                HStack(spacing: 8) {
                    metric(L10n.text("Charge Sessions"), Format.count(chargingSessions.count), "bolt.fill")
                    metric(L10n.text("Estimated Energy"), Format.energyKwh(energy), "bolt.circle")
                    metric(
                        L10n.text("Estimated Cost"),
                        estimatedCost.map { Format.currency($0.amount, symbol: $0.currency) } ?? "—",
                        "creditcard"
                    )
                }
                if estimatedCost == nil, !chargingSessions.isEmpty {
                    footnote("exclamationmark.triangle",
                             L10n.text("Charging cost spans multiple currencies, so it is not totalled here. See the per-location breakdown below."))
                }
                if let serviceProjection {
                    HStack(spacing: 5) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 10)).foregroundStyle(HisingenTheme.accent)
                        Text(L10n.format("Next service projected around %@",
                                         Format.dateFormatter.string(from: serviceProjection.projectedDate ?? Date())))
                            .font(.system(size: 9.5)).foregroundStyle(.secondary)
                        if let odo = serviceProjection.projectedOdometerKm {
                            Text("· " + Format.distance(km: Int(odo.rounded()), unit: preferences.distanceUnit))
                                .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                }
                let fuelSpend = lifetime.lifetimeFuelCost
                let lifetimeCostPerKm = HistoryInsights.costPerKm(
                    totalEnergyKwh: lifetime.lifetimeChargingEnergyKwh,
                    pricePerKwh: preferences.electricityPricePerKwh,
                    odometerPoints: allTimeOdometerPoints,
                    fuelCost: fuelSpend
                )
                if let costPerKm = lifetimeCostPerKm, preferences.electricityPricePerKwh > 0 {
                    let perUnit = costPerKm * (preferences.distanceUnit == .kilometers ? 1 : UnitConversion.kilometersPerMile)
                    HStack(spacing: 5) {
                        Image(systemName: "speedometer")
                            .font(.system(size: 10)).foregroundStyle(HisingenTheme.accent)
                        Text(L10n.format("Lifetime charging cost ≈ %@ per %@",
                                         Format.currency(perUnit, symbol: preferences.currencySymbol, decimals: 3),
                                         preferences.distanceUnit == .kilometers ? "km" : "mi"))
                            .font(.system(size: 9.5)).foregroundStyle(.secondary)
                        Text(L10n.text("(estimated)")).font(.system(size: 8.5)).foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    var exportMenu: some View {
        Menu {
            Picker(L10n.text("Range (trips & charging sessions)"), selection: $exportScope) {
                ForEach(ExportScope.allCases) { Text(L10n.text($0.rawValue)).tag($0) }
            }
            Divider()
            Button(L10n.text("Trips")) {
                let csv = exportScope == .selectedPeriod
                    ? HistoryExport.tripsCSV(trips)
                    : database.exportTripsCSV(for: state.vin)
                exportCSV(csv, name: "Trips")
            }
            .disabled(trips.isEmpty)
            Button(L10n.text("Charging Sessions")) {
                let csv = exportScope == .selectedPeriod
                    ? HistoryExport.chargingSessionsCSV(chargingSessions)
                    : database.exportChargingSessionsCSV(for: state.vin)
                exportCSV(csv, name: "Charging-Sessions")
            }
            .disabled(chargingSessions.isEmpty)
            Button(L10n.text("Session Samples")) {
                guard let session = selectedSession else { return }
                exportCSV(database.exportChargingSamplesCSV(sessionID: session.id), name: "Charging-Samples")
            }
            .disabled(selectedSession == nil || selectedSessionCurve.isEmpty)
            Button(L10n.text("Battery Health")) {
                exportCSV(database.exportBatteryHealthCSV(for: state.vin), name: "Battery-Health")
            }
            .disabled(batteryHealthRecords.isEmpty)
            Button(L10n.text("Air Quality")) {
                exportCSV(database.exportAirQualityCSV(for: state.vin), name: "Air-Quality")
            }
            .disabled(airQualityRecords.isEmpty)
            Button(L10n.text("Telemetry")) {
                exportCSV(database.exportTelemetryCSV(for: state.vin), name: "Telemetry")
            }
            .disabled(telemetryRecords.isEmpty)
            Button(L10n.text("Automation Log")) {
                exportCSV(database.exportCommandAuditsCSV(for: state.vin), name: "Automation-Log")
            }
            .disabled(commands.isEmpty)
            if state.powertrain.hasCombustionEngine {
                Button(L10n.text("Fuel Fill-Ups")) {
                    exportCSV(database.exportFuelEntriesCSV(for: state.vin), name: "Fuel")
                }
                .disabled(fuelEntries.isEmpty)
            }
            Button(L10n.text("Cabin Climate")) {
                exportCSV(database.exportCabinClimateCSV(for: state.vin), name: "Cabin-Climate")
            }
            .disabled(cabinClimateRecords.isEmpty)
            Divider()
            Button(L10n.text("Copy Summary")) {
                HistoryExport.copyToClipboard(historySummaryText)
            }
            Button(L10n.text("Print / Save as PDF…")) {
                HistoryExport.printText(historySummaryText,
                                        jobTitle: "Hisingen History \(state.vin.suffix(6))")
            }
        } label: {
            Label(L10n.text("Export"), systemImage: "square.and.arrow.up")
                .font(.system(size: 10, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(L10n.text("Export history data"))
    }

    func metric(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(HisingenTheme.accent)
            Text(value).font(.system(size: 12, weight: .bold, design: .rounded)).lineLimit(1)
            Text(title).font(.system(size: 8.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }

    // MARK: - Month / year comparison

    var monthComparisonCard: some View {
        let thisMonth = snapshot.thisMonth
        let lastMonth = snapshot.lastMonth
        let thisYear = snapshot.thisYear
        let lastYear = snapshot.lastYear
        let hasMonth = thisMonth.distanceKm > 0 || thisMonth.energyKwh > 0 || lastMonth.distanceKm > 0 || lastMonth.energyKwh > 0
        guard hasMonth else { return AnyView(EmptyView()) }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "calendar", title: L10n.text("This Month vs Last"), color: .cyan)
                HStack(spacing: 8) {
                    comparisonMetric(L10n.text("Distance"),
                                     Format.distance(km: thisMonth.distanceKm, decimals: 0, unit: preferences.distanceUnit),
                                     delta(thisMonth.distanceKm, lastMonth.distanceKm), higherIsBetter: nil)
                    comparisonMetric(L10n.text("Energy"),
                                     Format.energyKwh(thisMonth.energyKwh),
                                     delta(thisMonth.energyKwh, lastMonth.energyKwh), higherIsBetter: nil)
                    if let thisConsumption = thisMonth.averageConsumption {
                        comparisonMetric(L10n.text("Consumption"),
                                         preferences.energyConsumptionUnit.format(kwhPer100Km: thisConsumption),
                                         lastMonth.averageConsumption.flatMap { delta(thisConsumption, $0) },
                                         higherIsBetter: false)
                    }
                }
                Text(L10n.text("Compares the elapsed part of this month against the same number of days last month."))
                    .font(.system(size: 8.5)).foregroundStyle(.tertiary)
                if lastYear.distanceKm > 0 || lastYear.energyKwh > 0 {
                    Divider().opacity(0.3)
                    HStack(spacing: 10) {
                        Text(L10n.text("Year to date")).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        if let d = delta(thisYear.distanceKm, lastYear.distanceKm) {
                            yoyChip(L10n.text("Distance"), d)
                        }
                        if let d = delta(thisYear.energyKwh, lastYear.energyKwh) {
                            yoyChip(L10n.text("Energy"), d)
                        }
                        Spacer()
                    }
                }
            }
        })
    }

    func delta(_ current: Double, _ previous: Double) -> Double? {
        guard previous > 0 else { return nil }
        return (current - previous) / previous * 100
    }

    func comparisonMetric(_ title: String, _ value: String, _ delta: Double?, higherIsBetter: Bool?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 12, weight: .bold, design: .rounded)).lineLimit(1)
            HStack(spacing: 4) {
                Text(title).font(.system(size: 8.5)).foregroundStyle(.secondary).lineLimit(1)
                if let delta {
                    Text(Format.signedPercent(delta))
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(deltaColor(delta, higherIsBetter: higherIsBetter))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)" + (delta.map { ", \(Format.signedPercent($0))" } ?? ""))
    }

    func deltaColor(_ delta: Double, higherIsBetter: Bool?) -> Color {
        guard let higherIsBetter, abs(delta) >= 1 else { return .secondary }
        let improved = higherIsBetter ? delta > 0 : delta < 0
        return improved ? HisingenTheme.semanticGood : HisingenTheme.semanticWarning
    }

    func yoyChip(_ title: String, _ delta: Double) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.system(size: 8.5)).foregroundStyle(.tertiary)
            Text(Format.signedPercent(delta))
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(Color.primary.opacity(0.04), in: Capsule())
    }

    // MARK: - Emissions

    var emissionsCard: AnyView {
        let electricKm = HistoryInsights.distanceCovered(from: odometerPoints)
            ?? trips.reduce(0) { $0 + $1.distanceKm }
        let consumption = HistoryInsights.averageEfficiency(of: efficiencyPoints)
        // Battery-only: on a plug-in hybrid the odometer span mixes electric and engine
        // kilometres, so an "avoided" figure that treats all of it as electric would be
        // misleading.
        guard state.powertrain.hasElectricRange, !state.powertrain.hasCombustionEngine,
              electricKm > 5,
              let consumption,
              let comparison = HistoryInsights.emissionsComparison(
                electricKm: electricKm,
                consumptionKwhPer100Km: consumption,
                gridGramsCO2PerKwh: preferences.gridCarbonIntensityGramsPerKwh)
        else { return AnyView(EmptyView()) }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "leaf.fill", title: L10n.text("Emissions vs Petrol"), color: .green)
                HStack(spacing: 12) {
                    curveStat(L10n.text("CO₂ Avoided"), Format.massKg(comparison.avoidedKgCO2))
                    curveStat(L10n.text("EV Generation"), Format.massKg(comparison.electricKgCO2))
                    curveStat(L10n.text("Petrol Equivalent"), Format.massKg(comparison.petrolKgCO2))
                }
                Text(L10n.format("Indicative only — assumes %@ g CO₂/kWh grid intensity and a %@ g CO₂/km petrol car, well-to-wheel. Set the grid figure with the \u{201C}grid_carbon_intensity_g_per_kwh\u{201D} preference.",
                                 Format.count(Int(preferences.gridCarbonIntensityGramsPerKwh)),
                                 Format.count(170)))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        })
    }

    var emptyCard: some View {
        Card {
            VStack(spacing: 8) {
                Image(systemName: "chart.xyaxis.line").font(.system(size: 22)).foregroundStyle(.secondary)
                Text(L10n.text("No history recorded yet")).font(.system(size: 12, weight: .semibold))
                Text(L10n.text("Hisingen records meaningful odometer changes, charging sessions and remote-command outcomes locally as new telemetry arrives."))
                    .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    var nothingInRangeCard: some View {
        Card {
            VStack(spacing: 8) {
                Image(systemName: "calendar.badge.exclamationmark").font(.system(size: 20)).foregroundStyle(.secondary)
                Text(L10n.text("Nothing recorded in this range")).font(.system(size: 12, weight: .semibold))
                Text(L10n.text("There is history outside the selected dates. Widen the period or choose “All”."))
                    .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(L10n.text("Show all history")) { period = .all }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Helpers

    func exportCSV(_ contents: String, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Hisingen-\(name)-\(state.vin.suffix(6)).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = L10n.format("Could not write %@: %@", url.lastPathComponent, error.localizedDescription)
        }
    }

    var historySummaryText: String {
        var lines: [String] = []
        lines.append("Hisingen — History summary")
        lines.append("Vehicle: …\(state.vin.suffix(6))")
        lines.append("Range: \(period.rawValue)")
        if let range = activeRange {
            lines.append("       \(Format.dateFormatter.string(from: range.lowerBound)) – \(Format.dateFormatter.string(from: range.upperBound))")
        }
        lines.append("Generated: \(Format.dateTimeFormatter.string(from: Date()))")
        lines.append("")
        let totalDistance = trips.reduce(0) { $0 + $1.distanceKm }
        lines.append("Trips: \(trips.count)  ·  Distance: \(Format.distance(km: totalDistance, decimals: 1, unit: preferences.distanceUnit))")
        let energy = chargingSessions.reduce(0) { $0 + $1.energyDeliveredKwh }
        lines.append("Charging sessions: \(chargingSessions.count)  ·  Energy: \(Format.energyKwh(energy))")
        if let cost = aggregateChargingCost() {
            lines.append("Estimated charging cost: \(Format.currency(cost.amount, symbol: cost.currency))")
        }
        if let average = HistoryInsights.averageEfficiency(of: efficiencyPoints) {
            lines.append("Average consumption: \(preferences.energyConsumptionUnit.format(kwhPer100Km: average))")
        }
        if let latest = batteryHealthRecords.first {
            lines.append("Battery state of health: \(String(format: "%.1f%%", latest.stateOfHealthPct)) at \(Format.distance(km: latest.odometerKm, decimals: 0, unit: preferences.distanceUnit))")
        }
        if let kmPerDay = HistoryInsights.averageKmPerDay(from: allTimeOdometerPoints) {
            lines.append("Average daily distance: \(Format.distance(km: kmPerDay, decimals: 1, unit: preferences.distanceUnit))")
        }
        let stats = commandStatistics
        if stats.totalCount > 0, let rate = stats.successRatePct {
            lines.append("Remote commands: \(stats.totalCount)  ·  success \(String(format: "%.0f%%", rate))")
        }
        return lines.joined(separator: "\n")
    }
}
