import SwiftUI

/// The one-time browser grant for Polestar remote commands. Shared by Settings → Features →
/// Remote Controls and Settings → Accounts, so the control sits where a reader looks for it and
/// both pages speak the same sentence.
///
/// The grant is verified against, and dispatched with, the Polestar ID session. Offering the
/// browser step without that session throws the grant away, so `needsSignIn` swaps the menu for
/// the re-sign-in path instead of letting the reader authorize into nothing.
@MainActor
struct RemoteCommandAuthorizationRow: View {
    let binder: PreferenceBinder

    /// True when the account session is gone and only a fresh sign-in can hold the grant.
    var needsSignIn: Bool = false

    private var prefs: PreferencesStore { binder.preferences }

    var body: some View {
        if needsSignIn {
            signInRow(offersAction: true)
        } else if !prefs.hasPolestarIDCredentials {
            signInRow(offersAction: false)
        } else {
            authorizationRow
        }
    }

    /// The warning row, with the action only where this view owns it: on Features the account
    /// card sits above and carries the sign-in, while the Accounts copy needs its own button.
    private func signInRow(offersAction: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "person.badge.key.fill")
                        .hisType(.caption)
                        .foregroundStyle(HisingenTheme.semanticWarning)
                    Text(L10n.text("Sign in to Polestar first"))
                        .hisType(.label, weight: .semibold)
                }
                Text(L10n.text("Connect your Polestar account before authorizing remote commands."))
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if offersAction {
                Button {
                    binder.notify(.reauthenticate(.polestar))
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise.circle")
                        Text(L10n.text("Re-sign In"))
                    }
                    .hisType(.caption, weight: .semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(HisingenTheme.semanticWarning)
                .controlSize(.mini)
            }
        }
        .padding(8)
        .background(HisingenTheme.semanticWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var authorizationRow: some View {
        let authorized = prefs.hasPolestarCommandAuthorization
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: authorized ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .hisType(.caption)
                        .foregroundStyle(authorized ? HisingenTheme.semanticGood : HisingenTheme.semanticWarning)
                    Text(authorized ? L10n.text("Remote commands authorized")
                                    : L10n.text("Authorize Remote Commands"))
                        .hisType(.label, weight: .semibold)
                }
                Text(authorized
                     ? L10n.text("Locks, climate, windows, cabin cleaning and locate are authorized. Re-authorize here if these commands start failing.")
                     : L10n.text("Opens your browser to sign in for remote commands. Hisingen never sees your Polestar password for this step, and this is separate from the account sign-in above."))
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button {
                    binder.notify(.polestarCommandAuthorization)
                } label: {
                    Text(authorized ? L10n.text("Re-authorize…") : L10n.text("Authorize…"))
                }
                Button {
                    binder.notify(.polestarCommandAuthorizationForceLogin)
                } label: {
                    Text(L10n.text("Sign in with a different account…"))
                }
            } label: {
                Text(authorized ? L10n.text("Re-authorize…") : L10n.text("Authorize…"))
                    .hisType(.caption, weight: .medium)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .controlSize(.small)
        }
        .padding(8)
        .background((authorized ? HisingenTheme.semanticGood : HisingenTheme.semanticWarning).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}
