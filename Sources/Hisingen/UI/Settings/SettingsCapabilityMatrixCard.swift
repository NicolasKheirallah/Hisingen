import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The vehicle capability matrix in Settings → Features: a filterable list of what the
/// selected vehicle supports, plus CSV export. Renders nothing when there is no vehicle.
/// Extracted from `SettingsView` (which previously returned it as an `AnyView`).
@MainActor
struct SettingsCapabilityMatrixCard: View {
    let state: VehicleState?
    @State private var capabilityFilter = CapabilityFilter.all
    @State private var exportFeedback: (message: String, isError: Bool)?

    @ViewBuilder
    var body: some View {
        if let state {
            let profile = state.capabilityProfile
            let items = VehicleCapability.displayed.filter { capabilityFilter.matches(profile.support(for: $0)) }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(symbol: "checklist", title: L10n.text("Vehicle Capability Matrix"), color: .blue)
                    Text(L10n.format("Capability assessment for %@ (%@)", state.modelName ?? L10n.text("Vehicle"), state.vin))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Picker(L10n.text("Capability filter"), selection: $capabilityFilter) {
                            ForEach(CapabilityFilter.allCases) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .accessibilityLabel(L10n.text("Capability filter"))

                        Spacer()

                        Button {
                            exportCapabilities(state: state)
                        } label: {
                            Label(L10n.text("Export Matrix"), systemImage: "square.and.arrow.up")
                        }
                        .controlSize(.small)
                    }

                    if let exportFeedback {
                        Label(exportFeedback.message, systemImage: exportFeedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(exportFeedback.isError ? Color.red : HisingenTheme.semanticGood)
                    }

                    // A degraded dashboard should explain itself here rather than only in the
                    // unified log — the cached snapshot keeps very little telemetry, so cards
                    // going quiet is otherwise indistinguishable from an unsupported vehicle.
                    if state.isCachedSnapshot {
                        degradedNotice(
                            symbol: "internaldrive",
                            text: L10n.text("Showing the last saved snapshot — most live telemetry is unavailable until the next successful refresh.")
                        )
                    } else if !state.unavailableFeatures.isEmpty {
                        degradedNotice(
                            symbol: "exclamationmark.arrow.triangle.2.circlepath",
                            text: L10n.format(
                                "The last refresh could not read: %@",
                                state.unavailableFeatures.map(\.title).sorted().joined(separator: ", ")
                            )
                        )
                    }

                    VStack(spacing: 6) {
                        ForEach(items, id: \.self) { cap in
                            let support = profile.support(for: cap)
                            HStack {
                                Text(cap.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(HisingenTheme.ink)
                                Spacer()
                                let color: Color = {
                                    switch support {
                                    case .supported: return HisingenTheme.semanticGood
                                    case .vehicleManaged: return .blue
                                    case .unavailable: return HisingenTheme.semanticWarning
                                    case .backendDependent: return .secondary
                                    }
                                }()
                                Pill(text: support.displayName, color: color, symbol: support.symbolName)
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    if items.isEmpty {
                        Text(L10n.text("No capabilities match this filter."))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    }

                    Text(L10n.text("\"Direct tyre-pressure values\" means numeric kPa readings. Many vehicles report a warning level per tyre instead (indirect TPMS); those warnings still appear on the vehicle overview and in notifications."))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func degradedNotice(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(HisingenTheme.semanticWarning)
            Text(text)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(HisingenTheme.semanticWarning.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func exportCapabilities(state: VehicleState) {
        let rows = VehicleCapability.displayed.map { capability in
            "\(csvCell(capability.title)),\(csvCell(state.capabilityProfile.support(for: capability).displayName))"
        }
        let csv = (["capability,support"] + rows).joined(separator: "\n") + "\n"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "capabilities_\(state.vin.prefix(8)).csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
                exportFeedback = (L10n.text("Capability matrix exported."), false)
            } catch {
                exportFeedback = (L10n.format("Export failed: %@", error.localizedDescription), true)
            }
        }
    }

    private func csvCell(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
