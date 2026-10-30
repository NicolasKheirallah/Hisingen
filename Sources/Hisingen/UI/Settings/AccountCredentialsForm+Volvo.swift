import SwiftUI

/// The Volvo section of the account card: developer-app credentials, the VIN, and the
/// Volvo ID sign-in handoff.
extension AccountCredentialsForm {
    var volvoFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            if BuiltinVolvoSecrets.isConfigured && !showCustomVolvoApp {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(HisingenTheme.semanticGood)
                        .hisType(.subhead)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.text("Developer Access Ready"))
                            .hisType(.label, weight: .semibold)
                            .foregroundStyle(.primary)
                        Text(L10n.text("Default developer application credentials configured."))
                            .hisType(.micro)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        showCustomVolvoApp = true
                    } label: {
                        Text(L10n.text("Custom App"))
                            .hisType(.caption)
                    }
                    .buttonStyle(.pressable)
                    .foregroundStyle(HisingenTheme.accent)
                }
                .padding(8)
                .background(HisingenTheme.semanticGood.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            } else {
                Text(L10n.text(
                    "Register a free API application at developer.volvocars.com to get a Client ID, Client Secret, and VCC API Key, then sign in with your Volvo ID below. Hisingen never sees your Volvo ID password directly, because sign-in happens in a system browser window."
                ))
                .hisType(.caption)
                .foregroundStyle(.secondary)
                .hisCaptionLeading()
                .fixedSize(horizontal: false, vertical: true)

                if BuiltinVolvoSecrets.isConfigured {
                    HStack {
                        Spacer()
                        Button {
                            showCustomVolvoApp = false
                            model.draft.volvoClientID = ""
                            model.draft.volvoClientSecret = ""
                            model.draft.volvoApiKey = ""
                        } label: {
                            Text(L10n.text("Use Default Developer Keys"))
                                .hisType(.caption)
                        }
                        .buttonStyle(.pressable)
                        .foregroundStyle(HisingenTheme.accent)
                    }
                }

                labeledField(L10n.text("Client ID")) {
                    TextField("Client ID", text: model.binding(\.volvoClientID))
                        .textFieldStyle(.roundedBorder)
                }

                labeledField(L10n.text("Client Secret")) {
                    SecureField(model.hasResumableVolvoSession && model.draft.volvoClientSecret.isEmpty
                                ? L10n.text("•••••••• (Saved in Keychain)")
                                : L10n.text("Client Secret"), text: model.binding(\.volvoClientSecret))
                        .textFieldStyle(.roundedBorder)
                }

                labeledField(L10n.text("VCC API Key")) {
                    SecureField(model.hasResumableVolvoSession && model.draft.volvoApiKey.isEmpty
                                ? L10n.text("•••••••• (Saved in Keychain)")
                                : L10n.text("VCC API Key"), text: model.binding(\.volvoApiKey))
                        .textFieldStyle(.roundedBorder)
                }
            }

            labeledField(L10n.text("Vehicle Nickname (Optional)")) {
                TextField(L10n.text("e.g. My Volvo, Family car"), text: model.binding(\.volvoNickname))
                    .textFieldStyle(.roundedBorder)
            }

            labeledField(L10n.text("VIN (Optional, auto-detected)")) {
                TextField("YV1...", text: model.binding(\.volvoVIN))
                    .textFieldStyle(.roundedBorder)
            }
            if attemptedVolvoSignIn && !SettingsValidation.isValidOptionalVIN(model.draft.volvoVIN) {
                InlineValidationLabel(message: L10n.text("A VIN must contain 17 valid letters or digits."))
            }

            Button {
                withAnimation(Motion.resolveCrossfade(Motion.stateChange)) {
                    attemptedVolvoSignIn = true
                }
                beginVolvoSignIn()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                    Text(model.hasResumableVolvoSession
                         ? L10n.text("Switch to Volvo Account")
                         : L10n.text("Sign in with Volvo ID"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled((!BuiltinVolvoSecrets.isConfigured && model.draft.volvoClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || !SettingsValidation.isValidOptionalVIN(model.draft.volvoVIN))
            .padding(.top, style == .welcoming ? 6 : 4)
        }
    }

    private func beginVolvoSignIn() {
        guard let request = model.beginVolvoSignIn() else { return }
        onSettingsChanged(.volvoSignIn(
            clientID: request.clientID,
            clientSecret: request.clientSecret,
            vccApiKey: request.vccApiKey,
            nickname: request.nickname
        ))
    }
}
