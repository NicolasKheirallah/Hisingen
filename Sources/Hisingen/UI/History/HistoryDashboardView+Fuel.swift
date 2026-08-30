import Charts
import SwiftUI

// `HistoryDashboardView` — fuel cards for combustion / PHEV vehicles: the fill-up sheet,
// the tank-to-tank economy chart, and the recent fill-ups list.

extension HistoryDashboardView {
    // MARK: - Fuel entries (hybrid / combustion)

    var fuelEntrySheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Log Fuel Fill-Up")).font(.system(size: 13, weight: .semibold))
            LabeledField(title: L10n.text("Volume (litres)"), text: $fuelLitersText)
            LabeledField(title: L10n.text("Price per litre"), text: $fuelPriceText)
            LabeledField(title: L10n.text("Odometer (km), optional"), text: $fuelOdometerText)
            HStack {
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) { showFuelSheet = false }
                Button(L10n.text("Save")) {
                    guard let liters = Double(fuelLitersText.replacingOccurrences(of: ",", with: ".")), liters > 0,
                          let price = Double(fuelPriceText.replacingOccurrences(of: ",", with: ".")) else { return }
                    let odo = Double(fuelOdometerText.replacingOccurrences(of: ",", with: "."))
                    _ = database.addFuelEntry(vin: state.vin, date: Date(), liters: liters,
                                              pricePerLiter: price, odometerKm: odo)
                    fuelLitersText = ""; fuelPriceText = ""; fuelOdometerText = ""
                    showFuelSheet = false
                    bumpRefresh()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            Text(L10n.text("Fill-ups are stored locally and included in lifetime cost-per-distance estimates. Add an odometer reading to unlock the economy trend."))
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 300)
    }

    var fuelEconomyCard: AnyView {
        let tuples = fuelEntries.map { (id: $0.id, date: $0.date, liters: $0.liters,
                                       pricePerLiter: $0.pricePerLiter, odometerKm: $0.odometerKm) }
        let points = HistoryInsights.fuelEconomyBetweenFills(tuples)
        let priceSeries = fuelEntries.filter { $0.pricePerLiter > 0 }.sorted { $0.date < $1.date }
        guard points.count >= 2 || priceSeries.count >= 3 else { return AnyView(EmptyView()) }
        let avgEconomy = points.isEmpty ? nil : points.reduce(0) { $0 + $1.litersPer100Km } / Double(points.count)
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardHeader(symbol: "fuelpump.fill", title: L10n.text("Fuel Economy"), color: .mint)
                    Spacer()
                    if let avgEconomy {
                        Text(Format.fuelEconomy(lPer100Km: avgEconomy, unit: preferences.fuelEconomyUnit))
                            .font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    }
                }
                if points.count >= 2 {
                    Chart(points) { point in
                        LineMark(
                            x: .value(L10n.text("Date"), point.date),
                            y: .value(L10n.text("Economy"), point.litersPer100Km)
                        )
                        .foregroundStyle(HisingenTheme.chartAttention)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.catmullRom)
                        PointMark(
                            x: .value(L10n.text("Date"), point.date),
                            y: .value(L10n.text("Economy"), point.litersPer100Km)
                        )
                        .symbolSize(14)
                        .foregroundStyle(HisingenTheme.chartAttention)
                    }
                    .chartYAxisLabel("L/100km")
                    .frame(height: chartHeight * 0.8)
                    .accessibilityLabel(L10n.text("Fuel economy between fill-ups chart"))
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
                    .chartYAxisLabel(L10n.format("%@/L", preferences.currencySymbol))
                    .frame(height: chartHeight * 0.55)
                    .accessibilityLabel(L10n.text("Fuel price per litre trend chart"))
                }
                Text(L10n.text("Economy is measured tank-to-tank and needs an odometer reading on each fill-up."))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        })
    }

    var recentFillsCard: AnyView {
        guard !fuelEntries.isEmpty else { return AnyView(EmptyView()) }
        let totalSpend = fuelEntries.reduce(0) { $0 + $1.liters * $1.pricePerLiter }
        let totalLitres = fuelEntries.reduce(0) { $0 + $1.liters }
        let avgPrice = totalLitres > 0 ? totalSpend / totalLitres : 0
        let pageSize = 8
        let pageCount = HistoryPagination.pageCount(itemCount: fuelEntries.count, pageSize: pageSize)
        // Clamp locally: a delete can shrink the list under the current page without a state
        // reset, and `HistoryPagination.page` already tolerates an out-of-range index.
        let page = min(max(0, fuelPage), max(0, pageCount - 1))
        let visible = HistoryPagination.page(of: fuelEntries, index: page, pageSize: pageSize)
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "drop.fill", title: L10n.text("Fuel Fill-Ups"), color: .mint)
                HStack(spacing: 12) {
                    curveStat(L10n.text("Total Spend"), Format.currency(totalSpend, symbol: preferences.currencySymbol))
                    curveStat(L10n.text("Total Volume"), Format.fuelVolume(liters: totalLitres, unit: preferences.fuelVolumeUnit))
                    if avgPrice > 0 {
                        curveStat(L10n.text("Avg Price/L"), Format.currency(avgPrice, symbol: preferences.currencySymbol, decimals: 3))
                    }
                }
                ForEach(visible) { entry in
                    HStack {
                        Text(Format.dateFormatter.string(from: entry.date)).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Format.fuelVolume(liters: entry.liters, unit: preferences.fuelVolumeUnit)) · \(Format.currency(entry.liters * entry.pricePerLiter, symbol: preferences.currencySymbol))")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                        Button { fuelEntryPendingDeletion = entry } label: {
                            Image(systemName: "trash").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.text("Delete fill-up"))
                    }
                    if entry.id != visible.last?.id { Divider().opacity(0.25) }
                }
                if pageCount > 1 {
                    HStack(spacing: 8) {
                        Button { fuelPage = max(0, page - 1) } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.borderless).disabled(page == 0)
                        Spacer()
                        Text(L10n.format("Page %d of %d", page + 1, pageCount))
                            .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        Button { fuelPage = min(pageCount - 1, page + 1) } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.borderless).disabled(page >= pageCount - 1)
                    }
                    .padding(.top, 2)
                }
            }
        })
    }
}
