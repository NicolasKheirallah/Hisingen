import SwiftUI

extension InfoTabView {
    // MARK: - Capability inspector (Polestar GetMyCars flags)

    /// Capability flags observed in the undocumented GetMyCars response. A true flag is a
    /// positive observation; false can also mean the field was absent, so it is not proof that
    /// the vehicle lacks the capability.
    var capabilityInspectorCard: some View {
        guard let caps = state.otaCapabilities, state.isVolvo == false else { return AnyView(EmptyView()) }

        struct Flag { let title: String; let reported: Bool; let symbol: String }
        let flags: [Flag] = [
            Flag(title: L10n.text("Full OTA Updates"), reported: caps.supportsFullOtaUpdates, symbol: "arrow.down.circle"),
            Flag(title: L10n.text("Remote Install Scheduling"), reported: caps.supportsRemoteOtaInstallSchedule, symbol: "calendar.badge.clock"),
            Flag(title: L10n.text("Cloud Download Consent"), reported: caps.supportsCloudBasedOtaDownloadConsent, symbol: "icloud.and.arrow.down"),
            Flag(title: L10n.text("Tailgate Open/Close"), reported: caps.supportsTrunkControl, symbol: "car.side.rear.open"),
            Flag(title: L10n.text("Trunk Unlock"), reported: caps.supportsTrunkUnlock, symbol: "lock.open"),
            Flag(title: L10n.text("Honk & Flash"), reported: caps.supportsHonkAndFlash, symbol: "light.beacon"),
            Flag(title: L10n.text("Windows Control"), reported: caps.supportsWindowsControl, symbol: "rectangle.arrowtriangle.2.outward"),
            Flag(title: L10n.text("Charging Functions"), reported: caps.supportsChargingFunctions, symbol: "bolt.fill")
        ]
        let positive = flags.filter(\.reported)
        let negative = flags.filter { !$0.reported }

        func row(_ flag: Flag) -> KVRow {
            KVRow(flag.title,
                  flag.reported ? L10n.text("Reported supported") : L10n.text("Not reported"),
                  symbol: flag.symbol)
        }

        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "checklist", title: L10n.text("Vehicle Capabilities"), color: .teal)
                Text(L10n.text("Positive flags were reported by the backend. “Not reported” does not prove that the vehicle lacks a capability."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)

                VStack(spacing: 6) {
                    ForEach(positive.indices, id: \.self) { row(positive[$0]) }
                    if caps.supportsPlugAndCharge {
                        KVRow(L10n.text("Plug & Charge"), L10n.text("Supported"), symbol: "plug")
                    }
                    if caps.hasPerformanceSoftwareUpgrade {
                        KVRow(L10n.text("Performance Software Upgrade"), L10n.text("Available"), symbol: "gauge.with.needle.100percent.high")
                    }
                    if let installed = caps.installedSoftwareVersion {
                        KVRow(L10n.text("Backend-Reported Software"), installed, symbol: "checkmark.seal",
                              info: L10n.text("Unverified value from an undocumented backend field."))
                    }
                }

                if !negative.isEmpty {
                    DisclosureGroup(isExpanded: $showAllCapabilities) {
                        VStack(spacing: 6) {
                            ForEach(negative.indices, id: \.self) { row(negative[$0]) }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text(L10n.format("%d not reported by the backend", negative.count))
                            .font(.system(size: 11, weight: .medium))
                    }
                }

                Text(L10n.text("Reported by the vehicle cloud backend — exact support per VIN."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        })
    }

    // MARK: - Capability profile (brand-agnostic, from VehicleCapabilityProfile)

    var capabilityProfileEntries: (positive: [(VehicleCapability, VehicleCapabilitySupport)],
                                   negative: [(VehicleCapability, VehicleCapabilitySupport)]) {
        // Only shown when the Polestar GetMyCars flag list isn't (Volvo, or a Polestar without
        // that payload) — otherwise the two capability cards would say much the same thing.
        guard state.otaCapabilities == nil || state.isVolvo else { return ([], []) }
        let profile = state.capabilityProfile
        var positive: [(VehicleCapability, VehicleCapabilitySupport)] = []
        var negative: [(VehicleCapability, VehicleCapabilitySupport)] = []
        for capability in VehicleCapability.allCases {
            let support = profile.support(for: capability)
            if support == .unavailable {
                negative.append((capability, support))
            } else {
                positive.append((capability, support))
            }
        }
        return (positive, negative)
    }

    var vehicleCapabilityCard: some View {
        let entries = capabilityProfileEntries
        guard !entries.positive.isEmpty || !entries.negative.isEmpty else { return AnyView(EmptyView()) }

        func row(_ pair: (VehicleCapability, VehicleCapabilitySupport)) -> KVRow {
            KVRow(pair.0.title, pair.1.displayName, symbol: pair.1.symbolName)
        }

        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "checklist", title: L10n.text("Vehicle Capabilities"), color: .teal)
                Text(L10n.text("Derived from the model profile and any capabilities probed at runtime. Not a live per-VIN guarantee."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)

                VStack(spacing: 6) {
                    ForEach(entries.positive.indices, id: \.self) { row(entries.positive[$0]) }
                }

                if !entries.negative.isEmpty {
                    DisclosureGroup(isExpanded: $showAllCapabilities) {
                        VStack(spacing: 6) {
                            ForEach(entries.negative.indices, id: \.self) { row(entries.negative[$0]) }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text(L10n.format("%d not available on this model", entries.negative.count))
                            .font(.system(size: 11, weight: .medium))
                    }
                }
            }
        })
    }
}
