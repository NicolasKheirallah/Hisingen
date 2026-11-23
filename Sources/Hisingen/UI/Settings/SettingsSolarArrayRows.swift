import SwiftUI

/// The reader's own solar panels, optional. With a size, tilt and direction the planner's solar
/// line also estimates output from the radiation on the panels. The size stays on this Mac; only
/// the tilt and direction go to Open-Meteo, to ask for the radiation on that plane.
@MainActor
struct SettingsSolarArrayRows: View {
    let binder: PreferenceBinder
    @State private var sizeText = ""

    private var prefs: PreferencesStore { binder.preferences }

    private var sizeIsValid: Bool {
        let trimmed = sizeText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        guard let value = NumberParsing.decimal(from: trimmed) else { return false }
        return (0...SolarArray.maximumKwp).contains(value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Text(L10n.text("Solar panels"))
                    .hisType(.body, weight: .medium)
                InformationButton(message: L10n.text("Optional. With your panel size and direction the solar forecast also estimates output from Open-Meteo's radiation on the panels. The size stays on this Mac; only the tilt and direction are sent."))
            }
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("Array size"))
                        .hisType(.body)
                    Text(L10n.text("Peak power in kWp. Leave empty to show radiation only."))
                        .hisType(.caption)
                        .hisCaptionLeading()
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HisTextField("0", text: $sizeText)
                    .frame(width: 55)
                    .multilineTextAlignment(.trailing)
                    .controlSize(.small)
                    .accessibilityLabel(L10n.text("Array size"))
                    .onChange(of: sizeText) { _, _ in commitSize() }
                Text(verbatim: "kWp")
                    .hisType(.label)
                    .foregroundStyle(.secondary)
            }
            if !sizeIsValid {
                InlineValidationLabel(message: L10n.text("Enter a size between 0 and 100 kWp."))
            }
            if prefs.solarArrayKwp > 0 {
                HStack {
                    Text(L10n.text("Panel tilt"))
                        .hisType(.body)
                    Spacer()
                    Stepper(value: binder(\.solarArrayTiltDegrees), in: 0...90, step: 5) {
                        Text(L10n.format("%@°", Format.number(prefs.solarArrayTiltDegrees, decimals: 0)))
                            .hisType(.label, design: .monospaced)
                    }
                    .controlSize(.small)
                    .accessibilityLabel(L10n.text("Panel tilt"))
                }
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.text("Panel direction"))
                            .hisType(.body)
                        Text(L10n.text("0° is south, -90° east, 90° west."))
                            .hisType(.caption)
                            .hisCaptionLeading()
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Stepper(value: binder(\.solarArrayAzimuthDegrees), in: -180...180, step: 15) {
                        Text(L10n.format("%@°", Format.number(prefs.solarArrayAzimuthDegrees, decimals: 0)))
                            .hisType(.label, design: .monospaced)
                    }
                    .controlSize(.small)
                    .accessibilityLabel(L10n.text("Panel direction"))
                }
            }
        }
        .onAppear {
            sizeText = prefs.solarArrayKwp > 0 ? Format.number(prefs.solarArrayKwp, decimals: 1) : ""
        }
    }

    /// An empty field turns the estimate off; a number outside 0 to 100 is left uncommitted and
    /// the validation line says why.
    private func commitSize() {
        let trimmed = sizeText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            prefs.solarArrayKwp = 0
        } else if let value = NumberParsing.decimal(from: trimmed), (0...SolarArray.maximumKwp).contains(value) {
            prefs.solarArrayKwp = value
        } else {
            return
        }
        binder.bump()
    }
}
