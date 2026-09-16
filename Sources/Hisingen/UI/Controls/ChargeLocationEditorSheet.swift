import SwiftUI

@MainActor
struct ChargeLocationEditorSheet: View {
    let defaultAmpLimit: Int
    var capabilities: VehicleOTACapabilities? = nil
    let onSave: (_ alias: String, _ ampLimit: Int, _ minimumSoc: Int, _ optimisedCharging: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var alias: String = ""
    @State private var ampLimit: Double = 16
    @State private var minimumSoc: Double = 0
    @State private var optimised: Bool = false
    @State private var showNameError = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(HisingenTheme.accent)
                Text(L10n.text("Save Charge Location"))
                    .hisType(.subhead, weight: .bold)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(L10n.text("Close"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider().opacity(HisingenTheme.dividerOpacity)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.text("Saves the vehicle's current position. Do this while parked where you normally charge."))
                        .hisType(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("Name"))
                            .hisType(.caption, weight: .medium)
                            .foregroundStyle(.secondary)
                        TextField(L10n.text("Home, Office…"), text: $alias)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L10n.text("Current limit"))
                                .hisType(.caption, weight: .medium)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.amps(Int(ampLimit.rounded())))
                                .hisType(.label, weight: .bold, design: .rounded)
                                .monospacedDigit()
                        }
                        let bounds = VehicleChargeBounds(capabilities: capabilities).amperageRange
                        Slider(value: $ampLimit, in: Double(bounds.lowerBound)...Double(bounds.upperBound), step: 1)
                            .tint(HisingenTheme.semanticWarning)
                            .disabled(capabilities?.controlSettings?.locationAmperage == false)
                            // A control greyed out with no reason reads as broken. The vehicle's
                            // own refusal is the explanation, so it is attached to the control.
                            .help(capabilities?.controlSettings?.locationAmperage == false
                                  ? L10n.text("This vehicle does not support a current limit per location.")
                                  : "")
                    }

                    if showNameError {
                        InlineValidationLabel(message: L10n.text("Give this location a name."))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L10n.text("Minimum charge"))
                                .hisType(.caption, weight: .medium)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.percent(minimumSoc))
                                .hisType(.label, weight: .bold, design: .rounded)
                                .monospacedDigit()
                        }
                        Slider(value: $minimumSoc, in: 0...100, step: 5).tint(HisingenTheme.semanticGood)
                    }

                    Toggle(L10n.text("Optimised charging"), isOn: $optimised)
                        .disabled(capabilities?.controlSettings?.locationOptimization == false)
                        .hisType(.label)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .padding(16)
            }

            Divider().opacity(HisingenTheme.dividerOpacity)
            HStack {
                // Escape closes it, and Cancel is the platform's cancel action rather than a
                // button that merely says Cancel — the pattern the rest of the app already uses.
                Button(L10n.text("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
                Button(L10n.text("Save")) {
                    let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                    // A blank name used to be swapped for "Charge location" on the way out, so the
                    // reader got a saved location they had not named and no chance to name it. The
                    // sheet validates instead, through the shared label every other form uses.
                    guard !trimmedAlias.isEmpty else { showNameError = true; return }
                    onSave(
                        trimmedAlias,
                        capabilities?.controlSettings?.locationAmperage == false ? 0 : Int(ampLimit.rounded()),
                        Int(minimumSoc.rounded()),
                        optimised
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(HisingenTheme.accent)
                .foregroundStyle(HisingenTheme.accentOn)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        // Pinned at 360x380, so larger text was clipped rather than reflowing, while its sibling
        // sheet reads `dynamicTypeSize` and grows. A minimum, not a fixed size: it still opens at
        // the size it always did and expands when the reader asks for larger type.
        .frame(minWidth: 360, minHeight: 380)
        .background(HisingenTheme.canvas)
        .onAppear {
            let bounds = VehicleChargeBounds(capabilities: capabilities).amperageRange
            ampLimit = Double(min(bounds.upperBound, max(bounds.lowerBound, defaultAmpLimit)))
        }
    }
}
