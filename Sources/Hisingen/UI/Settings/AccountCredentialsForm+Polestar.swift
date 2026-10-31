import SwiftUI

/// The Polestar section of the account card: sign-in option choice, the Polestar ID and
/// Developer Portal fields, and the save and test actions.
extension AccountCredentialsForm {
    private var enablePolestarID: Bool { credentialSelection.enablePolestarID }
    private var enableDataPortal: Bool { credentialSelection.enableDataPortal }

    var polestarFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            polestarCredentialSelector

            polestarModeExplanation

            if enablePolestarID {
                polestarIDSection
            }

            if enablePolestarID && enableDataPortal {
                Divider().padding(.vertical, 2)
            }

            if enableDataPortal {
                polestarDataPortalSection
            }

            Divider().padding(.vertical, 2)

            polestarSharedFields

            polestarActionButtons
        }
    }

    private struct CredentialOption {
        let title: String
        let subtitle: String
        let symbol: String
        let isSelected: Bool
    }

    private var polestarCredentialSelector: some View {
        HStack(spacing: 8) {
            credentialOptionCard(
                CredentialOption(
                    title: L10n.text("Polestar ID"),
                    subtitle: L10n.text("Remote Controls"),
                    symbol: "person.badge.key.fill",
                    isSelected: enablePolestarID
                )
            ) {
                togglePolestarCredentialOption(polestarID: true)
            }

            credentialOptionCard(
                CredentialOption(
                    title: L10n.text("Developer Portal"),
                    subtitle: L10n.text("EU Data Act"),
                    symbol: "antenna.radiowaves.left.and.right",
                    isSelected: enableDataPortal
                )
            ) {
                togglePolestarCredentialOption(polestarID: false)
            }
        }
    }

    private func togglePolestarCredentialOption(polestarID: Bool) {
        withAnimation(reduceMotion ? nil : Motion.selection) {
            testConnectionResult = nil
            keychainError = nil
            polestarFallbackKind = nil
            credentialSelection.toggle(polestarID: polestarID)
            // Keep the toggle local until Save: persisting mode here triggers
            // credentialsChanged → full session re-establish (with password replay)
            // merely from exploring options, and can disagree with an unsaved draft
            // if Save later fails validation.
        }
    }

    private func credentialOptionCard(
        _ option: CredentialOption,
        action: @escaping () -> Void
    ) -> some View {
        let radius: CGFloat = HisingenTheme.bannerRadius
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: option.symbol)
                        .hisSymbolSize(14, weight: .semibold)
                        .foregroundStyle(option.isSelected ? HisingenTheme.accent : HisingenTheme.inkMuted)
                    Spacer()
                    Image(systemName: option.isSelected ? "checkmark.circle.fill" : "circle")
                        .hisSymbolSize(13)
                        .foregroundStyle(option.isSelected ? HisingenTheme.accent : .secondary.opacity(0.4))
                }
                Text(option.title)
                    .hisType(.label, weight: option.isSelected ? .semibold : .medium)
                    .foregroundStyle(option.isSelected ? HisingenTheme.ink : HisingenTheme.inkMuted)
                Text(option.subtitle)
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                option.isSelected ? HisingenTheme.accent.opacity(0.12) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(option.isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var polestarModeExplanation: some View {
        if enablePolestarID && enableDataPortal {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "link.badge.plus")
                    .foregroundStyle(HisingenTheme.accent)
                    .hisType(.label)
                Text(PreferencesStore.PolestarConnectionMode.augmented.detailDescription)
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .transition(.opacity)
        } else if enablePolestarID {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "person.badge.key.fill")
                    .foregroundStyle(HisingenTheme.accent)
                    .hisType(.label)
                Text(PreferencesStore.PolestarConnectionMode.polestarID.detailDescription)
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .transition(.opacity)
        } else {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(HisingenTheme.accent)
                    .hisType(.label)
                Text(PreferencesStore.PolestarConnectionMode.dataPortal.detailDescription)
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .transition(.opacity)
        }
    }

    private var polestarIDStatusBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(HisingenTheme.semanticGood)
                .hisSymbolSize(13)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text("Polestar ID: Signed In"))
                    .hisType(.caption, weight: .semibold)
                if !preferences.email.isEmpty {
                    Text(preferences.email)
                        .hisType(.micro)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                onSettingsChanged(.polestarWebSignIn)
            } label: {
                Text(L10n.text("Re-authenticate"))
                    .hisType(.micro, weight: .medium)
            }
            .controlSize(.mini)
        }
        .padding(8)
        .background(HisingenTheme.semanticGood.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var polestarIDUnauthenticatedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.shield.exclamationmark")
                    .foregroundStyle(HisingenTheme.semanticWarning)
                    .hisSymbolSize(13)
                Text(L10n.text("Polestar ID: Sign In Required"))
                    .hisType(.caption, weight: .semibold)
            }
            Text(L10n.text("Polestar ID enables remote controls and streaming. Sign in via the interactive window to authorize your account."))
                .hisType(.micro)
                .foregroundStyle(.secondary)
                .hisCaptionLeading()
                .fixedSize(horizontal: false, vertical: true)

            Button {
                onSettingsChanged(.polestarWebSignIn)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.forward.app")
                    Text(L10n.text("Sign In with Polestar ID (Web)"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(8)
        .background(HisingenTheme.semanticWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var polestarDataPortalStatusBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(HisingenTheme.semanticGood)
                .hisSymbolSize(13)
            Text(L10n.text("Developer Portal: Configured"))
                .hisType(.caption, weight: .semibold)
            Spacer()
        }
        .padding(8)
        .background(HisingenTheme.semanticGood.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var polestarIDSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if enableDataPortal {
                Text(L10n.text("1. Polestar ID (Remote Controls)"))
                    .hisType(.caption, weight: .semibold)
                    .foregroundStyle(HisingenTheme.accent)
            }

            if let fallbackKind = polestarFallbackKind ?? inheritedPolestarFallbackKind {
                interactiveVerificationBanner(fallbackKind)
            } else if isPolestarIDSignedIn {
                polestarIDStatusBanner
            } else {
                polestarIDUnauthenticatedBanner
            }

            labeledField(L10n.text("Polestar ID (Email)")) {
                TextField("name@example.com", text: model.binding(\.polestarEmail))
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
            }
            if shouldShowEmailError {
                InlineValidationLabel(message: L10n.text("Enter a valid email address."))
            }

            labeledField(L10n.text("Password")) {
                SecureField(L10n.text("•••••••• (only to update credentials)"), text: model.binding(\.polestarPassword))
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
            }
        }
    }

    private func interactiveVerificationBanner(_ fallbackKind: SignInFailureKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "globe")
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Interactive Verification Required"))
                        .hisType(.label, weight: .semibold)
                    Text(L10n.text(fallbackCopy(for: fallbackKind)))
                        .hisType(.caption)
                        .foregroundStyle(.secondary)
                        .hisCaptionLeading()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                onSettingsChanged(.polestarWebSignIn)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.forward.app")
                    Text(L10n.text("Complete Interactive Sign-In"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            HStack(spacing: 4) {
                Text(L10n.text("Still failing?"))
                    .hisType(.micro)
                    .foregroundStyle(.tertiary)
                Button {
                    onSettingsChanged(.exportDiagnosticLogs)
                } label: {
                    Text(L10n.text("Export Diagnostic Logs"))
                        .hisType(.micro, weight: .medium)
                }
                .buttonStyle(.pressable)
                .help(L10n.text("Bundles recent app log entries, refresh diagnostics, and redacted API request metadata into one file you can attach to a bug report."))
            }
        }
        .padding(8)
        .background(HisingenTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(HisingenTheme.accent.opacity(0.3), lineWidth: 0.5)
        )
        .transition(.opacity)
    }

    private var polestarDataPortalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if enablePolestarID {
                Text(L10n.text("2. Developer Portal (EU Data Act Telemetry)"))
                    .hisType(.caption, weight: .semibold)
                    .foregroundStyle(HisingenTheme.accent)
            }

            if model.isDataPortalConfigured {
                polestarDataPortalStatusBanner
            }

            labeledField(L10n.text("Account ID (x-client-id)")) {
                TextField("0a7f033f-...", text: model.binding(\.polestarDataPortalAccountID))
                    .textFieldStyle(.roundedBorder)
            }

            labeledField(L10n.text("Client ID")) {
                TextField("client-id", text: model.binding(\.polestarDataPortalClientID))
                    .textFieldStyle(.roundedBorder)
            }

            labeledField(L10n.text("Client Secret")) {
                SecureField(L10n.text("•••••••• (only to update credentials)"), text: model.binding(\.polestarDataPortalClientSecret))
                    .textFieldStyle(.roundedBorder)
            }

            dataPortalQuotaView
        }
    }

    private var polestarSharedFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            labeledField(L10n.text("Vehicle Nickname (Optional)")) {
                TextField(L10n.text("e.g. My Polestar, Midnight"), text: model.binding(\.polestarNickname))
                    .textFieldStyle(.roundedBorder)
            }

            labeledField(L10n.text("VIN (Optional, auto-detected)")) {
                TextField("YSM...", text: model.binding(\.polestarVIN))
                    .textFieldStyle(.roundedBorder)
            }
            if shouldShowVINError {
                InlineValidationLabel(message: L10n.text("A VIN must contain 17 valid letters or digits."))
            }
        }
    }

    private var polestarActionButtons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(Motion.resolveCrossfade(Motion.stateChange)) {
                        attemptedPolestarSignIn = true
                    }
                    savePolestarConnection()
                } label: {
                    HStack(spacing: 4) {
                        if showSavedFeedback {
                            Image(systemName: "checkmark")
                            Text(polestarSaveButtonSavedTitle)
                        } else {
                            Image(systemName: "arrow.right.circle.fill")
                            Text(polestarSaveButtonTitle)
                        }
                    }
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                    .id(showSavedFeedback)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(enableDataPortal && !enablePolestarID && !model.canConnectDataPortal)
                .padding(.top, style == .welcoming ? 6 : 4)

                if enableDataPortal {
                    Button {
                        testCurrentConnection()
                    } label: {
                        HStack(spacing: 4) {
                            if isTestingConnection {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                            }
                            Text(L10n.text("Test Connection"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(isTestingConnection)
                    .padding(.top, style == .welcoming ? 6 : 4)
                }
            }

            if let test = testConnectionResult {
                dataPortalTestResultBanner(test)
            }

            if let keychainError {
                InlineValidationLabel(message: keychainError)
                    .transition(.opacity)
            }
        }
    }

    private func savePolestarConnection() {
        guard let outcome = model.savePolestar(mode: credentialSelection.mode) else { return }
        withAnimation(reduceMotion ? nil : Motion.stateChange) {
            showSavedFeedback = outcome.saved
            keychainError = outcome.keychainError
        }
        triggerSavedFeedbackReset()
        if let effect = outcome.effect {
            onSettingsChanged(effect == .credentialsChanged ? .credentials : .presentation)
        }
    }

    private var polestarSaveButtonTitle: String {
        if enablePolestarID && enableDataPortal {
            return L10n.text("Save Both & Connect")
        } else if enableDataPortal {
            return L10n.text("Save & Connect")
        } else {
            return L10n.text("Sign In")
        }
    }

    private var polestarSaveButtonSavedTitle: String {
        if enablePolestarID && enableDataPortal {
            return L10n.text("Saved & Connected (Both)")
        } else {
            return L10n.text("Saved & Connected")
        }
    }

    private var dataPortalQuotaView: some View {
        // The fastest cadence the app runs (charging or climate), so the projection shows the
        // day the governor will hold to when a scheduled refresh is at its tightest.
        let now = Date()
        let pacing = DataPortalQuotaGovernor.pace(
            requestedInterval: RefreshPolicy.regularInterval(isCharging: true),
            used: PolestarDataPortalAPI.dailyCallCount,
            secondsUntilReset: DataPortalQuotaGovernor.secondsUntilReset(now: now),
            now: now
        )
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.needle")
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                Text(L10n.format("Daily API usage: %d / %d calls", PolestarDataPortalAPI.dailyCallCount, PolestarDataPortalAPI.dailyCallLimit))
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(L10n.format("Projected by midnight UTC: %d calls", pacing.projection.projectedEndOfDay))
                .hisType(.micro)
                .foregroundStyle(.secondary)
                .padding(.leading, 18)
        }
        .padding(.top, 2)
    }

    private func dataPortalTestResultBanner(_ test: ConnectionCheck) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: test.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(test.success ? HisingenTheme.semanticGood : HisingenTheme.semanticCritical)
                .hisType(.caption)
            Text(test.message)
                .hisType(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (test.success ? HisingenTheme.semanticGood : HisingenTheme.semanticCritical).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    (test.success ? HisingenTheme.semanticGood : HisingenTheme.semanticCritical).opacity(0.25),
                    lineWidth: 0.5
                )
        )
        .transition(.opacity)
    }

    /// The email error shows once the reader has tried to sign in, and keeps showing while they
    /// fix it. A field nobody has touched is not shown as wrong.
    private var shouldShowEmailError: Bool {
        (attemptedPolestarSignIn || !model.draft.polestarEmail.isEmpty)
            && !SettingsValidation.isValidEmail(model.draft.polestarEmail)
    }

    /// Same for the optional VIN, which only complains once there is something to complain about.
    private var shouldShowVINError: Bool {
        !model.draft.polestarVIN.isEmpty && !SettingsValidation.isValidOptionalVIN(model.draft.polestarVIN)
    }

    private func triggerSavedFeedbackReset() {
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(reduceMotion ? nil : Motion.theme) {
                showSavedFeedback = false
            }
        }
    }
}
