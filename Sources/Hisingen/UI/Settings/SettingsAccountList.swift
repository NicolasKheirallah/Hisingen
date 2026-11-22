import SwiftUI

/// Accounts for the active brand, plus the demo switch. The list is deliberately small: one
/// row per account with its own Switch action, and Add Account that starts the existing sign-in
/// form against a fresh account record.
@MainActor
struct SettingsAccountList: View {
    let onSettingsChanged: (SettingsChange) -> Void
    @Environment(\.preferencesStore) private var preferences
    @State private var errorMessage: String?

    private var accounts: [StoredAccount] {
        preferences.accountStore.accounts(for: preferences.activeBrand)
    }

    private var activeID: String? {
        preferences.accountStore.activeAccountID(for: preferences.activeBrand)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("Accounts"))
                    .hisType(.caption)
                    .foregroundStyle(HisingenTheme.inkMuted)
                Spacer()
                Button(L10n.text("Add Account")) {
                    addAccount()
                }
                .buttonStyle(.borderless)
            }
            ForEach(accounts) { account in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.label)
                            .hisType(.body)
                            .foregroundStyle(HisingenTheme.ink)
                            .lineLimit(1)
                        if account.id == activeID {
                            Text(L10n.text("Active"))
                                .hisType(.caption)
                                .foregroundStyle(HisingenTheme.inkMuted)
                        }
                    }
                    Spacer(minLength: 8)
                    if account.id != activeID {
                        Button(L10n.text("Switch")) {
                            switchTo(account)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Divider().opacity(HisingenTheme.dividerOpacity)
            }
            if let errorMessage {
                Text(errorMessage)
                    .hisType(.caption)
                    .foregroundStyle(HisingenTheme.semanticWarning)
            }
            Toggle(isOn: Binding(
                get: { preferences.isDemoMode },
                set: { preferences.isDemoMode = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Demo mode"))
                        .hisType(.body)
                    Text(L10n.text("Relaunch Hisingen to apply."))
                        .hisType(.caption)
                        .foregroundStyle(HisingenTheme.inkMuted)
                }
            }
            .toggleStyle(.switch)
        }
    }

    private func addAccount() {
        do {
            _ = try preferences.accountStore.addAccount(
                brand: preferences.activeBrand, label: "")
            onSettingsChanged(.accountAdded)
        } catch {
            errorMessage = L10n.text("The account could not be added.")
        }
    }

    private func switchTo(_ account: StoredAccount) {
        do {
            try preferences.accountStore.switchTo(accountID: account.id)
            onSettingsChanged(.accountSwitched)
        } catch {
            errorMessage = L10n.text("The account could not be switched.")
        }
    }
}
