import SwiftUI

@MainActor
struct AccountCredentialsForm: View {
    enum Style {
        case compact
        case welcoming
    }

    let style: Style
    let onSettingsChanged: (SettingsChange) -> Void
    var onTestConnection: (VehicleBrand) async -> (success: Bool, message: String) = { _ in
        (false, L10n.text("Connection testing is not available."))
    }

    @State private var selectedBrand = VehicleBrand.polestar
    @Environment(\.preferencesStore) private var preferences
    @State private var polestarEmail = ""
    @State private var polestarPassword = ""
    @State private var polestarVIN = ""
    @State private var polestarNickname = ""

    @State private var volvoClientID = ""
    @State private var volvoClientSecret = ""
    @State private var volvoApiKey = ""
    @State private var volvoVIN = ""
    @State private var volvoNickname = ""

    @State private var showCustomVolvoApp = false
    @State private var showSavedFeedback = false
    @State private var isTestingConnection = false
    @State private var testConnectionResult: (success: Bool, message: String)?
    @State private var showUpdateFields = false
    @State private var showPolestarInteractiveFallback = false
    @State private var attemptedPolestarSignIn = false
    @State private var attemptedVolvoSignIn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum ConnectionHealth { case active, connectedInactive, sessionExpired, notConnected }

    /// Whether the selected brand has enough on file (developer keys / account email, plus a
    /// previously-discovered VIN) to renew its session with a browser handshake alone — i.e.
    /// this is an *expired* session, not a brand that was never set up.
    private var hasRenewableCredentials: Bool {
        guard !preferences.vin(for: selectedBrand).isEmpty else { return false }
        switch selectedBrand {
        case .polestar:
            return !preferences.email.isEmpty
        case .volvo:
            let hasClientID = !preferences.volvoClientID.isEmpty || BuiltinVolvoSecrets.isConfigured
            let hasSecrets = BuiltinVolvoSecrets.isConfigured
                || ((try? Keychain.readVolvoClientSecret()) ?? nil)?.isEmpty == false
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
            let draft = preferences.accountDraft
            polestarEmail = draft.polestarEmail.isEmpty ? preferences.email : draft.polestarEmail
            polestarPassword = draft.polestarPassword
            polestarVIN = draft.polestarVIN.isEmpty ? preferences.vin(for: .polestar) : draft.polestarVIN
            polestarNickname = draft.polestarNickname.isEmpty ? preferences.vehicleNickname(for: polestarVIN) : draft.polestarNickname
            volvoClientID = draft.volvoClientID.isEmpty ? preferences.volvoClientID : draft.volvoClientID
            volvoClientSecret = draft.volvoClientSecret
            volvoApiKey = draft.volvoApiKey
            volvoVIN = draft.volvoVIN.isEmpty ? preferences.vin(for: .volvo) : draft.volvoVIN
            volvoNickname = draft.volvoNickname.isEmpty ? preferences.vehicleNickname(for: volvoVIN) : draft.volvoNickname
            preferences.accountDraft = .init(polestarEmail: polestarEmail, polestarPassword: polestarPassword,
                                             polestarVIN: polestarVIN, polestarNickname: polestarNickname,
                                             volvoClientID: volvoClientID, volvoClientSecret: volvoClientSecret,
                                             volvoApiKey: volvoApiKey, volvoVIN: volvoVIN, volvoNickname: volvoNickname)
            selectedBrand = preferences.activeBrand
        }
        .onDisappear {
            // Drafts improve navigation, but credentials must never survive the form.
            polestarPassword = ""
            volvoClientSecret = ""
            volvoApiKey = ""
            preferences.accountDraft.polestarPassword = ""
            preferences.accountDraft.volvoClientSecret = ""
            preferences.accountDraft.volvoApiKey = ""
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
                testConnectionResult = nil
                showPolestarInteractiveFallback = false
                showUpdateFields = false
            }
        }
    }

    private func brandCard(_ brand: VehicleBrand) -> some View {
        let isSelected = selectedBrand == brand
        let radius: CGFloat = HisingenTheme.cornerRadius == 0 ? 0 : 10
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                selectedBrand = brand
                testConnectionResult = nil
                showPolestarInteractiveFallback = false
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: brand == .polestar ? "bolt.car.fill" : "car.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? HisingenTheme.accent : HisingenTheme.inkMuted)
                Text(brand.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
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
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var isBrandConnected: Bool {
        preferences.hasResumableSession(for: selectedBrand)
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
            case .active: return .green
            case .connectedInactive: return .blue
            case .sessionExpired: return .orange
            case .notConnected: return .orange
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
                    ProgressView().controlSize(.small).frame(width: 8, height: 8)
                } else {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .semibold))

                    switch health {
                    case .active, .connectedInactive:
                        Text(L10n.format("Vehicle: %@", activeLabel))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    case .sessionExpired:
                        Text(selectedBrand == .polestar
                             ? L10n.text("Your Polestar sign-in needs renewing. Re-sign in below — no password required.")
                             : L10n.text("Your Volvo sign-in needs renewing. Re-sign in below with the developer keys already saved."))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    case .notConnected:
                        Text(L10n.text("Enter your credentials below to establish a live connection."))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
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
                        .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
            }

            if style != .welcoming && (isBrandConnected || health == .sessionExpired) {
                HStack(spacing: 6) {
                    reSignInButton(prominent: health == .sessionExpired)

                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            showUpdateFields.toggle()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: showUpdateFields ? "chevron.up" : "pencil")
                            Text(showUpdateFields ? L10n.text("Done") : L10n.text("Edit Credentials"))
                        }
                        .font(.system(size: 10, weight: .medium))
                    }
                    .controlSize(.mini)

                    if isBrandConnected {
                        Button {
                            testCurrentConnection()
                        } label: {
                            Text(L10n.text("Test"))
                                .font(.system(size: 10, weight: .medium))
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
                        .foregroundStyle(test.success ? .green : .red)
                        .font(.system(size: 10))
                    Text(test.message)
                        .font(.system(size: 10))
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
    }

    @ViewBuilder
    private func reSignInButton(prominent: Bool) -> some View {
        let label = HStack(spacing: 3) {
            Image(systemName: "arrow.clockwise.circle")
            Text(L10n.text("Re-sign In"))
        }
        .font(.system(size: 10, weight: .semibold))

        if prominent {
            Button { onSettingsChanged(.reauthenticate(selectedBrand)) } label: { label }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.mini)
        } else {
            Button { onSettingsChanged(.reauthenticate(selectedBrand)) } label: { label }
                .buttonStyle(.bordered)
                .controlSize(.mini)
        }
    }

    private var polestarFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            if style == .welcoming {
                Text(L10n.text("Sign in with your Polestar ID email and password."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            labeledField(L10n.text("Polestar ID (Email)")) {
                TextField("name@example.com", text: $polestarEmail)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .onChange(of: polestarEmail) { _, value in preferences.accountDraft.polestarEmail = value }
            }
            if attemptedPolestarSignIn && !isValidEmail(polestarEmail) {
                validationMessage(L10n.text("Enter a valid email address."))
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
            if attemptedPolestarSignIn && !isValidOptionalVIN(polestarVIN) {
                validationMessage(L10n.text("A VIN must contain 17 valid letters or digits."))
            }

            if showPolestarInteractiveFallback || testConnectionResult?.message.contains("additional or changed sign-in step") == true {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "globe")
                            .font(.system(size: 11))
                            .foregroundStyle(HisingenTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("Interactive Verification Required"))
                                .font(.system(size: 11, weight: .semibold))
                            Text(L10n.text("Polestar presented a verification challenge (2FA, CAPTCHA, or Terms update). Complete sign-in in the interactive window."))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
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
                attemptedPolestarSignIn = true
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
                .transition(.scale(scale: 0.85).combined(with: .opacity))
                .id(showSavedFeedback)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!isValidEmail(polestarEmail) || !isValidOptionalVIN(polestarVIN))
            .padding(.top, style == .welcoming ? 6 : 4)
        }
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
                        .foregroundStyle(.green)
                        .font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.text("Developer Access Ready"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(L10n.text("Default developer application credentials configured."))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        showCustomVolvoApp = true
                    } label: {
                        Text(L10n.text("Custom App"))
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(HisingenTheme.accent)
                }
                .padding(8)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            } else {
                Text(L10n.text(
                    "Register a free API application at developer.volvocars.com to get a Client ID, "
                    + "Client Secret, and VCC API Key, then sign in with your Volvo ID below. "
                    + "Hisingen never sees your Volvo ID password directly — sign-in happens in a "
                    + "system browser window."
                ))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
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
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
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
                validationMessage(L10n.text("A VIN must contain 17 valid letters or digits."))
            }

            Button {
                attemptedVolvoSignIn = true
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
        isTestingConnection = true
        testConnectionResult = nil
        let brand = selectedBrand
        Task {
            let result = await onTestConnection(brand)
            guard brand == selectedBrand else { return } // user switched brands mid-check
            isTestingConnection = false
            testConnectionResult = (result.success, result.message)
            if brand == .polestar && (result.message.contains("additional or changed sign-in step") || result.message.contains("Settings and try again")) {
                showPolestarInteractiveFallback = true
            }
        }
    }

    private func savePolestarCredentials() {
        guard isValidEmail(polestarEmail), isValidOptionalVIN(polestarVIN) else { return }
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
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7)) {
            showSavedFeedback = !keychainFailed
            if keychainFailed {
                testConnectionResult = (false, L10n.text("Couldn't save the password to the Keychain. Please try again."))
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                showSavedFeedback = false
            }
        }
        guard !keychainFailed else { return }
        // Persist identity only after a new password has reached Keychain successfully. A
        // Keychain denial must not leave an email/VIN pointing at credentials that were not
        // actually saved.
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

    private func validationMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.red)
            .accessibilityLabel(message)
    }

    private func labeledField<Content: View>(_ label: String, @ViewBuilder field: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            field()
        }
    }
}
