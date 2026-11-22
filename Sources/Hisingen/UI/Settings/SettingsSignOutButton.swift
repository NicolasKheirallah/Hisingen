import SwiftUI

/// The copy and confirmation scope for the sign-out button, split out so the live-fleet rule
/// can be tested without rendering the Settings window.
@MainActor
enum SignOutScopeResolver {
    static func scope(fleet: FleetSnapshot, preferences: PreferencesStore) -> SettingsSignOutButton.Scope {
        let brand = preferences.activeBrand
        let selectedVIN = preferences.vin(for: brand).normalizedVIN
        var activeVINs = Set(fleet.cars.map { $0.vin.normalizedVIN })
        if !selectedVIN.isEmpty { activeVINs.insert(selectedVIN) }
        guard activeVINs.count > 1 else { return .account }
        let state = fleet.snapshot(for: selectedVIN)
        let title = preferences.formattedVehicleTitle(
            vin: selectedVIN,
            modelName: state?.identity.modelName,
            modelYear: state?.identity.modelYear,
            registrationNo: state?.identity.registrationNo,
            fallbackBrand: brand
        )
        return .vehicle(title: title)
    }
}

@MainActor
struct SettingsSignOutButton: View {
    /// What the confirmation removes. An account with another connected car keeps its session
    /// and hides just the active vehicle; the last vehicle signs the account out.
    enum Scope: Equatable {
        case account
        case vehicle(title: String)
    }

    let binder: PreferenceBinder
    let onSignOut: (SignOutSelection) -> Void
    /// Resolved when the button is pressed, not when the Settings window was built. A second
    /// car can arrive while the window is open, and the confirmation must describe what the
    /// controller will actually do.
    var fleetProvider: (@MainActor () -> FleetSnapshot)? = nil

    @State private var showsVehicleConfirmation = false
    @State private var showsAccountConfirmation = false
    @State private var confirmedScope: Scope = .account

    private var preferences: PreferencesStore { binder.preferences }

    private var currentScope: Scope { resolveScope() }

    private var buttonTitle: String {
        switch currentScope {
        case .account:
            return L10n.format("Sign Out of %@ Account", preferences.activeBrand.displayName)
        case .vehicle:
            return L10n.text("Sign Out This Vehicle")
        }
    }

    private var confirmedVehicleTitle: String {
        if case .vehicle(let title) = confirmedScope { return title }
        return preferences.activeBrand.displayName
    }

    var body: some View {
        Button(role: .destructive) {
            confirmedScope = resolveScope()
            switch confirmedScope {
            case .account:
                showsAccountConfirmation = true
            case .vehicle:
                showsVehicleConfirmation = true
            }
        } label: {
            HStack {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                Text(buttonTitle)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.hisSecondary(HisingenTheme.semanticCritical))
        .controlSize(.regular)
        .confirmationDialog(
            L10n.format("Sign out of %@?", confirmedVehicleTitle),
            isPresented: $showsVehicleConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("Sign Out This Vehicle"), role: .destructive) {
                onSignOut(.vehicle)
            }
            Button(L10n.text("Sign Out Entire Account…")) {
                showsVehicleConfirmation = false
                Task { @MainActor in showsAccountConfirmation = true }
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(vehicleConsequence + " " + impact)
        }
        .confirmationDialog(
            L10n.format("Sign out of %@?", preferences.activeBrand.displayName),
            isPresented: $showsAccountConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("Sign Out & Remove Session"), role: .destructive) {
                onSignOut(.account)
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(accountConsequence + " " + impact)
        }
    }

    private var impact: String {
        preferences.eraseHistoryOnSignOut
            ? L10n.text("Erase local history on sign out is enabled. Signing out also erases saved history.")
            : L10n.text("Local vehicle history is kept.")
    }

    private var vehicleConsequence: String {
        L10n.format(
            "This removes this vehicle from Hisingen. Your %@ account stays signed in for your other vehicles.",
            preferences.activeBrand.displayName
        )
    }

    private var accountConsequence: String {
        L10n.text("The saved session and account credentials for this provider will be removed from this Mac.")
    }

    private func resolveScope() -> Scope {
        guard let fleet = fleetProvider?() else { return .account }
        return SignOutScopeResolver.scope(fleet: fleet, preferences: preferences)
    }
}
