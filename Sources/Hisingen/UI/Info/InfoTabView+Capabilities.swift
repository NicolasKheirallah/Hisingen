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
                    if let sunroof = caps.supportsSunroofControl {
                        KVRow(L10n.text("Sunroof Remote Control"),
                              sunroof ? L10n.text("Reported supported") : L10n.text("Not reported"),
                              symbol: "sun.max.trianglebadge.exclamationmark")
                    }
                    if let plate = caps.registrationPlate?.trimmingCharacters(in: .whitespacesAndNewlines), !plate.isEmpty {
                        KVRow(L10n.text("Backend Registration Plate"), plate, symbol: "rectangle.inset.filled.badge.record")
                    }
                    if let linked = caps.userIsLinked {
                        KVRow(L10n.text("Account Linked To Vehicle"),
                              linked ? L10n.text("Yes") : L10n.text("No"), symbol: "person.2")
                    }
                    if let owner = caps.userIsOwner {
                        KVRow(L10n.text("Account Owns Vehicle"),
                              owner ? L10n.text("Yes") : L10n.text("No"), symbol: "person.crop.square.badge.checkmark")
                    }
                    if caps.hasPerformanceSoftwareUpgrade {
                        KVRow(L10n.text("Performance Software Upgrade"), L10n.text("Available"), symbol: "gauge.with.needle.100percent.high")
                    }
                    if let installed = caps.installedSoftwareVersion {
                        KVRow(L10n.text("Backend-Reported Software"), installed, symbol: "checkmark.seal",
                              info: L10n.text("Installed software version reported by MyCars."))
                    }
                    if let equipment = caps.equipment {
                        ForEach(equipment.details) { detail in
                            KVRow(L10n.text(detail.title), detail.value, symbol: "info.circle")
                        }
                        if equipment.softwareVersionDisagrees(with: caps.installedSoftwareVersion) {
                            KVRow(L10n.text("Software Version Disagreement"),
                                  equipment.restrictedSoftwareVersion ?? "", symbol: "exclamationmark.triangle")
                        }
                        if let lights = equipment.supportedLightWarnings, !lights.isEmpty {
                            DisclosureGroup(L10n.text("Monitored Lights")) {
                                Text(lights.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
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

                DisclosureGroup(L10n.text("Effective Control Capabilities")) {
                    ForEach(VehicleCapability.displayed, id: \.self) { capability in
                        KVRow(capability.title, state.capabilityProfile.support(for: capability).displayName,
                              symbol: state.capabilityProfile.support(for: capability).symbolName,
                              info: state.capabilityProfile.supportSource(for: capability))
                    }
                }

                if let rawFields = caps.unknownWireFields, !rawFields.isEmpty {
                    DisclosureGroup(L10n.format("Undecoded Backend Fields (%d)", rawFields.count)) {
                        ForEach(rawFields.indices, id: \.self) { index in
                            rawCapabilityFieldRow(rawFields[index])
                        }
                    }
                }

                Text(L10n.text("Controls also depend on account permissions, enabled features and available command implementations."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        })
    }

    /// One raw `GetMyCars` wire field. The label carries the parent message number when the
    /// field lives inside a known sub-message, e.g. "Field 35.5".
    func rawCapabilityFieldRow(_ field: PolestarRawWireField) -> KVRow {
        let path = field.subfield.map { "\($0).\(field.field)" } ?? String(field.field)
        let label = field.isBinary ? L10n.format("Field %@ (raw)", path) : L10n.format("Field %@", path)
        return KVRow(label, field.value, symbol: "curlybraces",
                     info: L10n.text("Wire field the backend sent but Hisingen has not yet decoded. Shown raw so new backend data is visible; reported unchanged in support exports."))
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
            KVRow(pair.0.title, pair.1.displayName, symbol: pair.1.symbolName,
                  info: state.capabilityProfile.supportSource(for: pair.0))
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
