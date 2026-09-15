import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The vehicle capability matrix in Settings → Features: a filterable list of what the
/// selected vehicle supports, plus CSV export. Renders nothing when there is no vehicle.
/// Extracted from `SettingsView` (which previously returned it as an `AnyView`).
@MainActor
struct SettingsCapabilityMatrixCard: View {
    let state: VehicleState?
    @Environment(\.preferencesStore) private var preferences
    @State private var capabilityFilter = CapabilityFilter.all
    @State private var exportFeedback: (message: String, isError: Bool)?

    @ViewBuilder
    var body: some View {
        if state == nil {
            // The card rendered nothing at all with no vehicle, so searching "capability" scrolled
            // to a heading with an absent card under it, and the reader was left to guess whether
            // the section was missing, broken or empty. §16: a dead end says what happened.
            UnavailableFeatureCard(
                symbol: "checklist",
                title: L10n.text("Vehicle Capability Matrix"),
                color: .blue,
                badge: L10n.text("No vehicle selected"),
                message: L10n.text("Choose a vehicle or sign in to see which capabilities this account can reach. The matrix is read from the vehicle itself, so it cannot be built without one."),
                state: .unavailable
            )
        } else if let state {
            let profile = state.capabilityProfile
            let items = VehicleCapability.displayed.filter { capabilityFilter.matches(profile.support(for: $0)) }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(symbol: "checklist", title: L10n.text("Vehicle Capability Matrix"), color: .blue)
                    // This card printed the raw VIN, and named its export after it, on the screen
                    // most likely to be screenshotted — defeating the setting whose own promise is
                    // that it blurs the VIN "across the app".
                    Text(L10n.format("Capability assessment for %@ (%@)", state.identity.modelName ?? L10n.text("Vehicle"), preferences.displayVIN(state.identity.vin)))
                        .hisType(.caption)
                        .foregroundStyle(.secondary)
                        .privacySensitive(preferences.privacyRedactionEnabled)

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
                            .hisType(.micro, weight: .medium)
                            .foregroundStyle(exportFeedback.isError ? Color.red : HisingenTheme.semanticGood)
                    }

                    // A degraded dashboard should explain itself here rather than only in the
                    // unified log – the cached snapshot keeps very little telemetry, so cards
                    // going quiet is otherwise indistinguishable from an unsupported vehicle.
                    if state.freshness.isCached {
                        degradedNotice(
                            symbol: "internaldrive",
                            text: L10n.text("Showing the last saved snapshot. Most live telemetry is unavailable until the next successful refresh.")
                        )
                    } else if !state.freshness.unavailableFeatures.isEmpty {
                        degradedNotice(
                            symbol: "exclamationmark.arrow.triangle.2.circlepath",
                            text: L10n.format(
                                "The last refresh could not read: %@",
                                state.freshness.unavailableFeatures.map(\.title).sorted().joined(separator: ", ")
                            )
                        )
                    }

                    VStack(spacing: 6) {
                        ForEach(items, id: \.self) { cap in
                            let support = profile.support(for: cap)
                            HStack {
                                Text(cap.title)
                                    .hisType(.label, weight: .medium)
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
                            .hisType(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    }

                    Text(L10n.text("\"Direct tyre-pressure values\" means numeric kPa readings. Many vehicles report a warning level per tyre instead (indirect TPMS); those warnings still appear on the vehicle overview and in notifications."))
                        .hisType(.micro)
                        .foregroundStyle(.tertiary)
                        .hisCaptionLeading()
                        .hisCaptionLeading()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func degradedNotice(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .hisType(.caption)
                .foregroundStyle(HisingenTheme.semanticWarning)
            Text(text)
                .hisType(.micro)
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
        panel.nameFieldStringValue = "capabilities_\(preferences.exportVINComponent(state.identity.vin)).csv"
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
