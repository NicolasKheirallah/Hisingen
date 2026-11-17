import SwiftUI

/// The Polestar section of the account card: sign-in option choice, the Polestar ID and
/// Developer Portal fields, and the save and test actions.
extension AccountCredentialsForm {
    private var enablePolestarID: Bool { credentialSelection.enablePolestarID }
    private var enableDataPortal: Bool { credentialSelection.enableDataPortal }

    var polestarFields: some View {
        VStack(alignment: .leading, spacing: style == .welcoming ? 16 : 10) {
            polestarCredentialSelector

            polestarModeExplanation

            if enablePolestarID {
                polestarIDSection
            }

            if enablePolestarID && enableDataPortal {
                PanelRule().padding(.vertical, 2)
            }

            if enableDataPortal {
                polestarDataPortalSection
            }

            // The nickname and VIN are optional and live in Settings. On the first sign-in they
            // only pushed the button off the panel.
            if style != .welcoming {
                PanelRule().padding(.vertical, 2)

                polestarSharedFields
            }

            polestarActionButtons
        }
        // Return in any field does what the form's button does, with the same guard.
        .onSubmit { submitPolestarConnection() }
    }

    /// Which Polestar sign-in routes are on. Both can be, so each is an underlined word that
    /// toggles on its own, the same mark the brand row uses for a chosen place, one step quieter.
    private var polestarCredentialSelector: some View {
        HStack(spacing: 20) {
            credentialOption(
                title: L10n.text("Polestar ID"),
                detail: L10n.text("Remote Controls"),
                isSelected: enablePolestarID
            ) {
                togglePolestarCredentialOption(polestarID: true)
            }

            credentialOption(
                title: L10n.text("Developer Portal"),
                detail: L10n.text("EU Data Act"),
                isSelected: enableDataPortal
            ) {
                togglePolestarCredentialOption(polestarID: false)
            }
            Spacer(minLength: 0)
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

    private func credentialOption(
        title: String,
        detail: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .hisType(.label)
                .lineLimit(1)
                .foregroundStyle(isSelected ? HisingenTheme.ink : HisingenTheme.inkMuted)
                .frame(minHeight: 28)
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Rectangle()
                            .fill(HisingenTheme.ink)
                            .frame(height: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var polestarModeExplanation: some View {
        Text(credentialSelection.mode.detailDescription)
            .hisType(.label)
            .foregroundStyle(HisingenTheme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
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
        .padding(.leading, 2)
        .hisNotice(HisingenTheme.semanticGood)
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
            .buttonStyle(.hisProminent)
            .controlSize(.regular)
            .padding(.top, 4)
        }
        .padding(.vertical, 4)
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
        .padding(.leading, 2)
        .hisNotice(HisingenTheme.semanticGood)
    }

    private var polestarIDSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if enableDataPortal {
                Text(L10n.text("1. Polestar ID (Remote Controls)"))
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.inkMuted)
            }

            if let fallbackKind = polestarFallbackKind ?? inheritedPolestarFallbackKind {
                interactiveVerificationBanner(fallbackKind)
            } else if isPolestarIDSignedIn {
                polestarIDStatusBanner
            } else if style == .welcoming {
                polestarWebSignInButton
            } else {
                polestarIDUnauthenticatedBanner
            }

            if style == .welcoming && !isPolestarIDSignedIn {
                Text(L10n.text("Sign in with your Polestar ID email and password."))
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }

            labeledField(L10n.text("Polestar ID (Email)")) {
                HisTextField("name@example.com", text: model.binding(\.polestarEmail),
                             label: L10n.text("Polestar ID (Email)"))
                    .textContentType(.username)
            }
            if shouldShowEmailError {
                InlineValidationLabel(message: L10n.text("Enter a valid email address."))
            }

            labeledField(L10n.text("Password")) {
                HisSecureField(polestarPasswordPrompt, text: model.binding(\.polestarPassword),
                               label: L10n.text("Password"))
                    .textContentType(.password)
            }
        }
    }

    /// The first sign-in's primary action: the browser handoff, which also handles any
    /// verification step Polestar adds. Email and password below it are the second route.
    private var polestarWebSignInButton: some View {
        Button {
            onSettingsChanged(.polestarWebSignIn)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.forward.app")
                Text(L10n.text("Sign In with Polestar ID (Web)"))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.hisProminent)
        .controlSize(.regular)
    }

    /// A reader who has never saved an account has no password to "update", so the update
    /// wording only shows once an email is on file. The label above already says Password.
    private var polestarPasswordPrompt: String {
        style == .welcoming && preferences.email.isEmpty
            ? ""
            : L10n.text("•••••••• (only to update credentials)")
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
            .buttonStyle(.hisProminent)
            .controlSize(.small)
            HStack(spacing: 4) {
                Text(L10n.text("Still failing?"))
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
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
        .background(HisingenTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 0))
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(HisingenTheme.accent.opacity(0.3), lineWidth: 0.5)
        )
        .transition(.opacity)
    }

    private var polestarDataPortalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if enablePolestarID {
                Text(L10n.text("2. Developer Portal (EU Data Act Telemetry)"))
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.inkMuted)
            }

            if model.isDataPortalConfigured {
                polestarDataPortalStatusBanner
            }

            labeledField(L10n.text("Account ID (x-client-id)")) {
                HisTextField("0a7f033f-...", text: model.binding(\.polestarDataPortalAccountID))
            }

            labeledField(L10n.text("Client ID")) {
                HisTextField("client-id", text: model.binding(\.polestarDataPortalClientID))
            }

            labeledField(L10n.text("Client Secret")) {
                HisSecureField(L10n.text("•••••••• (only to update credentials)"), text: model.binding(\.polestarDataPortalClientSecret))
            }

            if style != .welcoming {
                dataPortalQuotaView
            }
        }
    }

    private var polestarSharedFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            labeledField(L10n.text("Vehicle Nickname (Optional)")) {
                HisTextField(L10n.text("e.g. My Polestar, Midnight"), text: model.binding(\.polestarNickname))
            }

            labeledField(L10n.text("VIN (Optional, auto-detected)")) {
                HisTextField("YSM...", text: model.binding(\.polestarVIN))
            }
            if shouldShowVINError {
                InlineValidationLabel(message: L10n.text("A VIN must contain 17 valid letters or digits."))
            }
        }
    }

    private var polestarActionButtons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                let save = Button {
                    submitPolestarConnection()
                } label: {
                    HStack(spacing: 4) {
                        if showSavedFeedback {
                            Image(systemName: "checkmark")
                            Text(polestarSaveButtonSavedTitle)
                        } else {
                            Text(polestarSaveButtonTitle)
                        }
                    }
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                    .id(showSavedFeedback)
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
                .disabled(polestarSaveDisabled)
                .padding(.top, style == .welcoming ? 6 : 4)

                if enablePolestarID && (!isPolestarIDSignedIn || (polestarFallbackKind ?? inheritedPolestarFallbackKind) != nil) {
                    save.buttonStyle(.hisSecondary)
                } else {
                    save.buttonStyle(.hisProminent)
                }

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
                    .buttonStyle(.hisSecondary)
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

    private var polestarSaveDisabled: Bool {
        enableDataPortal && !enablePolestarID && !model.canConnectDataPortal
    }

    private func submitPolestarConnection() {
        guard !polestarSaveDisabled else { return }
        withAnimation(Motion.resolveCrossfade(Motion.stateChange)) {
            attemptedPolestarSignIn = true
        }
        savePolestarConnection()
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
            in: RoundedRectangle(cornerRadius: 0)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 0)
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
