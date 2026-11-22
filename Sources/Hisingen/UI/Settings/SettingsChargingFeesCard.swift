import SwiftUI

/// Settings, Electricity: parking-style fees a charger or a charging location charges when a car
/// stays plugged in after the charge has finished. Rates are the reader's own, typed from their
/// charger's price list, so no default number is suggested.
@MainActor
struct SettingsChargingFeesCard: View {
    let binder: PreferenceBinder
    var pairings: [HomeChargingPairing]

    @State private var scope: ChargingOverstayRule.Scope = .charger
    @State private var chargerID = ""
    @State private var locationName = ""
    @State private var graceMinutes = 10
    @State private var amountText = ""
    @State private var unit: ChargingOverstayRule.Unit = .perHour
    @State private var currency = ""

    private var preferences: PreferencesStore { binder.preferences }
    private var rules: [ChargingOverstayRule] { preferences.chargingOverstayRules }

    private var amount: Double? {
        let cleaned = amountText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value.isFinite, value > 0 else { return nil }
        return value
    }

    private var target: String {
        switch scope {
        case .charger: return chargerID
        case .location: return locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var canAdd: Bool { !target.isEmpty && amount != nil }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "parkingsign.circle", title: L10n.text("Idle and Overstay Fees"),
                           color: HisingenTheme.semanticWarning)
                Text(L10n.text("Charge a fee when a car stays plugged in after charging finishes. Hisingen shows it on a session only where the paired charger recorded the session running past the charge's end."))
                    .hisType(.caption)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if rules.isEmpty {
                    Text(L10n.text("No fee rules yet. Add one for a charger or a location."))
                        .hisType(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 4) {
                        ForEach(rules) { rule in
                            ruleRow(rule)
                            if rule.id != rules.last?.id {
                                Divider().opacity(HisingenTheme.dividerOpacity)
                            }
                        }
                    }
                }

                PanelRule()
                addForm
            }
        }
        .onAppear {
            if currency.isEmpty { currency = preferences.currencySymbol }
            if chargerID.isEmpty { chargerID = pairings.first?.chargerID ?? "" }
        }
    }

    private func ruleRow(_ rule: ChargingOverstayRule) -> some View {
        HStack(spacing: 8) {
            Image(systemName: rule.scope == .charger ? "powerplug" : "mappin.and.ellipse")
                .hisType(.body)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(scopeLabel(rule))
                    .hisType(.label, weight: .medium)
                Text(L10n.format("%@ after %d min grace", rule.rateText, rule.graceMinutes))
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button(L10n.text("Remove"), role: .destructive) {
                    preferences.removeChargingOverstayRule(id: rule.id)
                    binder.bump()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .hisType(.body)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(L10n.format("Options for the %@ rule", scopeLabel(rule)))
        }
        .padding(.vertical, 2)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: $scope) {
                    Text(L10n.text("Charger")).tag(ChargingOverstayRule.Scope.charger)
                    Text(L10n.text("Location")).tag(ChargingOverstayRule.Scope.location)
                }
                .labelsHidden()
                .accessibilityLabel(L10n.text("Rule applies to"))
                .controlSize(.small)
                .frame(maxWidth: 120)

                if scope == .charger {
                    Picker("", selection: $chargerID) {
                        ForEach(pairings, id: \.identity) { pairing in
                            Text(pairing.chargerName.isEmpty ? pairing.chargerID : pairing.chargerName)
                                .tag(pairing.chargerID)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(L10n.text("Charger"))
                    .controlSize(.small)
                    .frame(maxWidth: 200)
                    .disabled(pairings.isEmpty)
                    if pairings.isEmpty {
                        Text(L10n.text("Pair a charger first."))
                            .hisType(.micro)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    TextField(L10n.text("Location name"), text: $locationName)
                        .hisField()
                        .accessibilityLabel(L10n.text("Location name"))
                }
            }

            HStack(spacing: 8) {
                Text(L10n.text("Grace period"))
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $graceMinutes) {
                    ForEach([0, 5, 10, 15, 20, 30, 45, 60], id: \.self) { minutes in
                        Text(L10n.format("%d min", minutes)).tag(minutes)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(L10n.text("Grace period"))
                .controlSize(.small)
                .frame(maxWidth: 90)

                Text(L10n.text("Fee"))
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: $amountText)
                    .hisField()
                    .frame(width: 76)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(L10n.text("Fee"))
                TextField("", text: $currency)
                    .hisField()
                    .frame(width: 48)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(L10n.text("Currency"))
                Picker("", selection: $unit) {
                    ForEach(ChargingOverstayRule.Unit.allCases, id: \.self) { unit in
                        Text(unit.displayName).tag(unit)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(L10n.text("Fee unit"))
                .controlSize(.small)
                .frame(maxWidth: 130)
                Spacer(minLength: 0)
            }

            Button {
                add()
            } label: {
                Text(L10n.text("Add Rule")).frame(minHeight: 24)
            }
            .buttonStyle(.hisSecondary)
            .controlSize(.small)
            .disabled(!canAdd)
        }
    }

    private func add() {
        guard let amount, !target.isEmpty else { return }
        let symbol = currency.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences.addChargingOverstayRule(ChargingOverstayRule(
            scope: scope, target: target, graceMinutes: graceMinutes,
            amount: amount, unit: unit,
            currencySymbol: symbol.isEmpty ? preferences.currencySymbol : symbol
        ))
        amountText = ""
        if scope == .location { locationName = "" }
        binder.bump()
    }

    private func scopeLabel(_ rule: ChargingOverstayRule) -> String {
        switch rule.scope {
        case .charger:
            let name = pairings.first { $0.chargerID == rule.target }?.chargerName ?? ""
            return name.isEmpty ? rule.target : name
        case .location:
            return rule.target
        }
    }

}
