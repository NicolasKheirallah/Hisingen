import SwiftUI

@MainActor
struct SettingsChargingPlannerCard: View {
    let binder: PreferenceBinder
    var onOpenAutomation: (() -> Void)? = nil

    private var prefs: PreferencesStore { binder.preferences }

    private var powerChoices: [Double] {
        let presets = [3.7, 7.4, 11.0, 22.0]
        let current = prefs.electricityChargerPowerKw
        return presets.contains(current) ? presets : (presets + [current]).sorted()
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "chart.bar", title: L10n.text("Charging Planner"), color: HisingenTheme.semanticWarning)
                SettingsFeatureToggleRow(
                    binder: binder,
                    feature: .smartChargingPlanner,
                    symbol: "bolt",
                    title: "Smart Charging Planner",
                    detail: "Show the cheapest charging window to your charge limit, from Swedish spot prices"
                )
                if prefs.features.contains(.smartChargingPlanner) {
                    Divider().opacity(HisingenTheme.dividerOpacity)
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("Charging Power"))
                                .hisType(.body, weight: .medium)
                            Text(L10n.text("Used to estimate how many charging hours are needed"))
                                .hisType(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: binder(\.electricityChargerPowerKw)) {
                            ForEach(powerChoices, id: \.self) { option in
                                Text(Format.powerKw(option)).tag(option)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel(L10n.text("Charging Power"))
                        .controlSize(.small)
                        .frame(maxWidth: 160)
                    }
                    if let onOpenAutomation {
                        NavigationRow(title: L10n.text("Open Plan Automations"), action: onOpenAutomation)
                    }
                }
            }
        }
    }
}

@MainActor
struct PlannerAutoStartControl: View {
    let binder: PreferenceBinder

    @State private var showAutoStartConfirmation = false

    private var prefs: PreferencesStore { binder.preferences }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(L10n.text("Auto-Start Charging in the Window"))
                        .hisType(.body, weight: .medium)
                    InformationButton(message: L10n.text("When the planned window opens, Hisingen sends the same start-charging command as the Controls tab, only while the vehicle is plugged in and below its charge limit. Requires the Charging Controls feature."))
                }
                Text(L10n.text("Sends the start-charging command automatically while the window runs"))
                    .hisType(.caption)
                    .hisCaptionLeading()
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { prefs.plannerAutoStartEnabled },
                set: { enabled in
                    if enabled {
                        showAutoStartConfirmation = true
                    } else {
                        prefs.plannerAutoStartEnabled = false
                        binder.bump()
                        binder.notify(.features)
                    }
                }
            ))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .confirmationDialog(
            L10n.text("Allow automatic charging commands?"),
            isPresented: $showAutoStartConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("Allow Auto-Start")) {
                prefs.plannerAutoStartEnabled = true
                binder.bump()
                binder.notify(.features)
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("Hisingen will send a start-charging command without another prompt when the planned cheap-price window opens, but only while the vehicle is plugged in and below its charge limit."))
        }
    }
}
