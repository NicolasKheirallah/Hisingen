import Charts
import SwiftUI

// `HistoryDashboardView` – fuel cards for combustion / PHEV vehicles: the fill-up sheet,
// the tank-to-tank economy chart, and the recent fill-ups list.

extension HistoryDashboardView {
    // MARK: - Fuel entries (hybrid / combustion)

    var fuelEntrySheet: some View {
        let validation = FuelFillUpValidation.validate(
            volumeText: fuelLitersText, priceText: fuelPriceText, odometerText: fuelOdometerText)
        return VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Log Fuel Fill-Up")).hisType(.heading, weight: .semibold)
            LabeledField(title: L10n.text("Volume (litres)"), text: $fuelLitersText,
                         reason: validation.reason(for: .volume))
            LabeledField(title: L10n.text("Price per litre"), text: $fuelPriceText,
                         reason: validation.reason(for: .price))
            LabeledField(title: L10n.text("Odometer (km), optional"), text: $fuelOdometerText,
                         reason: validation.reason(for: .odometer))
            HStack {
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) { showFuelSheet = false }
                Button(L10n.text("Save")) {
                    guard validation.isValid else { return }
                    _ = history.addFuelEntry(vin: state.identity.vin, date: Date(),
                                             liters: validation.liters,
                                             pricePerLiter: validation.pricePerLiter,
                                             odometerKm: validation.odometerKm)
                    fuelLitersText = ""; fuelPriceText = ""; fuelOdometerText = ""
                    showFuelSheet = false
                    bumpRefresh()
                }
                .buttonStyle(.hisProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!validation.isValid)
            }
            Text(L10n.text("Fill-ups are stored locally and included in lifetime cost-per-distance estimates. Add an odometer reading to unlock the economy trend."))
                .hisType(.micro).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300)
    }

    var fuelEconomyCard: AnyView {
        let tuples = fuelEntries.map { (id: $0.id, date: $0.date, liters: $0.liters,
                                       pricePerLiter: $0.pricePerLiter, odometerKm: $0.odometerKm) }
        let points = HistoryInsights.fuelEconomyBetweenFills(tuples)
        let priceSeries = fuelEntries.filter { $0.pricePerLiter > 0 }.sorted { $0.date < $1.date }
        guard points.count >= 2 || priceSeries.count >= 3 else {
            return AnyView(HistoryCardSurface {
                HisingenEmptyState(
                    symbol: "fuelpump",
                    title: L10n.text("Fuel trend needs more fill-ups"),
                    message: L10n.text("Add odometer readings to at least two fill-ups, or prices to three fill-ups.")
                )
            })
        }
        let avgEconomy = points.isEmpty ? nil : points.reduce(0) { $0 + $1.litersPer100Km } / Double(points.count)
        return AnyView(HistoryCardSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HistorySectionHeading(symbol: "fuelpump", title: L10n.text("Fuel Economy"), color: HisingenTheme.chartPositive)
                    Spacer()
                    if let avgEconomy {
                        Text(Format.fuelEconomy(lPer100Km: avgEconomy, unit: preferences.fuelEconomyUnit))
                            .hisType(.caption, weight: .semibold, design: .rounded).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                let fuelUnit = preferences.fuelEconomyUnit
                if points.count == 1, let only = points.first {
                    // A one-point series drew as a blank rectangle: `LineMark` alone has nothing to
                    // draw a line between, so the card showed an empty frame exactly when there was
                    // one reading to show.
                    Chart([only]) { point in
                        PointMark(
                            x: .value(L10n.text("Date"), point.date),
                            y: .value(L10n.text("Consumption"), fuelUnit.plotValue(lPer100Km: point.litersPer100Km))
                        )
                        .symbolSize(24)
                        .foregroundStyle(HisingenTheme.chartAttention)
                    }
                    .historyTimeAxis(spanning: [only.date])
                    .historyYAxis(fuelUnit.suffix)
                    .frame(height: chartHeight)
                    .accessibilityLabel(L10n.text("Fuel consumption trend chart"))
                    .accessibilityValue(chartAccessibilityValue(points: [fuelUnit.plotValue(lPer100Km: only.litersPer100Km)]))
                } else if points.count >= 2 {
                    HistoryScrubChart(items: points, date: { $0.date },
                                      callout: { "\(Format.dateFormatter.string(from: $0.date)) · \(Format.fuelEconomy(lPer100Km: $0.litersPer100Km, unit: fuelUnit))" }) {
                        ForEach(points) { point in
                            LineMark(
                                x: .value(L10n.text("Date"), point.date),
                                y: .value(L10n.text("Economy"), fuelUnit.plotValue(lPer100Km: point.litersPer100Km))
                            )
                            .foregroundStyle(HisingenTheme.chartAttention)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.linear)
                            PointMark(
                                x: .value(L10n.text("Date"), point.date),
                                y: .value(L10n.text("Economy"), fuelUnit.plotValue(lPer100Km: point.litersPer100Km))
                            )
                            .symbolSize(14)
                            .foregroundStyle(HisingenTheme.chartAttention)
                        }
                    }
                    .historyTimeAxis(spanning: points.map(\.date))
                    .historyYAxis(fuelUnit.suffix)
                    .frame(height: chartHeight * 0.8)
                    .accessibilityLabel(L10n.text("Fuel economy between fill-ups chart"))
                    .accessibilityValue(chartAccessibilityValue(points: points.map { fuelUnit.plotValue(lPer100Km: $0.litersPer100Km) }))
                    .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                        title: L10n.text("Fuel Economy"), yLabel: fuelUnit.suffix,
                        points: points.map { ($0.date, fuelUnit.plotValue(lPer100Km: $0.litersPer100Km)) }))
                    .hisAnimation(Motion.progress, value: lifetimeDataKey)
                }
                if priceSeries.count >= 3 {
                    Chart(priceSeries) { entry in
                        LineMark(
                            x: .value(L10n.text("Date"), entry.date),
                            y: .value(L10n.text("Price"), entry.pricePerLiter)
                        )
                        .foregroundStyle(HisingenTheme.chartInfo)
                        .interpolationMethod(.monotone)
                    }
                    .historyTimeAxis(spanning: priceSeries.map(\.date))
                    .historyYAxis(L10n.format("%@/L", preferences.currencySymbol))
                    .frame(height: chartHeight * 0.55)
                    .accessibilityLabel(L10n.text("Fuel price per litre trend chart"))
                    .accessibilityValue(chartAccessibilityValue(points: priceSeries.map { $0.pricePerLiter }))
                    .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                        title: L10n.text("Price"), yLabel: preferences.currencySymbol,
                        points: priceSeries.map { ($0.date, $0.pricePerLiter) }))
                    .hisAnimation(Motion.progress, value: lifetimeDataKey)
                }
                Text(L10n.text("Economy is measured tank-to-tank and needs an odometer reading on each fill-up."))
                    .hisType(.micro).foregroundStyle(.secondary)
            }
        })
    }

    var recentFillsCard: AnyView {
        let totalSpend = fuelEntries.reduce(0) { $0 + $1.liters * $1.pricePerLiter }
        let totalLitres = fuelEntries.reduce(0) { $0 + $1.liters }
        let avgPrice = totalLitres > 0 ? totalSpend / totalLitres : 0
        return AnyView(HistoryCardSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HistorySectionHeading(symbol: "drop", title: L10n.text("Fuel Fill-Ups"), color: HisingenTheme.chartPositive)
                    Spacer()
                    if state.powertrain.hasCombustionEngine {
                        Button(L10n.text("Add Fuel")) { showFuelSheet = true }
                            .buttonStyle(.hisSecondary)
                            .controlSize(.small)
                    }
                }
                if !fuelEntries.isEmpty {
                    fuelTotals(totalSpend: totalSpend, totalLitres: totalLitres, avgPrice: avgPrice)
                }
                PaginatedSection(items: fuelEntries, pageSize: preferences.historyPageSize(for: .historyRecentFills),
                                 emptyMessage: L10n.text("No fill-ups have been recorded.")) { visible, footer in
                    ForEach(visible) { entry in
                        HStack {
                            Text(Format.dateFormatter.string(from: entry.date)).hisType(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Format.fuelVolume(liters: entry.liters, unit: preferences.fuelVolumeUnit)) · \(Format.currency(entry.liters * entry.pricePerLiter, symbol: preferences.currencySymbol))")
                                .hisType(.label, weight: .semibold, design: .rounded)
                                .monospacedDigit()
                            Button { fuelEntryPendingDeletion = entry } label: {
                                Image(systemName: "trash").hisType(.micro).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.pressable)
                            .accessibilityLabel(L10n.text("Delete fill-up"))
                            .help(L10n.text("Delete fill-up"))
                        }
                        if entry.id != visible.last?.id { Divider().opacity(HisingenTheme.dividerOpacity) }
                    }
                    footer
                }
                // A delete bumps the refresh token and reloads the lifetime snapshot, so
                // this key changes when the removed row actually disappears.
                .hisAnimation(Motion.cardChange, value: lifetimeDataKey)
            }
        })
    }
    private func fuelTotals(totalSpend: Double, totalLitres: Double, avgPrice: Double) -> some View {
        HStack(spacing: 12) {
            curveStat(L10n.text("Total Spend"), Format.currency(totalSpend, symbol: preferences.currencySymbol))
            curveStat(L10n.text("Total Volume"), Format.fuelVolume(liters: totalLitres, unit: preferences.fuelVolumeUnit))
            if avgPrice > 0 {
                curveStat(L10n.text("Avg Price/L"), Format.currency(avgPrice, symbol: preferences.currencySymbol, decimals: 3))
            }
        }
    }

}
