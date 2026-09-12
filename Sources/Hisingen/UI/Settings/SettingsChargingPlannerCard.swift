import SwiftUI

/// Settings → Features → "Charging Planner": the opt-in switch for the smart charging
/// planner plus its inputs — the Swedish spot-price zone (SE1–SE4, with a suggestion
/// from the vehicle's GPS when one is available), the charger output used to turn needed
/// energy into whole charging hours, the window-open / prices-published banners, and the
/// separate auto-start consent. The feature is off by default; enabling it here gates
/// both the daily price fetch and the dashboard card. Prices come from
/// elprisetjustnu.se, fetched once a day after publication.
@MainActor
struct SettingsChargingPlannerCard: View {
    let binder: PreferenceBinder
    var state: VehicleState? = nil

    private var prefs: PreferencesStore { binder.preferences }
    private var isEnabled: Bool { prefs.features.contains(.smartChargingPlanner) }

    private static let powerOptions: [Double] = [3.7, 7.4, 11.0, 22.0]

    private var powerChoices: [Double] {
        let current = prefs.electricityChargerPowerKw
        return Self.powerOptions.contains(current) ? Self.powerOptions : (Self.powerOptions + [current]).sorted()
    }

    /// GPS-based zone suggestion, shown only when it is available and differs from the
    /// current pick. Approximate by design — the real borders bend around municipalities.
    private var suggestedZone: ElspotZone? {
        guard let latitude = state?.location?.latitude else { return nil }
        let suggestion = ChargingPlannerSupport.suggestedZone(latitude: latitude)
        return suggestion == prefs.electricityPriceZone ? nil : suggestion
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "chart.bar.fill", title: L10n.text("Charging Planner"), color: .orange)

                SettingsFeatureToggleRow(
                    binder: binder,
                    feature: .smartChargingPlanner,
                    symbol: "bolt.fill",
                    title: "Smart Charging Planner",
                    detail: "Show the cheapest charging window to your charge limit, from Swedish spot prices"
                )

                if isEnabled {
                    Divider().opacity(0.4)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Price Zone"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("Spot-price area you live in"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: binder(\.electricityPriceZone)) {
                            ForEach(ElspotZone.allCases) { zone in
                                Text(zone.title).tag(zone)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 220)
                    }

                    if let suggestedZone {
                        HStack(spacing: 6) {
                            Image(systemName: "location")
                                .font(.system(size: 10))
                                .foregroundStyle(HisingenTheme.accent)
                            Text(L10n.format("The vehicle's location suggests %@", suggestedZone.title))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Button(L10n.text("Use")) {
                                prefs.electricityPriceZone = suggestedZone
                                binder.bump()
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .accessibilityLabel(L10n.format("Use %@", suggestedZone.title))
                        }
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Charging Power"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("Used to estimate how many charging hours are needed"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: binder(\.electricityChargerPowerKw)) {
                            ForEach(powerChoices, id: \.self) { option in
                                Text(Format.powerKw(option)).tag(option)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 160)
                    }

                    Divider().opacity(0.4)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Notify When the Cheap Window Opens"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("One banner per window, respecting quiet hours"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: binder(\.notifyPlannerWindowStart))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Notify When Tomorrow's Prices Arrive"))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.text("One daily banner after 14:15 with the cheapest hour"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: binder(\.notifyPlannerPricesPublished))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(L10n.text("Auto-Start Charging in the Window"))
                                    .font(.system(size: 12, weight: .medium))
                                InformationButton(message: L10n.text("When the planned window opens, Hisingen sends the same start-charging command as the Controls tab — only while the vehicle is plugged in and below its charge limit. Requires the Charging Controls feature."))
                            }
                            Text(L10n.text("Sends the start-charging command automatically while the window runs"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: binder(\.plannerAutoStartEnabled))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    Text(L10n.text("Prices are fetched once a day after 14:15 and exclude taxes and grid fees. Source: elprisetjustnu.se."))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
