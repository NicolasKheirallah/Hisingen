import SwiftUI

@MainActor
struct SettingsSignOutButton: View {
    let binder: PreferenceBinder
    let onSignOut: () -> Void

    @State private var showsConfirmation = false

    private var preferences: PreferencesStore { binder.preferences }

    var body: some View {
        Button(role: .destructive) {
            showsConfirmation = true
        } label: {
            HStack {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                Text(L10n.format("Sign Out of %@ Account", preferences.activeBrand.displayName))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.hisSecondary(HisingenTheme.semanticCritical))
        .controlSize(.regular)
        .confirmationDialog(
            L10n.format("Sign out of %@?", preferences.activeBrand.displayName),
            isPresented: $showsConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("Sign Out & Remove Session"), role: .destructive, action: onSignOut)
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            let impact = preferences.eraseHistoryOnSignOut
                ? L10n.text("Erase local history on sign out is enabled. Signing out also erases saved history.")
                : L10n.text("Local vehicle history is kept.")
            Text(L10n.text("The saved session and account credentials for this provider will be removed from this Mac.") + " " + impact)
        }
    }
}
