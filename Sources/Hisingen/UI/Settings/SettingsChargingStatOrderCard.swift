import SwiftUI

/// Up/down editor for the order of the Charging card's detail rows (Settings → General).
/// Rows absent from the saved order keep their natural position after the ordered ones.
/// Extracted from `SettingsView`; operates directly on `preferences.chargingStatOrder`
/// through `PreferenceBinder`, so it carries no local `@State`.
@MainActor
struct SettingsChargingStatOrderCard: View {
    let binder: PreferenceBinder

    private static let titles: [String: String] = [
        "connection": "Charger Connection", "type": "Charging Type", "draw": "Current Draw",
        "limit": "Current Limit", "voltage": "Voltage", "target": "Target Limit",
        "powerModule": "Power Module", "timeToTarget": "Time to Target",
        "timeToMinSoc": "Time to Min SOC", "avgConsumption": "Avg Consumption",
        "avgSinceCharge": "Avg Since Last Charge", "energySinceCharge": "Energy Since Charge",
    ]
    private static let knownKeys = [
        "connection", "type", "draw", "limit", "voltage", "target", "powerModule",
        "timeToTarget", "timeToMinSoc", "avgConsumption", "avgSinceCharge", "energySinceCharge",
    ]

    private var order: [String] { binder.preferences.chargingStatOrder }

    private func setOrder(_ updated: [String]) {
        binder.preferences.chargingStatOrder = updated
        binder.bump()
        binder.notify(.presentation)
    }

    private var unorderedTitles: [String] {
        Set(Self.knownKeys).subtracting(order).map { Self.titles[$0] ?? $0 }.sorted()
    }

    var body: some View {
        let order = self.order
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardHeader(symbol: "list.number", title: L10n.text("Charging Stat Order"), color: .indigo)
                    Spacer()
                    if !order.isEmpty {
                        Button(L10n.text("Reset")) { setOrder([]) }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }
                Text(L10n.text("Reorders the detail rows on the Charging card. Unlisted rows keep their default position below."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                ForEach(Array(order.enumerated()), id: \.element) { index, id in
                    HStack {
                        Text(Self.titles[id] ?? id).font(.system(size: 11))
                        Spacer()
                        Button {
                            guard index > 0 else { return }
                            var updated = order
                            updated.swapAt(index, index - 1)
                            setOrder(updated)
                        } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        Button {
                            guard index < order.count - 1 else { return }
                            var updated = order
                            updated.swapAt(index, index + 1)
                            setOrder(updated)
                        } label: { Image(systemName: "arrow.down") }
                        .buttonStyle(.borderless)
                        .disabled(index == order.count - 1)
                    }
                    .padding(.vertical, 1)
                }
                // Remaining unlisted rows, offered for adoption into the order.
                ForEach(unorderedTitles, id: \.self) { pending in
                    HStack {
                        Text(pending).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.text("Add")) {
                            let key = Self.knownKeys.first { Self.titles[$0] == pending } ?? pending
                            setOrder(order + [key])
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}
