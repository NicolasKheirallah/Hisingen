import SwiftUI

@MainActor
struct SettingsGridCarbonSection: View {
    let binder: PreferenceBinder

    @State private var gridCarbonIntensity = ""
    @State private var hasLiveCarbonKey = false
    @State private var keyDraft = ""
    @State private var keyError: String?
    private var preferences: PreferencesStore { binder.preferences }

    @ViewBuilder
    var body: some View {
        Text(L10n.text("Emissions")).hisType(.label, weight: .semibold).accessibilityAddTraits(.isHeader)

        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("Grid Carbon Intensity"))
                    .hisType(.body, weight: .medium)
                Text(L10n.text("For the emissions comparison in History"))
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                HisTextField("120", text: Binding(
                    get: { gridCarbonIntensity },
                    set: { text in
                        gridCarbonIntensity = text
                        if let intensity = NumberParsing.decimal(from: text),
                           (1...1_200).contains(intensity) {
                            preferences.gridCarbonIntensityGramsPerKwh = intensity
                            binder.bump()
                        }
                    }
                ))
                .frame(width: 55)
                .multilineTextAlignment(.trailing)
                .controlSize(.small)
                .accessibilityLabel(L10n.text("Grid Carbon Intensity"))
                Text(L10n.text("g CO₂/kWh"))
                    .hisType(.label)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            gridCarbonIntensity = preferences.gridCarbonIntensityGramsPerKwh.formatted(
                .number.locale(L10n.displayLocale).grouping(.never).precision(.fractionLength(0...3))
            )
            hasLiveCarbonKey = preferences.hasElectricityMapsKey
        }
        if !gridCarbonIntensity.isEmpty && !isValidGridCarbonIntensity(gridCarbonIntensity) {
            InlineValidationLabel(message: L10n.text("Enter an intensity between 1 and 1,200 g CO₂/kWh."))
        }

        Divider().opacity(HisingenTheme.dividerOpacity)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Live grid carbon"))
                        .hisType(.body, weight: .medium)
                    Text(L10n.text("Shows the carbon intensity now beside the charging plan. Without a key, no live line appears."))
                        .hisType(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if hasLiveCarbonKey {
                    Button(L10n.text("Remove")) {
                        preferences.clearElectricityMapsKey()
                        hasLiveCarbonKey = false
                        keyDraft = ""
                        keyError = nil
                        binder.bump()
                    }
                    .buttonStyle(.hisSecondary)
                    .controlSize(.small)
                }
            }
            if hasLiveCarbonKey {
                Label(L10n.text("Key saved"), systemImage: "checkmark.seal")
                    .hisType(.label, weight: .medium)
                    .foregroundStyle(HisingenTheme.semanticGood)
                Text(L10n.text("The live line appears only when Electricity Maps answers. The typed intensity above is still used for the emissions estimate."))
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    SecureField("", text: $keyDraft)
                        .hisField()
                        .accessibilityLabel(L10n.text("Electricity Maps API key"))
                    Button(L10n.text("Save")) {
                        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !key.isEmpty else { return }
                        do {
                            try preferences.saveElectricityMapsKey(key)
                            hasLiveCarbonKey = true
                            keyDraft = ""
                            keyError = nil
                            binder.bump()
                        } catch {
                            keyError = error.localizedDescription
                        }
                    }
                    .buttonStyle(.hisSecondary)
                    .controlSize(.small)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text(L10n.text("Create a free token at electricitymaps.com. It is stored in the macOS Keychain and never exported."))
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let keyError {
                InlineValidationLabel(message: keyError)
            }
        }
    }

    private func isValidGridCarbonIntensity(_ text: String) -> Bool {
        guard let value = NumberParsing.decimal(from: text) else { return false }
        return (1...1_200).contains(value)
    }
}
