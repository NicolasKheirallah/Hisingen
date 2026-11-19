import SwiftUI

/// The Volvo section of the account card: developer-app credentials, the VIN, and the
/// Volvo ID sign-in handoff.
extension AccountCredentialsForm {
    var volvoFields: some View {
        VStack(alignment: .leading, spacing: style == .welcoming ? 16 : 8) {
            if BuiltinVolvoSecrets.isConfigured && !showCustomVolvoApp {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("Developer Access Ready"))
                            .hisType(.body)
                            .foregroundStyle(HisingenTheme.ink)
                        Text(L10n.text("Default developer application credentials configured."))
                            .hisType(.caption)
                            .foregroundStyle(HisingenTheme.inkMuted)
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
                .padding(10)
                .padding(.leading, 2)
                .hisNotice(HisingenTheme.semanticGood)
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
                    HisTextField("", text: model.binding(\.volvoClientID), label: L10n.text("Client ID"))
                }

                labeledField(L10n.text("Client Secret")) {
                    HisSecureField(model.hasResumableVolvoSession && model.draft.volvoClientSecret.isEmpty
                                   ? L10n.text("•••••••• (Saved in Keychain)") : "",
                                   text: model.binding(\.volvoClientSecret), label: L10n.text("Client Secret"))
                }

                labeledField(L10n.text("VCC API Key")) {
                    HisSecureField(model.hasResumableVolvoSession && model.draft.volvoApiKey.isEmpty
                                   ? L10n.text("•••••••• (Saved in Keychain)") : "",
                                   text: model.binding(\.volvoApiKey), label: L10n.text("VCC API Key"))
                }
            }

            if style != .welcoming {
                labeledField(L10n.text("VIN (Optional, auto-detected)")) {
                    HisTextField("YV1...", text: model.binding(\.volvoVIN))
                }
                if attemptedVolvoSignIn && !SettingsValidation.isValidOptionalVIN(model.draft.volvoVIN) {
                    InlineValidationLabel(message: L10n.text("A VIN must contain 17 valid letters or digits."))
                }
            }

            Button {
                submitVolvoSignIn()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                    Text(model.hasResumableVolvoSession
                         ? L10n.text("Switch to Volvo Account")
                         : L10n.text("Sign in with Volvo ID"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.hisProminent)
            .controlSize(.regular)
            .disabled(volvoSignInDisabled)
            .padding(.top, style == .welcoming ? 6 : 4)
        }
        // Return in any field does what the button does, with the same guard.
        .onSubmit { submitVolvoSignIn() }
    }

    private var volvoSignInDisabled: Bool {
        (!BuiltinVolvoSecrets.isConfigured && model.draft.volvoClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || !SettingsValidation.isValidOptionalVIN(model.draft.volvoVIN)
    }

    private func submitVolvoSignIn() {
        guard !volvoSignInDisabled else { return }
        withAnimation(Motion.resolveCrossfade(Motion.stateChange)) {
            attemptedVolvoSignIn = true
        }
        beginVolvoSignIn()
    }

    private func beginVolvoSignIn() {
        guard let request = model.beginVolvoSignIn(saveNickname: false) else { return }
        onSettingsChanged(.volvoSignIn(
            clientID: request.clientID,
            clientSecret: request.clientSecret,
            vccApiKey: request.vccApiKey,
            nickname: request.nickname
        ))
    }
}
