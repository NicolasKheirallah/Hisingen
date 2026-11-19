import SwiftUI

@MainActor
struct SettingsGridCarbonSection: View {
    let binder: PreferenceBinder

    @State private var gridCarbonIntensity = ""
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
        }
        if !gridCarbonIntensity.isEmpty && !isValidGridCarbonIntensity(gridCarbonIntensity) {
            InlineValidationLabel(message: L10n.text("Enter an intensity between 1 and 1,200 g CO₂/kWh."))
        }
    }

    private func isValidGridCarbonIntensity(_ text: String) -> Bool {
        guard let value = NumberParsing.decimal(from: text) else { return false }
        return (1...1_200).contains(value)
    }
}
