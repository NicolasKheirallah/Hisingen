import SwiftUI

/// Settings → Features → "Remote Controls": one feature toggle per
/// remote command, greyed out where the vehicle's capability profile or the provider API
/// does not permit it. Extracted from `SettingsView`.
@MainActor
struct SettingsRemoteControlsCard: View {
    let state: VehicleState?
    let binder: PreferenceBinder
    var onOpenAuthorization: (() -> Void)? = nil

    private var prefs: PreferencesStore { binder.preferences }

    private func supportsCapability(_ capability: VehicleCapability) -> Bool {
        guard let state else { return false }
        return state.capabilityProfile.support(for: capability).permitsRequest
    }

    private func row(_ feature: AppFeature, symbol: String, title: String, detail: String,
                     isSupported: Bool = true, badgeText: String? = nil) -> SettingsFeatureToggleRow {
        SettingsFeatureToggleRow(binder: binder, feature: feature, symbol: symbol, title: title,
                                 detail: detail, isSupported: isSupported,
                                 badgeText: isSupported ? badgeText : "Not supported by vehicle")
    }

    /// Raw (unlocalized – `SettingsFeatureToggleRow` localizes) badge for a command whose
    /// dispatch needs the Polestar command-client authorization the user has not granted yet.
    private func commandAuthBadge(_ needsCommandClientAuth: Bool) -> String? {
        guard needsCommandClientAuth,
              prefs.activeBrand == .polestar,
              !prefs.hasPolestarCommandAuthorization else { return nil }
        return "Needs authorization"
    }

    var body: some View {
        let isVolvo = prefs.activeBrand == .volvo
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "slider.horizontal.3", title: L10n.text("Remote Controls"), color: HisingenTheme.semanticActive)

                Text(isVolvo
                     ? L10n.text("Climate is available with the standard API subscription. Lock, locate, engine-start, and location permissions require approval for your Volvo developer application and a new sign-in.")
                     : L10n.text("Locks, climate, windows, cabin cleaning and locate need the one-time browser authorization in Accounts. Charging, timers and software installation work with the account sign-in alone."))
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
                if let onOpenAuthorization {
                    NavigationRow(title: L10n.text("Remote Command Permissions"), action: onOpenAuthorization)
                }

                VStack(spacing: 4) {
                    row(.remoteClimate, symbol: "fan", title: "Remote Climate", detail: "Start & stop cabin preconditioning", isSupported: supportsCapability(.climateStartStop), badgeText: isVolvo ? nil : commandAuthBadge(true))
                    row(.remoteLocks, symbol: "lock", title: "Remote Locks", detail: "Central lock and unlock", isSupported: supportsCapability(.locks) && (!isVolvo || prefs.volvoRestrictedScopesEnabled), badgeText: isVolvo ? "Requires Approval" : commandAuthBadge(true))
                    row(.remoteCharging, symbol: "bolt", title: "Remote Charging", detail: "Set target SoC, current limit & charge now", isSupported: !isVolvo && supportsCapability(.chargeTarget), badgeText: isVolvo ? "Read-Only in API" : nil)
                    row(.remoteSchedules, symbol: "calendar.badge.clock", title: "Charging & Climate Timers", detail: "Create and edit charge windows and departure timers", isSupported: !isVolvo && (supportsCapability(.chargingSchedule) || supportsCapability(.climateTimers)), badgeText: isVolvo ? "Not in API" : nil)
                    row(.remoteWindows, symbol: "rectangle.arrowtriangle.2.outward", title: "Window Controls", detail: "Vent or close vehicle windows", isSupported: !isVolvo && supportsCapability(.windows), badgeText: isVolvo ? "Not in API" : commandAuthBadge(true))
                    row(.remoteHonkFlash, symbol: "flashlight.on.fill", title: "Locate Vehicle", detail: "Flash headlights and honk horn", isSupported: supportsCapability(.honkAndFlash) && (!isVolvo || prefs.volvoRestrictedScopesEnabled), badgeText: isVolvo ? "Requires Approval" : commandAuthBadge(true))
                    row(.remotePreCleaning, symbol: "aqi.medium", title: "Cabin Air Cleaning", detail: "PM2.5 pre-cleaning filtration", isSupported: !isVolvo && supportsCapability(.preCleaning), badgeText: isVolvo ? "In-Car Only" : commandAuthBadge(true))
                    row(.remoteOTA, symbol: "arrow.triangle.2.circlepath", title: "Vehicle Software Controls", detail: "Install or cancel a pending software update", isSupported: !isVolvo && supportsCapability(.softwareInstallControl), badgeText: isVolvo ? "Not in API" : nil)
                }
            }
        }
    }
}
