import AppKit
import SwiftUI
import UniformTypeIdentifiers

// `HistoryDashboardView` – period picker, overview card, month/year comparison, emissions
// card, the Export menu, and the empty / nothing-in-range states.

extension HistoryDashboardView {
    // MARK: - Period picker

    func periodPicker(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Picker(L10n.text("History Period"), selection: $period) {
                    ForEach(HistoryPeriod.allCases.filter { $0 != .custom }) { item in
                        Text(L10n.text(item.rawValue)).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Every sibling control on this tab is `.small`; the period picker alone was at the
                // default size, so the filter was the loudest element on a data tab and the first to
                // overflow at a narrow panel width.
                .controlSize(.small)
                .accessibilityLabel(L10n.text("History Period"))

                Button {
                    showCustomRangeEditor = true
                } label: {
                    Image(systemName: period == .custom ? "calendar.badge.checkmark" : "calendar")
                        .hisType(.label, weight: .medium)
                }
                .buttonStyle(.pressable)
                .help(L10n.text("Pick a custom date range"))
                .accessibilityLabel(L10n.text("Custom date range"))
                .popover(isPresented: $showCustomRangeEditor, arrowEdge: .bottom) { customRangePopover }

                Button {
                    bumpRefresh()
                } label: {
                    Image(systemName: isLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .hisType(.label, weight: .medium)
                        .frame(width: 14, height: 14)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                }
                .buttonStyle(.pressable)
                // A re-tap during a load queues another refresh via `refreshToken`;
                // disabling the button froze the control for the whole load instead.
                .help(L10n.text("Reload history from the local database"))
                .accessibilityLabel(L10n.text("Refresh history"))

                historyJumpMenu(proxy: proxy)
            }

            // History describes energy, cost and range, and it was the one data surface that never
            // said whether the snapshot behind those numbers was current. Info, the Vehicle tab and
            // the status item all do. Shown only when there is something to say.
            if state.hasOldData() || state.freshness.isCached {
                HStack(spacing: 4) {
                    Image(systemName: state.freshness.isCached ? "wifi.slash" : "moon.stars.fill")
                        .hisType(.micro)
                        .accessibilityHidden(true)
                    Text(state.freshness.isCached
                         ? L10n.text("Showing an offline copy")
                         : state.freshnessDescription)
                        .hisType(.micro, weight: .semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .truncationMode(.middle)
                    Spacer()
                }
                .foregroundStyle(HisingenTheme.semanticWarning)
                .accessibilityElement(children: .combine)
            }

            HStack(spacing: 4) {
                Image(systemName: "info.circle").hisType(.nano)
                if period == .custom {
                    Text(L10n.format("Custom range: %@–%@",
                                     Format.dateFormatter.string(from: min(customRangeStart, customRangeEnd)),
                                     Format.dateFormatter.string(from: max(customRangeStart, customRangeEnd))))
                        .hisType(.nano, weight: .medium)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.text("Battery health, odometer totals and lifetime cost always use full history, regardless of the range above."))
                        .hisType(.nano)
                }
                Spacer()
                if snapshot.truncated {
                    Text(L10n.text("Older rows beyond the cap are not shown."))
                        .hisType(.nano)
                        .foregroundStyle(HisingenTheme.semanticWarning.opacity(0.9))
                }
            }
            .foregroundStyle(.tertiary)
        }
    }

    var customRangePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Custom Range")).hisType(.body, weight: .semibold)
            DatePicker(L10n.text("From"), selection: $customRangeStart,
                       in: ...customRangeEnd, displayedComponents: .date)
                .hisType(.label)
            DatePicker(L10n.text("To"), selection: $customRangeEnd,
                       in: customRangeStart...Date(), displayedComponents: .date)
                .hisType(.label)
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
        let totalDistance = aggregateTrips.reduce(0) { $0 + $1.distanceKm }
        let drivingTime = aggregateTrips.reduce(0) { $0 + $1.duration }
        let energy = chargingSessions.reduce(0) { $0 + $1.energyDeliveredKwh }
        let estimatedCost = aggregateChargingCost()
        let serviceProjection = HistoryInsights.projectService(
            currentOdometerKm: state.maintenance.odometerKm.map(Double.init),
            distanceToServiceKm: state.maintenance.service.distanceToServiceKm,
            daysToService: state.maintenance.service.daysToService,
            odometerPoints: allTimeOdometerPoints
        )
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: "chart.xyaxis.line", title: L10n.text("History Overview"), color: HisingenTheme.chartInfo)
                    Spacer()
                    if state.powertrain.hasCombustionEngine {
                        Button { showFuelSheet = true } label: {
                            Label(L10n.text("Add Fuel"), systemImage: "drop.fill")
                                .hisType(.caption, weight: .medium)
                        }
                        .buttonStyle(.pressable)
                        .help(L10n.text("Log a fill-up so fuel spend is included in cost estimates"))
                    }
                    exportMenu
                }
                HStack(spacing: 10) {
                    metric(L10n.text("Distance"), Format.distance(km: totalDistance, decimals: 1, unit: preferences.distanceUnit), "road.lanes")
                    metricColumnDivider
                    metric(L10n.text("Trips"), Format.count(aggregateTrips.count), "car.side")
                    metricColumnDivider
                    metric(L10n.text("Driving"), Format.shortDuration(minutes: Int(drivingTime / 60)), "clock")
                }
                HStack(spacing: 10) {
                    metric(L10n.text("Charge Sessions"), Format.count(chargingSessions.count), "bolt.fill")
                    metricColumnDivider
                    metric(L10n.text("Estimated Energy"), Format.energyKwh(energy), "bolt.circle")
                    metricColumnDivider
                    metric(
                        L10n.text("Estimated Cost"),
                        estimatedCost.map { Format.currency($0.amount, symbol: $0.currency) } ?? "–",
                        "creditcard"
                    )
                }
                if estimatedCost == nil, !chargingSessions.isEmpty {
                    footnote("exclamationmark.triangle",
                             L10n.text("Charging cost spans multiple currencies, so it is not totalled here. See the per-location breakdown below."))
                }
                // No fail-open `?? Date()`. It read as a real projection of "today", which is the
                // one answer a service date must never invent; a missing date is stated as missing.
                if let serviceProjection, serviceProjection.projectedDate != nil
                    || serviceProjection.projectedOdometerKm != nil {
                    HStack(spacing: 5) {
                        Image(systemName: "wrench.and.screwdriver")
                            .hisType(.caption).foregroundStyle(HisingenTheme.accent)
                        Text(serviceProjection.projectedDate.map {
                            L10n.format("Next service projected around %@",
                                        Format.dateFormatter.string(from: $0))
                        } ?? L10n.text("Next service projection has no date."))
                            .hisType(.micro).foregroundStyle(.secondary)
                        if let odo = serviceProjection.projectedOdometerKm {
                            Text("· " + Format.distance(km: Int(odo.rounded()), unit: preferences.distanceUnit))
                                .hisType(.micro).foregroundStyle(.tertiary)
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
                            .hisType(.caption).foregroundStyle(HisingenTheme.accent)
                        Text(L10n.format("Lifetime charging cost ≈ %@ per %@",
                                         Format.currency(perUnit, symbol: preferences.currencySymbol, decimals: 3),
                                         preferences.distanceUnit == .kilometers ? "km" : "mi"))
                            .hisType(.micro).foregroundStyle(.secondary)
                        Text(L10n.text("(estimated)")).hisType(.nano).foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// One path for every export entry: the workspace decides how the CSV is built
    /// (period rows it is handed, or a full-history ledger query off-main).
    func exportThroughWorkspace(_ kind: HistoryWorkspace.ExportKind, name: String) {
        let vin = state.identity.vin
        let scope: HistoryWorkspace.ExportScope = exportScope == .selectedPeriod ? .selectedPeriod : .fullHistory
        let sessionID = selectedSession?.id
        let periodTrips = trips
        let periodSessions = chargingSessions
        Task { @MainActor in
            let csv = await history.exportCSV(kind, scope: scope, vin: vin, selectedSessionID: sessionID,
                                              periodTrips: periodTrips, periodSessions: periodSessions)
            exportCSV(csv, name: name)
        }
    }

    var exportMenu: some View {
        Menu {
            Picker(L10n.text("Range (trips & charging sessions)"), selection: $exportScope) {
                ForEach(ExportScope.allCases) { Text(L10n.text($0.rawValue)).tag($0) }
            }
            Divider()
            Button(L10n.text("Trips")) {
                exportThroughWorkspace(.trips, name: "Trips")
            }
            .disabled(trips.isEmpty)
            Button(L10n.text("Charging Sessions")) {
                exportThroughWorkspace(.chargingSessions, name: "Charging-Sessions")
            }
            .disabled(chargingSessions.isEmpty)
            Button(L10n.text("Session Samples")) {
                guard selectedSession != nil else { return }
                exportThroughWorkspace(.sessionSamples, name: "Charging-Samples")
            }
            .disabled(selectedSession == nil || selectedSessionCurve.isEmpty)
            Button(L10n.text("Battery Health")) {
                exportThroughWorkspace(.batteryHealth, name: "Battery-Health")
            }
            .disabled(batteryHealthRecords.isEmpty)
            Button(L10n.text("Air Quality")) {
                exportThroughWorkspace(.airQuality, name: "Air-Quality")
            }
            .disabled(airQualityRecords.isEmpty)
            Button(L10n.text("Telemetry")) {
                exportThroughWorkspace(.telemetry, name: "Telemetry")
            }
            .disabled(telemetryRecords.isEmpty)
            Button(L10n.text("Automation Log")) {
                exportThroughWorkspace(.commandAudits, name: "Automation-Log")
            }
            .disabled(commands.isEmpty)
            if state.powertrain.hasCombustionEngine {
                Button(L10n.text("Fuel Fill-Ups")) {
                    exportThroughWorkspace(.fuelEntries, name: "Fuel")
                }
                .disabled(fuelEntries.isEmpty)
            }
            Button(L10n.text("Cabin Climate")) {
                exportThroughWorkspace(.cabinClimate, name: "Cabin-Climate")
            }
            .disabled(cabinClimateRecords.isEmpty)
            Divider()
            Button(L10n.text("Full Backup (JSON)")) {
                let workspace = history
                let includeCoordinates = preferences.persistLocationHistory
                Task { @MainActor in
                    let data = await workspace.exportBackupJSON(includeCoordinates: includeCoordinates)
                    guard let data else {
                        exportError = L10n.text("The backup could not be created.")
                        return
                    }
                    exportJSON(data, name: "Full-Backup")
                }
            }
            Divider()
            Button(L10n.text("Copy Summary")) {
                HistoryExport.copyToClipboard(historySummaryText)
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                exportNotice = L10n.text("Summary copied")
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    exportNotice = nil
                }
            }
            Button(L10n.text("Print / Save as PDF…")) {
                HistoryExport.printText(historySummaryText,
                                        jobTitle: "Hisingen History \(state.identity.vin.suffix(6))")
            }
        } label: {
            Label(L10n.text("Export"), systemImage: "square.and.arrow.up")
                .hisType(.caption, weight: .medium)
        }
        .menuStyle(.borderlessButton)
        .hisCaptionLeading()
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(L10n.text("Export history data"))
    }

    /// One overview reading: a value over its label, typography on the panel glass. The old
    /// tile drew a filled rounded rectangle, which is a card by any definition and the one
    /// surface the 2026 grammar retired; the columns separate on hairlines instead.
    func metric(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: symbol).hisType(.caption).foregroundStyle(HisingenTheme.accent)
            Text(value)
                .hisType(.body, weight: .bold, design: .rounded).lineLimit(1)
                .minimumScaleFactor(0.9)
                .monospacedDigit()
                .hisTelemetryValue(value, reduceMotion: reduceMotion)
            Text(title).hisType(.nano).foregroundStyle(.secondary).lineLimit(1)
            .minimumScaleFactor(0.9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }

    /// The hairline that separates metric columns now that no column carries a fill.
    var metricColumnDivider: some View {
        Divider()
            .opacity(HisingenTheme.dividerOpacity)
            .frame(maxHeight: 30)
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
                CardHeader(symbol: "calendar", title: L10n.text("This Month vs Last"), color: HisingenTheme.chartInfo)
                HStack(spacing: 10) {
                    comparisonMetric(L10n.text("Distance"),
                                     Format.distance(km: thisMonth.distanceKm, decimals: 0, unit: preferences.distanceUnit),
                                     delta(thisMonth.distanceKm, lastMonth.distanceKm), higherIsBetter: nil)
                    metricColumnDivider
                    comparisonMetric(L10n.text("Energy"),
                                     Format.energyKwh(thisMonth.energyKwh),
                                     delta(thisMonth.energyKwh, lastMonth.energyKwh), higherIsBetter: nil)
                    metricColumnDivider
                    if let thisConsumption = thisMonth.averageConsumption {
                        comparisonMetric(L10n.text("Consumption"),
                                         preferences.energyConsumptionUnit.format(kwhPer100Km: thisConsumption),
                                         lastMonth.averageConsumption.flatMap { delta(thisConsumption, $0) },
                                         higherIsBetter: false)
                    }
                }
                Text(L10n.text("Compares the elapsed part of this month against the same number of days last month."))
                    .hisType(.nano).foregroundStyle(.tertiary)
                if lastYear.distanceKm > 0 || lastYear.energyKwh > 0 {
                    Divider().opacity(HisingenTheme.dividerOpacity)
                    HStack(spacing: 10) {
                        Text(L10n.text("Year to date")).hisType(.micro, weight: .semibold).foregroundStyle(.secondary)
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
            Text(value)
                .hisType(.body, weight: .bold, design: .rounded).lineLimit(1)
                .minimumScaleFactor(0.9)
                .monospacedDigit()
                .hisTelemetryValue(value, reduceMotion: reduceMotion)
            HStack(spacing: 4) {
                Text(title).hisType(.nano).foregroundStyle(.secondary).lineLimit(1)
                .minimumScaleFactor(0.9)
                if let delta {
                    let color = deltaColor(delta, higherIsBetter: higherIsBetter)
                    Text(Format.signedPercent(delta))
                        .hisType(.nano, weight: .semibold)
                        .foregroundStyle(color)
                        .hisAnimation(Motion.stateChange, value: color)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(title).hisType(.nano).foregroundStyle(.tertiary)
            Text(Format.signedPercent(delta))
                .hisType(.nano, weight: .semibold)
                .foregroundStyle(.secondary)
                .hisTelemetryValue(delta, reduceMotion: reduceMotion)
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(HisingenTheme.chipFill, in: Capsule())
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
                CardHeader(symbol: "leaf.fill", title: L10n.text("Emissions vs Petrol"), color: HisingenTheme.semanticGood)
                HStack(spacing: 12) {
                    curveStat(L10n.text("CO₂ Avoided"), Format.massKg(comparison.avoidedKgCO2))
                    curveStat(L10n.text("EV Generation"), Format.massKg(comparison.electricKgCO2))
                    curveStat(L10n.text("Petrol Equivalent"), Format.massKg(comparison.petrolKgCO2))
                }
                Text(L10n.format("Indicative only: assumes %@ g CO₂/kWh grid intensity and a %@ g CO₂/km petrol car, well-to-wheel. Set the grid figure in Settings → General → Grid Carbon Intensity.",
                                 Format.count(Int(preferences.gridCarbonIntensityGramsPerKwh)),
                                 Format.count(Int(HistoryInsights.petrolCarGramsCO2PerKm))))
                    .hisType(.micro).foregroundStyle(.tertiary)
                    .hisCaptionLeading()
                    .fixedSize(horizontal: false, vertical: true)
            }
        })
    }

    var emptyCard: some View {
        Card {
            HisingenEmptyState(
                symbol: "chart.xyaxis.line",
                title: L10n.text("No history recorded yet"),
                message: L10n.text("Hisingen records meaningful odometer changes, charging sessions and remote-command outcomes locally as new telemetry arrives.")
            )
        }
    }

    /// The third terminal state. A read failure is not an empty history, and saying "no history
    /// recorded yet" about a store that could not be opened is a false statement about the
    /// user's own data.
    var storeUnreadableCard: some View {
        Card {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .hisSymbolSize(20)
                    .foregroundStyle(HisingenTheme.semanticWarning)
                Text(L10n.text("History could not be read")).hisType(.body, weight: .semibold)
                Text(L10n.text("Hisingen could not read the local history database. Nothing has been deleted; this is a read failure, not an empty history."))
                    .hisType(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(L10n.text("Refresh history")) { Task { await loadDashboardData() } }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .frame(maxWidth: .infinity)
        }
    }

    var nothingInRangeCard: some View {
        Card {
            HisingenEmptyState(
                symbol: "calendar.badge.exclamationmark",
                title: L10n.text("Nothing recorded in this range"),
                message: L10n.text("There is history outside the selected dates. Widen the period or choose “All”.")
            ) {
                Button(L10n.text("Show all history")) { period = .all }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    // MARK: - Helpers

    func exportCSV(_ contents: String, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Hisingen-\(name)-\(state.identity.vin.suffix(6)).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = L10n.format("Could not write %@: %@", url.lastPathComponent, error.localizedDescription)
        }
    }

    func exportJSON(_ data: Data, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Hisingen-\(name)-\(state.identity.vin.suffix(6)).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            exportError = L10n.format("Could not write %@: %@", url.lastPathComponent, error.localizedDescription)
        }
    }

    /// The exported summary reads through L10n like every other surface, so a Swedish reader
    /// does not print an English report. Labels reuse the keys the tab already shows; the
    /// numbers go through `Format.number`, so the decimal separator matches the panel.
    var historySummaryText: String {
        var lines: [String] = []
        lines.append(L10n.text("Hisingen · History summary"))
        lines.append("\(L10n.text("Vehicle")): …\(state.identity.vin.suffix(6))")
        lines.append("\(L10n.text("Range")): \(period.rawValue)")
        if let range = activeRange {
            lines.append("       \(Format.dateFormatter.string(from: range.lowerBound))–\(Format.dateFormatter.string(from: range.upperBound))")
        }
        lines.append("\(L10n.text("Generated")): \(Format.dateTimeFormatter.string(from: Date()))")
        lines.append("")
        let totalDistance = aggregateTrips.reduce(0) { $0 + $1.distanceKm }
        lines.append("\(L10n.text("Trips")): \(aggregateTrips.count)  ·  \(L10n.text("Distance")): \(Format.distance(km: totalDistance, decimals: 1, unit: preferences.distanceUnit))")
        let energy = chargingSessions.reduce(0) { $0 + $1.energyDeliveredKwh }
        lines.append("\(L10n.text("Charge Sessions")): \(chargingSessions.count)  ·  \(L10n.text("Energy")): \(Format.energyKwh(energy))")
        if let cost = aggregateChargingCost() {
            lines.append("\(L10n.text("Estimated Cost")): \(Format.currency(cost.amount, symbol: cost.currency))")
        }
        if let average = HistoryInsights.averageEfficiency(of: efficiencyPoints) {
            lines.append("\(L10n.text("Average consumption")): \(preferences.energyConsumptionUnit.format(kwhPer100Km: average))")
        }
        if let latest = batteryHealthRecords.first {
            lines.append("\(L10n.text("Calculated State of Health (SoH)")): \(Format.percent(latest.stateOfHealthPct, decimals: 1)) · \(L10n.text("Odometer")): \(Format.distance(km: latest.odometerKm, decimals: 0, unit: preferences.distanceUnit, grouped: true))")
        }
        if let kmPerDay = HistoryInsights.averageKmPerDay(from: allTimeOdometerPoints) {
            lines.append("\(L10n.text("Average Daily Distance")): \(Format.distance(km: kmPerDay, decimals: 1, unit: preferences.distanceUnit))")
        }
        let stats = commandStatistics
        if stats.totalCount > 0, let rate = stats.successRatePct {
            lines.append("\(L10n.text("Remote commands")): \(stats.totalCount)  ·  \(Format.percent(rate, decimals: 0))")
        }
        return lines.joined(separator: "\n")
    }
}
