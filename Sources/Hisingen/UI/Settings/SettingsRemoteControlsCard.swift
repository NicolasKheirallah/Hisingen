import SwiftUI

/// Settings → Features → "Remote Controls": the per-provider authorization affordance
/// (Volvo restricted scopes / Polestar command sign-in) followed by one feature toggle per
/// remote command, greyed out where the vehicle's capability profile or the provider API
/// does not permit it. Extracted from `SettingsView`.
@MainActor
struct SettingsRemoteControlsCard: View {
    let state: VehicleState?
    let binder: PreferenceBinder

    private var prefs: PreferencesStore { binder.preferences }

    private func supportsCapability(_ capability: VehicleCapability) -> Bool {
        guard let state else { return true }
        return state.capabilityProfile.support(for: capability).permitsRequest
    }

    private func row(_ feature: AppFeature, symbol: String, title: String, detail: String,
                     isSupported: Bool = true, badgeText: String? = nil) -> SettingsFeatureToggleRow {
        SettingsFeatureToggleRow(binder: binder, feature: feature, symbol: symbol, title: title,
                                 detail: detail, isSupported: isSupported, badgeText: badgeText)
    }

    var body: some View {
        let isVolvo = prefs.activeBrand == .volvo
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "slider.horizontal.3", title: L10n.text("Remote Controls"), color: .blue)

                Text(isVolvo
                     ? L10n.text("Climate is available with the standard API subscription. Lock, locate, engine-start, and location permissions require approval for your Volvo developer application and a new sign-in.")
                     : L10n.text("Climate, locks, windows, cabin cleaning, charging and timers are dispatched through Polestar's command service, and software installation through its OTA scheduler."))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                VStack(spacing: 4) {
                    if isVolvo {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.text("Approved Volvo permissions"))
                                    .font(.system(size: 11, weight: .semibold))
                                Text(L10n.text("Request restricted lock, unlock, engine, locate, and location scopes on the next sign-in."))
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { prefs.volvoRestrictedScopesEnabled },
                                set: { enabled in
                                    prefs.volvoRestrictedScopesEnabled = enabled
                                    binder.bump()
                                    binder.notify(.features)
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    } else {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.text("Authorize Remote Commands"))
                                    .font(.system(size: 11, weight: .semibold))
                                Text(L10n.text("Opens your browser to sign in for remote commands. Hisingen never sees your Polestar password for this step, and this is separate from the account sign-in above."))
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                binder.notify(.polestarCommandAuthorization)
                            } label: {
                                Text(L10n.text("Authorize…"))
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .controlSize(.small)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    row(.remoteClimate, symbol: "fan.fill", title: "Remote Climate", detail: "Start & stop cabin preconditioning", isSupported: supportsCapability(.climateStartStop))
                    row(.remoteLocks, symbol: "lock.fill", title: "Remote Locks", detail: "Central lock and unlock", isSupported: supportsCapability(.locks) && (!isVolvo || prefs.volvoRestrictedScopesEnabled), badgeText: isVolvo ? "Requires Approval" : nil)
                    row(.remoteCharging, symbol: "bolt.fill", title: "Remote Charging", detail: "Set target SoC, current limit & charge now", isSupported: !isVolvo && supportsCapability(.chargeTarget), badgeText: isVolvo ? "Read-Only in API" : nil)
                    row(.remoteSchedules, symbol: "calendar.badge.clock", title: "Charging & Climate Timers", detail: "Create and edit charge windows and departure timers", isSupported: !isVolvo && (supportsCapability(.chargingSchedule) || supportsCapability(.climateTimers)), badgeText: isVolvo ? "Not in API" : nil)
                    row(.remoteWindows, symbol: "rectangle.arrowtriangle.2.outward", title: "Window Controls", detail: "Vent or close vehicle windows", isSupported: !isVolvo && supportsCapability(.windows), badgeText: isVolvo ? "Not in API" : nil)
                    row(.remoteHonkFlash, symbol: "flashlight.on.fill", title: "Locate Vehicle", detail: "Flash headlights and honk horn", isSupported: supportsCapability(.honkAndFlash) && (!isVolvo || prefs.volvoRestrictedScopesEnabled), badgeText: isVolvo ? "Requires Approval" : nil)
                    row(.remotePreCleaning, symbol: "sparkles", title: "Cabin Air Cleaning", detail: "PM2.5 pre-cleaning filtration", isSupported: !isVolvo && supportsCapability(.preCleaning), badgeText: isVolvo ? "In-Car Only" : nil)
                    row(.remoteOTA, symbol: "arrow.triangle.2.circlepath", title: "Vehicle Software Controls", detail: "Install or cancel a pending software update", isSupported: !isVolvo && supportsCapability(.softwareInstallControl), badgeText: isVolvo ? "Not in API" : nil)
                }
            }
        }
    }
}
