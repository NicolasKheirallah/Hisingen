import SwiftUI

@MainActor
struct AccountCredentialsForm: View {
    enum Style {
        case compact
        case welcoming
    }

    let style: Style
    let onSettingsChanged: (SettingsChange) -> Void
    var onTestConnection: (VehicleBrand) async -> (success: Bool, message: String, failureKind: SignInFailureKind?) = { _ in
        (false, L10n.text("Connection testing is not available."), nil)
    }

    @State private var selectedBrand = VehicleBrand.polestar
    @Environment(\.preferencesStore) private var preferences
    @State private var polestarConnectionMode: PreferencesStore.PolestarConnectionMode = .polestarID
    @State private var polestarEmail = ""
    @State private var polestarPassword = ""
    @State private var polestarVIN = ""
    @State private var polestarNickname = ""
    @State private var polestarDataPortalAccountID = ""
    @State private var polestarDataPortalClientID = ""
    @State private var polestarDataPortalClientSecret = ""

    @State private var volvoClientID = ""
    @State private var volvoClientSecret = ""
    @State private var volvoApiKey = ""
    @State private var volvoVIN = ""
    @State private var volvoNickname = ""

    @State private var showCustomVolvoApp = false
    @State private var showSavedFeedback = false
    @State private var isTestingConnection = false
    @State private var testConnectionResult: (success: Bool, message: String, failureKind: SignInFailureKind?)?
    /// Local Keychain-save failures, kept separate from `testConnectionResult` so the
    /// banner's sessionExpired suppression can never hide them.
    @State private var keychainError: String?
    @State private var showUpdateFields = false
    /// Non-nil when the check (or the session state itself) says the interactive sign-in
    /// window is the way back in. The card copy adapts to which failure it represents.
    @State private var polestarFallbackKind: SignInFailureKind?
    @State private var attemptedPolestarSignIn = false
    @State private var attemptedVolvoSignIn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum ConnectionHealth { case active, connectedInactive, sessionExpired, notConnected }

    /// Whether the selected brand has enough on file (developer keys / account email, plus a
    /// previously-discovered VIN) to renew its session with a browser handshake alone – i.e.
    /// this is an *expired* session, not a brand that was never set up.
    private var hasRenewableCredentials: Bool {
        guard !preferences.vin(for: selectedBrand).isEmpty else { return false }
        switch selectedBrand {
        case .polestar:
            if preferences.polestarConnectionMode == .dataPortal {
                return !preferences.polestarDataPortalClientID.isEmpty && Keychain.hasStoredPolestarDataPortalCredentials
            }
            return Keychain.hasStoredPolestarEmail
        case .volvo:
            let hasClientID = !preferences.volvoClientID.isEmpty || BuiltinVolvoSecrets.isConfigured
            let hasSecrets = BuiltinVolvoSecrets.isConfigured
                || Keychain.hasStoredVolvoAppCredentials
            return hasClientID && hasSecrets
        }
    }

    private var connectionHealth: ConnectionHealth {
        // A live-check failure that reads like an auth problem is the strongest signal.
        if isBrandConnected, let result = testConnectionResult, !result.success,
           Self.looksLikeAuthFailure(result.message) {
            return .sessionExpired
        }
        if isBrandConnected {
            return isActiveBrand ? .active : .connectedInactive
        }
        // No resumable session, but the credentials to renew one are still on file.
        return hasRenewableCredentials ? .sessionExpired : .notConnected
    }

    private static func looksLikeAuthFailure(_ message: String) -> Bool {
        let needles = ["sign in", "signed in", "session", "expired", "credential",
                       "additional or changed sign-in", "no active session", "not permitted",
                       "authoriz", "token"]
        let lower = message.lowercased()
        return needles.contains { lower.contains($0) }
    }

    /// The kind the current session state implies before any check runs: an expired but
    /// renewable Polestar session means the interactive window is already the way back.
    private var inheritedPolestarFallbackKind: SignInFailureKind? {
        guard selectedBrand == .polestar, connectionHealth == .sessionExpired else { return nil }
        return .sessionExpired
    }

    private func fallbackCopy(for kind: SignInFailureKind) -> String {
        switch kind {
        case .signingFlowChanged:
            return "Polestar's sign-in page changed. Interactive Sign-In usually still works; if it doesn't, check for a Hisingen update."
        case .sessionExpired:
            return "Your Polestar session expired. Sign in again – the interactive window handles any new verification step Polestar added."
        default:
            return "Polestar presented a verification challenge (2FA, CAPTCHA, or Terms update). Complete sign-in in the interactive window."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .welcoming ? 14 : 10) {
            brandPicker

            accountStatusBanner

            if style == .welcoming || connectionHealth == .notConnected || showUpdateFields {
                if selectedBrand == .polestar {
                    polestarFields
                } else {
                    volvoFields
                }
            }
        }
        .onAppear {
            polestarConnectionMode = preferences.polestarConnectionMode
            let draft = preferences.accountDraft
            polestarEmail = draft.polestarEmail.isEmpty ? preferences.email : draft.polestarEmail
            polestarPassword = draft.polestarPassword
            polestarVIN = draft.polestarVIN.isEmpty ? preferences.vin(for: .polestar) : draft.polestarVIN
            polestarNickname = draft.polestarNickname.isEmpty ? preferences.vehicleNickname(for: polestarVIN) : draft.polestarNickname
            polestarDataPortalAccountID = draft.polestarDataPortalAccountID.isEmpty ? preferences.polestarDataPortalAccountID : draft.polestarDataPortalAccountID
            polestarDataPortalClientID = draft.polestarDataPortalClientID.isEmpty ? preferences.polestarDataPortalClientID : draft.polestarDataPortalClientID
            polestarDataPortalClientSecret = draft.polestarDataPortalClientSecret
            volvoClientID = draft.volvoClientID.isEmpty ? preferences.volvoClientID : draft.volvoClientID
            volvoClientSecret = draft.volvoClientSecret
            volvoApiKey = draft.volvoApiKey
            volvoVIN = draft.volvoVIN.isEmpty ? preferences.vin(for: .volvo) : draft.volvoVIN
            volvoNickname = draft.volvoNickname.isEmpty ? preferences.vehicleNickname(for: volvoVIN) : draft.volvoNickname
            preferences.accountDraft = .init(polestarEmail: polestarEmail, polestarPassword: polestarPassword,
                                             polestarVIN: polestarVIN, polestarNickname: polestarNickname,
                                             polestarDataPortalAccountID: polestarDataPortalAccountID,
                                             polestarDataPortalClientID: polestarDataPortalClientID,
                                             polestarDataPortalClientSecret: polestarDataPortalClientSecret,
                                             volvoClientID: volvoClientID, volvoClientSecret: volvoClientSecret,
                                             volvoApiKey: volvoApiKey, volvoVIN: volvoVIN, volvoNickname: volvoNickname)
            selectedBrand = preferences.activeBrand
        }
    }

    @ViewBuilder
    private var brandPicker: some View {
        if style == .welcoming {
            HStack(spacing: 8) {
                ForEach(VehicleBrand.allCases, id: \.self) { brand in
                    brandCard(brand)
                }
            }
        } else {
            Picker("", selection: $selectedBrand) {
                ForEach(VehicleBrand.allCases, id: \.self) { brand in
                    Text(brand.displayName).tag(brand)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: selectedBrand) { _, _ in
                withAnimation(Motion.resolveCrossfade(Motion.stateChange)) {
                    testConnectionResult = nil
                    keychainError = nil
                    polestarFallbackKind = nil
                    showUpdateFields = false
                }
            }
        }
    }

    private func brandCard(_ brand: VehicleBrand) -> some View {
        let isSelected = selectedBrand == brand
        let radius: CGFloat = HisingenTheme.cornerRadius == 0 ? 0 : 10
        return Button {
            withAnimation(reduceMotion ? nil : Motion.interaction) {
                selectedBrand = brand
                testConnectionResult = nil
                keychainError = nil
                polestarFallbackKind = nil
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: brand == .polestar ? "bolt.car.fill" : "car.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? HisingenTheme.accent : HisingenTheme.inkMuted)
                Text(brand.displayName)
                    .hisType(.body, weight: isSelected ? .semibold : .medium)
                    .foregroundStyle(isSelected ? HisingenTheme.ink : HisingenTheme.inkMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                isSelected ? HisingenTheme.accent.opacity(0.1) : Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(isSelected ? HisingenTheme.accent.opacity(0.45) : HisingenTheme.hairline,
                            lineWidth: isSelected ? 1.2 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var isBrandConnected: Bool {
        if selectedBrand == .polestar {
            if preferences.polestarConnectionMode == .dataPortal {
                return preferences.hasResumableSession(for: .polestar)
            }
            return preferences.hasSessionToken(for: .polestar)
        }
        return preferences.hasResumableSession(for: selectedBrand)
    }

    private var isActiveBrand: Bool {
        preferences.activeBrand == selectedBrand
    }

    @ViewBuilder
    private var accountStatusBanner: some View {
        let brandName = selectedBrand.displayName
        let activeLabel = preferences.lastVehicleLabel(for: selectedBrand)
        let health = connectionHealth
        let statusColor: Color = {
            switch health {
            case .active: return HisingenTheme.semanticGood
            case .connectedInactive: return HisingenTheme.semanticActive
            case .sessionExpired: return HisingenTheme.semanticWarning
            case .notConnected: return HisingenTheme.semanticWarning
            }
        }()
        let title: String = {
            switch health {
            case .active: return L10n.format("Connected · Active Account (%@)", brandName)
            case .connectedInactive: return L10n.format("Connected · Inactive Account (%@)", brandName)
            case .sessionExpired: return L10n.format("Session Expired · %@", brandName)
            case .notConnected: return L10n.format("Not Connected to %@", brandName)
            }
        }()

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if isTestingConnection {
                    ProgressView().controlSize(.mini)
                        .frame(width: 10, height: 10)
                        .transition(.opacity)
                } else {
                    Circle().fill(statusColor)
                        .frame(width: 8, height: 8)
                        .frame(width: 10, height: 10)
                        .transition(.opacity)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).hisType(.body, weight: .semibold)

                    switch health {
                    case .active, .connectedInactive:
                        Text(L10n.format("Vehicle: %@", activeLabel))
                            .hisType(.caption).foregroundStyle(.secondary)
                    case .sessionExpired:
                        Text(selectedBrand == .polestar
                             ? L10n.text("Your Polestar sign-in needs renewing. Re-sign in below – no password required.")
                             : L10n.text("Your Volvo sign-in needs renewing. Re-sign in below with the developer keys already saved."))
                            .hisType(.caption).foregroundStyle(.secondary)
                            .hisCaptionLeading()
                            .fixedSize(horizontal: false, vertical: true)
                    case .notConnected:
                        Text(L10n.text("Enter your credentials below to establish a live connection."))
                            .hisType(.caption).foregroundStyle(.secondary)
                            .hisCaptionLeading()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()

                if isBrandConnected && !isActiveBrand && health != .sessionExpired {
                    Button {
                        onSettingsChanged(.switchToBrand(selectedBrand))
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text(L10n.text("Set Active"))
                        }
                        .hisType(.caption, weight: .semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
            }

            if style != .welcoming && (isBrandConnected || health == .sessionExpired) {
                HStack(spacing: 6) {
                    reSignInButton(prominent: health == .sessionExpired)

                    Button {
                        withAnimation(reduceMotion ? nil : Motion.selection) {
                            showUpdateFields.toggle()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: showUpdateFields ? "chevron.up" : "pencil")
                            Text(showUpdateFields ? L10n.text("Done") : L10n.text("Edit Credentials"))
                        }
                        .hisType(.caption, weight: .medium)
                    }
                    .controlSize(.mini)

                    if isBrandConnected {
                        Button {
                            testCurrentConnection()
                        } label: {
                            Text(L10n.text("Test"))
                                .hisType(.caption, weight: .medium)
                        }
                        .controlSize(.mini)
                        .disabled(isTestingConnection)
                    }

                    Spacer()
                }
            }

            if let test = testConnectionResult, !(health == .sessionExpired && !test.success) {
                HStack(spacing: 6) {
                    Image(systemName: test.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(test.success ? HisingenTheme.semanticGood : HisingenTheme.semanticCritical)
                        .hisType(.caption)
                    Text(test.message)
                        .hisType(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
                .transition(.opacity)
            }
        }
        .padding(10)
        .background(statusColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(statusColor.opacity(0.25), lineWidth: 0.5)
        )
        // The Test flow mutates state from a Task continuation with no surrounding
        // transaction; this binding powers the spinner↔dot swap and result row.
        .hisAnimation(Motion.stateChange, value: isTestingConnection)
    }

    @ViewBuilder
    private func reSignInButton(prominent: Bool) -> some View {
        let label = HStack(spacing: 3) {
            Image(systemName: "arrow.clockwise.circle")
            Text(L10n.text("Re-sign In"))
        }
        .hisType(.caption, weight: .semibold)

        if prominent {
            Button { onSettingsChanged(.reauthenticate(selectedBrand)) } label: { label }
                .buttonStyle(.borderedProminent)
                .tint(HisingenTheme.semanticWarning)
                .controlSize(.mini)
        } else {
            Button { onSettingsChanged(.reauthenticate(selectedBrand)) } label: { label }
                .buttonStyle(.bordered)
                .controlSize(.mini)
        }
    }

    private var polestarFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.text("Connection Mode"), selection: $polestarConnectionMode) {
                ForEach(PreferencesStore.PolestarConnectionMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: polestarConnectionMode) { oldMode, newMode in
                guard oldMode != newMode else { return }
                preferences.polestarConnectionMode = newMode
                withAnimation(Motion.resolveCrossfade(Motion.stateChange)) {
                    testConnectionResult = nil
                    keychainError = nil
                    polestarFallbackKind = nil
                }
                if preferences.hasResumableSession(for: .polestar) {
                    onSettingsChanged(.credentials)
                }
            }

            switch polestarConnectionMode {
            case .polestarID:
                polestarIDFields
            case .dataPortal:
                polestarDataPortalFields
            case .augmented:
                polestarAugmentedFields
            }
        }
    }

    private var polestarIDFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            if style == .welcoming {
                Text(L10n.text("Sign in with your Polestar ID email and password."))
                    .hisType(.label)
                    .foregroundStyle(.secondary)
            }

            labeledField(L10n.text("Polestar ID (Email)")) {
                TextField("name@example.com", text: $polestarEmail)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .onChange(of: polestarEmail) { _, value in preferences.accountDraft.polestarEmail = value }
            }
            if shouldShowEmailError {
                InlineValidationLabel(message: L10n.text("Enter a valid email address."))
            }

            labeledField(L10n.text("Password")) {
                SecureField(L10n.text("•••••••• (only to update credentials)"), text: $polestarPassword)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .onChange(of: polestarPassword) { _, value in preferences.accountDraft.polestarPassword = value }
            }

            labeledField(L10n.text("Vehicle Nickname (Optional)")) {
                TextField(L10n.text("e.g. My Polestar, Midnight"), text: $polestarNickname)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: polestarNickname) { _, value in preferences.accountDraft.polestarNickname = value }
            }

            labeledField(L10n.text("VIN (Optional, auto-detected)")) {
                TextField("YSM...", text: $polestarVIN)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: polestarVIN) { _, value in preferences.accountDraft.polestarVIN = value }
            }
            if shouldShowVINError {
                InlineValidationLabel(message: L10n.text("A VIN must contain 17 valid letters or digits."))
            }

            if let fallbackKind = polestarFallbackKind ?? inheritedPolestarFallbackKind {
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

            Button {
                // Only the attempt flag is animated – keying on the field text would
                // re-render (and risk focus churn) on every keystroke.
                withAnimation(Motion.resolveCrossfade(Motion.stateChange)) {
                    attemptedPolestarSignIn = true
                }
                savePolestarCredentials()
            } label: {
                HStack(spacing: 4) {
                    if showSavedFeedback {
                        Image(systemName: "checkmark")
                        Text(L10n.text("Saved & Connected"))
                    } else {
                        Image(systemName: "arrow.right.circle.fill")
                        Text(L10n.text("Sign In"))
                    }
                }
                .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                .id(showSavedFeedback)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            // Deliberately not `.disabled(...)`. It used to be disabled by the same predicate that
            // decides whether the inline errors show, and the only write to `attemptedPolestarSignIn`
            // is inside this action, so a first-time user who mistyped their email saw a permanently
            // dead button and never the sentence written for exactly that mistake. Pressing it now
            // reveals the error, and the labels update live from then on because the condition
            // re-evaluates on every keystroke.
            .help(polestarFormIsValid
                  ? L10n.text("Saves these credentials and connects.")
                  : L10n.text("Some details still need fixing. Press to see what."))
            .accessibilityHint(polestarFormIsValid
                               ? L10n.text("Saves these credentials and connects.")
                               : L10n.text("Some details still need fixing. Press to see what."))
            .padding(.top, style == .welcoming ? 6 : 4)

            if let keychainError {
                InlineValidationLabel(message: keychainError)
                    .transition(.opacity)
            }
        }
    }

    private var polestarDataPortalFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            if style == .welcoming {
                Text(L10n.text("Connect to Polestar Developer Portal using EU Data Act M2M credentials."))
                    .hisType(.label)
                    .foregroundStyle(.secondary)
            }

            labeledField(L10n.text("Account ID (x-client-id)")) {
                TextField("0a7f033f-...", text: $polestarDataPortalAccountID)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: polestarDataPortalAccountID) { _, val in
                        preferences.accountDraft.polestarDataPortalAccountID = val
                    }
            }

            labeledField(L10n.text("Client ID")) {
                TextField("client-id", text: $polestarDataPortalClientID)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: polestarDataPortalClientID) { _, val in
                        preferences.accountDraft.polestarDataPortalClientID = val
                    }
            }

            labeledField(L10n.text("Client Secret")) {
                SecureField(L10n.text("•••••••• (only to update credentials)"), text: $polestarDataPortalClientSecret)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: polestarDataPortalClientSecret) { _, val in
                        preferences.accountDraft.polestarDataPortalClientSecret = val
                    }
            }

            labeledField(L10n.text("Vehicle Nickname (Optional)")) {
                TextField(L10n.text("e.g. My Polestar, Midnight"), text: $polestarNickname)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: polestarNickname) { _, val in preferences.accountDraft.polestarNickname = val }
            }

            labeledField(L10n.text("VIN (Optional, auto-detected)")) {
                TextField("YSM...", text: $polestarVIN)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: polestarVIN) { _, val in preferences.accountDraft.polestarVIN = val }
            }
            if shouldShowVINError {
                InlineValidationLabel(message: L10n.text("A VIN must contain 17 valid letters or digits."))
            }

            dataPortalActionButtons

            dataPortalQuotaView

            if let test = testConnectionResult {
                dataPortalTestResultBanner(test)
            }

            if let keychainError {
                InlineValidationLabel(message: keychainError)
                    .transition(.opacity)
            }
        }
    }

    private var dataPortalActionButtons: some View {
        HStack(spacing: 8) {
            savePolestarDataPortalButton

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

    private var dataPortalQuotaView: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.needle")
                .hisType(.micro)
                .foregroundStyle(.secondary)
            Text(L10n.format("Daily API usage: %d / %d calls", PolestarDataPortalAPI.dailyCallCount, PolestarDataPortalAPI.dailyCallLimit))
                .hisType(.micro)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 2)
    }

    private func dataPortalTestResultBanner(_ test: (success: Bool, message: String, failureKind: SignInFailureKind?)) -> some View {
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

    private var isDataPortalConfiguredOrEntered: Bool {
        let hasID = !polestarDataPortalClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !BuiltinPolestarSecrets.dataPortalClientID.isEmpty
        return hasID && isValidOptionalVIN(polestarVIN)
    }

    private var savePolestarDataPortalButton: some View {
        Button {
            savePolestarDataPortalCredentials()
        } label: {
            HStack(spacing: 4) {
                if showSavedFeedback {
                    Image(systemName: "checkmark")
                    Text(L10n.text("Saved & Connected"))
                } else {
                    Image(systemName: "arrow.right.circle.fill")
                    Text(L10n.text("Save & Connect"))
                }
            }
            .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
            .id(showSavedFeedback)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(!isDataPortalConfiguredOrEntered)
        .padding(.top, style == .welcoming ? 6 : 4)
    }

    private var polestarAugmentedFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(HisingenTheme.accent)
                    .hisType(.label)
                Text(L10n.text("Augmented mode pairs Developer Portal M2M telemetry with your Polestar ID for interactive remote controls and gRPC streaming."))
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

            Text(L10n.text("1. Polestar ID (Remote Controls)"))
                .hisType(.caption, weight: .semibold)
                .foregroundStyle(HisingenTheme.accent)

            labeledField(L10n.text("Polestar ID (Email)")) {
                TextField("name@example.com", text: $polestarEmail)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .onChange(of: polestarEmail) { _, val in preferences.accountDraft.polestarEmail = val }
            }
            if shouldShowEmailError {
                InlineValidationLabel(message: L10n.text("Enter a valid email address."))
            }

            labeledField(L10n.text("Password")) {
                SecureField(L10n.text("•••••••• (only to update credentials)"), text: $polestarPassword)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .onChange(of: polestarPassword) { _, val in preferences.accountDraft.polestarPassword = val }
            }

            Divider().padding(.vertical, 2)

            Text(L10n.text("2. Developer Portal (M2M Telemetry)"))
                .hisType(.caption, weight: .semibold)
                .foregroundStyle(HisingenTheme.accent)

            labeledField(L10n.text("Account ID (x-client-id)")) {
                TextField("0a7f033f-...", text: $polestarDataPortalAccountID)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: polestarDataPortalAccountID) { _, val in
                        preferences.accountDraft.polestarDataPortalAccountID = val
                    }
            }

            labeledField(L10n.text("Client ID")) {
                TextField("client-id", text: $polestarDataPortalClientID)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: polestarDataPortalClientID) { _, val in
                        preferences.accountDraft.polestarDataPortalClientID = val
                    }
            }

            labeledField(L10n.text("Client Secret")) {
                SecureField(L10n.text("•••••••• (only to update credentials)"), text: $polestarDataPortalClientSecret)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: polestarDataPortalClientSecret) { _, val in
                        preferences.accountDraft.polestarDataPortalClientSecret = val
                    }
            }

            Divider().padding(.vertical, 2)

            labeledField(L10n.text("Vehicle Nickname (Optional)")) {
                TextField(L10n.text("e.g. My Polestar, Midnight"), text: $polestarNickname)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: polestarNickname) { _, val in preferences.accountDraft.polestarNickname = val }
            }

            labeledField(L10n.text("VIN (Optional, auto-detected)")) {
                TextField("YSM...", text: $polestarVIN)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: polestarVIN) { _, val in preferences.accountDraft.polestarVIN = val }
            }

            savePolestarAugmentedButton
            dataPortalQuotaView

            if let keychainError {
                InlineValidationLabel(message: keychainError)
                    .transition(.opacity)
            }
        }
    }

    private var savePolestarAugmentedButton: some View {
        Button {
            savePolestarAugmentedCredentials()
        } label: {
            HStack(spacing: 4) {
                if showSavedFeedback {
                    Image(systemName: "checkmark")
                    Text(L10n.text("Saved & Connected (Augmented)"))
                } else {
                    Image(systemName: "arrow.right.circle.fill")
                    Text(L10n.text("Save Both & Connect"))
                }
            }
            .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
            .id(showSavedFeedback)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .padding(.top, style == .welcoming ? 6 : 4)
    }

    private func savePolestarAugmentedCredentials() {
        savePolestarCredentials()
        savePolestarDataPortalCredentials()
    }


    private func savePolestarDataPortalCredentials() {
        let trimmedID = polestarDataPortalClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = polestarDataPortalClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccountID = polestarDataPortalAccountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return }

        var keychainFailed = false
        if !trimmedSecret.isEmpty {
            do {
                try Keychain.savePolestarDataPortalCredentials(
                    accountID: trimmedAccountID.isEmpty ? nil : trimmedAccountID,
                    clientID: trimmedID,
                    clientSecret: trimmedSecret
                )
                polestarDataPortalClientSecret = ""
                preferences.accountDraft.polestarDataPortalClientSecret = ""
            } catch {
                keychainFailed = true
            }
        }
        withAnimation(reduceMotion ? nil : Motion.stateChange) {
            showSavedFeedback = !keychainFailed
            if keychainFailed {
                keychainError = L10n.text("Couldn't save credentials to the Keychain. Please try again.")
            }
        }
        triggerSavedFeedbackReset()
        guard !keychainFailed else { return }
        persistPolestarDataPortalPreferences(accountID: trimmedAccountID, clientID: trimmedID)
    }

    private func triggerSavedFeedbackReset() {
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(reduceMotion ? nil : Motion.theme) {
                showSavedFeedback = false
            }
        }
    }

    private func persistPolestarDataPortalPreferences(accountID: String, clientID: String) {
        preferences.polestarConnectionMode = .dataPortal
        preferences.polestarDataPortalAccountID = accountID
        preferences.polestarDataPortalClientID = clientID
        let upperVIN = polestarVIN.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        preferences.setVin(upperVIN, for: .polestar)
        let nickVIN = !upperVIN.isEmpty ? upperVIN : preferences.vin(for: .polestar)
        if !nickVIN.isEmpty {
            preferences.setVehicleNickname(polestarNickname, for: nickVIN)
        }
        onSettingsChanged(.credentials)
    }

    private var hasResumableVolvoSession: Bool {
        let trimmedClientID = volvoClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientID.isEmpty, trimmedClientID == preferences.volvoClientID,
              volvoClientSecret.isEmpty, volvoApiKey.isEmpty else { return false }
        return preferences.hasResumableSession(for: .volvo)
    }

    private var volvoFields: some View {
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
                    "Register a free API application at developer.volvocars.com to get a Client ID, "
                    + "Client Secret, and VCC API Key, then sign in with your Volvo ID below. "
                    + "Hisingen never sees your Volvo ID password directly – sign-in happens in a "
                    + "system browser window."
                ))
                .hisType(.caption)
                .foregroundStyle(.secondary)
                .hisCaptionLeading()
                .hisCaptionLeading()
                .fixedSize(horizontal: false, vertical: true)

                if BuiltinVolvoSecrets.isConfigured {
                    HStack {
                        Spacer()
                        Button {
                            showCustomVolvoApp = false
                            volvoClientID = ""
                            volvoClientSecret = ""
                            volvoApiKey = ""
                        } label: {
                            Text(L10n.text("Use Default Developer Keys"))
                                .hisType(.caption)
                        }
                        .buttonStyle(.pressable)
                        .foregroundStyle(HisingenTheme.accent)
                    }
                }

                labeledField(L10n.text("Client ID")) {
                    TextField("Client ID", text: $volvoClientID)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: volvoClientID) { _, value in preferences.accountDraft.volvoClientID = value }
                }

                labeledField(L10n.text("Client Secret")) {
                    SecureField(hasResumableVolvoSession && volvoClientSecret.isEmpty
                                ? L10n.text("•••••••• (Saved in Keychain)")
                                : L10n.text("Client Secret"), text: $volvoClientSecret)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: volvoClientSecret) { _, value in preferences.accountDraft.volvoClientSecret = value }
                }

                labeledField(L10n.text("VCC API Key")) {
                    SecureField(hasResumableVolvoSession && volvoApiKey.isEmpty
                                ? L10n.text("•••••••• (Saved in Keychain)")
                                : L10n.text("VCC API Key"), text: $volvoApiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: volvoApiKey) { _, value in preferences.accountDraft.volvoApiKey = value }
                }
            }

            labeledField(L10n.text("Vehicle Nickname (Optional)")) {
                TextField(L10n.text("e.g. My Volvo, Family car"), text: $volvoNickname)
                    .textFieldStyle(.roundedBorder)
                        .onChange(of: volvoNickname) { _, value in preferences.accountDraft.volvoNickname = value }
            }

            labeledField(L10n.text("VIN (Optional, auto-detected)")) {
                TextField("YV1...", text: $volvoVIN)
                    .textFieldStyle(.roundedBorder)
                        .onChange(of: volvoVIN) { _, value in preferences.accountDraft.volvoVIN = value }
            }
            if attemptedVolvoSignIn && !isValidOptionalVIN(volvoVIN) {
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
                    Text(hasResumableVolvoSession
                         ? L10n.text("Switch to Volvo Account")
                         : L10n.text("Sign in with Volvo ID"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled((!BuiltinVolvoSecrets.isConfigured && volvoClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || !isValidOptionalVIN(volvoVIN))
            .padding(.top, style == .welcoming ? 6 : 4)
        }
    }

    private func testCurrentConnection() {
        withAnimation(Motion.resolveCrossfade(Motion.stateChange)) {
            isTestingConnection = true
            testConnectionResult = nil
        }
        let brand = selectedBrand
        Task {
            let result = await onTestConnection(brand)
            // Reset before the brand guard so a mid-check brand switch can't leave the
            // spinner running and the Test button disabled.
            withAnimation(Motion.resolveCrossfade(Motion.stateChange)) {
                isTestingConnection = false
            }
            guard brand == selectedBrand else { return } // user switched brands mid-check
            // The result row and the interactive-verification panel both declare
            // transitions; without this transaction they would pop in instead.
            withAnimation(Motion.resolveCrossfade(Motion.stateChange)) {
                testConnectionResult = result
                if brand == .polestar, let kind = result.failureKind, kind.interactiveSignInHelps {
                    polestarFallbackKind = kind
                }
            }
        }
    }

    private var polestarFormIsValid: Bool {
        isValidEmail(polestarEmail) && isValidOptionalVIN(polestarVIN)
    }

    /// The email error shows once the reader has tried to sign in, and keeps showing while they
    /// fix it. A field nobody has touched is not shown as wrong.
    private var shouldShowEmailError: Bool {
        (attemptedPolestarSignIn || !polestarEmail.isEmpty) && !isValidEmail(polestarEmail)
    }

    /// Same for the optional VIN, which only complains once there is something to complain about.
    private var shouldShowVINError: Bool {
        !polestarVIN.isEmpty && !isValidOptionalVIN(polestarVIN)
    }

    private func savePolestarCredentials() {
        guard isValidEmail(polestarEmail), isValidOptionalVIN(polestarVIN) else { return }
        keychainError = nil
        let normalizedEmail = polestarEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let upperVIN = polestarVIN.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let oldVIN = preferences.vin(for: .polestar)
        let nicknameVIN = upperVIN.isEmpty ? oldVIN : upperVIN
        let credentialsChanged = normalizedEmail != preferences.email || upperVIN != oldVIN || !polestarPassword.isEmpty
        var keychainFailed = false
        if !polestarPassword.isEmpty {
            do {
                try Keychain.savePassword(polestarPassword)
                // The plaintext must not linger: neither in this view's state nor in the
                // app-lifetime draft store on `PreferencesStore`.
                polestarPassword = ""
                preferences.accountDraft.polestarPassword = ""
            } catch {
                keychainFailed = true
            }
        }
        withAnimation(reduceMotion ? nil : Motion.stateChange) {
            showSavedFeedback = !keychainFailed
            if keychainFailed {
                keychainError = L10n.text("Couldn't save the password to the Keychain. Please try again.")
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(reduceMotion ? nil : Motion.theme) {
                showSavedFeedback = false
            }
        }
        guard !keychainFailed else { return }
        // Persist identity only after a new password has reached Keychain successfully. A
        // Keychain denial must not leave an email/VIN pointing at credentials that were not
        // actually saved.
        preferences.polestarConnectionMode = .polestarID
        preferences.email = normalizedEmail
        preferences.setVin(upperVIN, for: .polestar)
        if !nicknameVIN.isEmpty {
            preferences.setVehicleNickname(polestarNickname, for: nicknameVIN)
        }
        onSettingsChanged(credentialsChanged ? .credentials : .presentation)
    }

    private func beginVolvoSignIn() {
        guard isValidOptionalVIN(volvoVIN) else { return }
        let upperVIN = volvoVIN.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let trimmedClientID = volvoClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldVIN = preferences.vin(for: .volvo)
        preferences.volvoClientID = trimmedClientID
        preferences.setVin(upperVIN, for: .volvo)
        if !upperVIN.isEmpty {
            preferences.setVehicleNickname(volvoNickname, for: upperVIN)
        } else {
            if !oldVIN.isEmpty {
                preferences.setVehicleNickname(volvoNickname, for: oldVIN)
            }
        }
        let idToSend = !trimmedClientID.isEmpty ? trimmedClientID : BuiltinVolvoSecrets.clientID
        let secretToSend = !volvoClientSecret.isEmpty ? volvoClientSecret : BuiltinVolvoSecrets.clientSecret
        let apiKeyToSend = !volvoApiKey.isEmpty ? volvoApiKey : BuiltinVolvoSecrets.vccApiKey
        onSettingsChanged(.volvoSignIn(
            clientID: idToSend,
            clientSecret: secretToSend,
            vccApiKey: apiKeyToSend,
            nickname: volvoNickname
        ))
        // The secrets were handed to the sign-in flow; drop the plaintext copies here and in
        // the app-lifetime draft store so they don't outlive the Settings sheet.
        volvoClientSecret = ""
        volvoApiKey = ""
        preferences.accountDraft.volvoClientSecret = ""
        preferences.accountDraft.volvoApiKey = ""
    }

    private func isValidEmail(_ value: String) -> Bool {
        SettingsValidation.isValidEmail(value)
    }

    private func isValidOptionalVIN(_ value: String) -> Bool {
        SettingsValidation.isValidOptionalVIN(value)
    }

    private func labeledField<Content: View>(_ label: String, @ViewBuilder field: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .hisType(.label, weight: .medium)
                .foregroundStyle(.secondary)
            field()
        }
    }
}
