import SwiftUI

/// The Polestar browser grant is verified against an active Polestar ID session.
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
                .buttonStyle(.hisProminent(HisingenTheme.semanticWarning))
                .controlSize(.mini)
            }
        }
        .padding(8)
        .background(HisingenTheme.semanticWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: 0))
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
                    in: RoundedRectangle(cornerRadius: 0))
    }
}

@MainActor
struct SettingsRemoteAuthorizationCard: View {
    let binder: PreferenceBinder

    private var prefs: PreferencesStore { binder.preferences }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(
                    symbol: "key",
                    title: L10n.text("Remote Command Permissions"),
                    color: HisingenTheme.semanticActive
                )
                if prefs.activeBrand == .volvo {
                    volvoPermissions
                } else {
                    RemoteCommandAuthorizationRow(
                        binder: binder,
                        needsSignIn: prefs.hasPolestarIDCredentials && !prefs.hasSessionToken(for: .polestar)
                    )
                }
            }
        }
    }

    private var volvoPermissions: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("Approved Volvo permissions"))
                    .hisType(.label, weight: .semibold)
                Text(L10n.text("Request restricted lock, unlock, engine, locate, and location scopes on the next sign-in."))
                    .hisType(.micro)
                    .hisCaptionLeading()
                    .fixedSize(horizontal: false, vertical: true)
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
            .accessibilityLabel(L10n.text("Approved Volvo permissions"))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(8)
        .background(HisingenTheme.semanticWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: 0))
    }
}
