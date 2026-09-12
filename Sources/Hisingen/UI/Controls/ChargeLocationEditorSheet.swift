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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(HisingenTheme.accent)
                Text(L10n.text("Save Charge Location"))
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.text("Saves the vehicle's current position. Do this while parked where you normally charge."))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("Name"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField(L10n.text("Home, Office…"), text: $alias)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L10n.text("Current limit"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.amps(Int(ampLimit.rounded())))
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        let bounds = VehicleChargeBounds(capabilities: capabilities).amperageRange
                        Slider(value: $ampLimit, in: Double(bounds.lowerBound)...Double(bounds.upperBound), step: 1)
                            .tint(.orange)
                            .disabled(capabilities?.controlSettings?.locationAmperage == false)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L10n.text("Minimum charge"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.percent(minimumSoc))
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        Slider(value: $minimumSoc, in: 0...100, step: 5).tint(.green)
                    }

                    Toggle(L10n.text("Optimised charging"), isOn: $optimised)
                        .disabled(capabilities?.controlSettings?.locationOptimization == false)
                        .font(.system(size: 11))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .padding(16)
            }

            Divider().opacity(0.4)
            HStack {
                Button(L10n.text("Cancel")) { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
                Button(L10n.text("Save")) {
                    let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(
                        trimmedAlias.isEmpty ? L10n.text("Charge location") : trimmedAlias,
                        capabilities?.controlSettings?.locationAmperage == false ? 0 : Int(ampLimit.rounded()),
                        Int(minimumSoc.rounded()),
                        optimised
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(HisingenTheme.accent)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 360, height: 380)
        .background(HisingenTheme.canvas)
        .onAppear {
            let bounds = VehicleChargeBounds(capabilities: capabilities).amperageRange
            ampLimit = Double(min(bounds.upperBound, max(bounds.lowerBound, defaultAmpLimit)))
        }
    }
}
