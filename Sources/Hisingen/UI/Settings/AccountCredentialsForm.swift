import SwiftUI

@MainActor
struct AccountCredentialsForm: View {
    enum Style {
        case compact
        case welcoming
    }

    let style: Style
    let onSettingsChanged: (SettingsChange) -> Void
    var onTestConnection: (VehicleBrand) async -> ConnectionCheck = { _ in
        ConnectionCheck(success: false, message: L10n.text("Connection testing is not available."), failureKind: nil)
    }
    @ObservedObject var model: AccountConnectionModel

    @State private var selectedBrand = VehicleBrand.polestar
    @Environment(\.preferencesStore) private var preferences
    @State private var enablePolestarID = true
    @State private var enableDataPortal = false

    private var polestarConnectionMode: PreferencesStore.PolestarConnectionMode {
        if enablePolestarID && enableDataPortal {
            return .augmented
        } else if enableDataPortal {
            return .dataPortal
        } else {
            return .polestarID
        }
    }

    @State private var showCustomVolvoApp = false
    @State private var showSavedFeedback = false
    @State private var isTestingConnection = false
    @State private var testConnectionResult: ConnectionCheck?
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

    private var connectionHealth: ConnectionHealth {
        switch model.health(for: selectedBrand, isActiveBrand: isActiveBrand, lastCheck: testConnectionResult) {
        case .active: return .active
        case .connectedInactive: return .connectedInactive
        case .sessionExpired: return .sessionExpired
        case .notConnected: return .notConnected
        }
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
            return "Your Polestar session expired. Sign in again. The interactive window handles any new verification step Polestar added."
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
            switch preferences.polestarConnectionMode {
            case .polestarID:
                enablePolestarID = true
                enableDataPortal = false
            case .dataPortal:
                enablePolestarID = false
                enableDataPortal = true
            case .augmented:
                enablePolestarID = true
                enableDataPortal = true
            }
            model.seedDraftFromStore()
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
        let radius = HisingenTheme.bannerRadius
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
                    .hisSymbolSize(20)
                    .foregroundStyle(isSelected ? HisingenTheme.accent : HisingenTheme.inkMuted)
                Text(brand.displayName)
                    .hisType(.body, weight: isSelected ? .semibold : .medium)
                    .foregroundStyle(isSelected ? HisingenTheme.ink : HisingenTheme.inkMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                isSelected ? HisingenTheme.accent.opacity(0.12) : Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
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
                        Text(activeAccountSubtitle(activeLabel: activeLabel))
                            .hisType(.caption).foregroundStyle(.secondary)
                    case .sessionExpired:
                        Text(selectedBrand == .polestar
                             ? L10n.text("Your Polestar sign-in needs renewing. Re-sign in below, no password required.")
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

                if model.isConnected(selectedBrand) && !isActiveBrand && health != .sessionExpired {
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

            if style != .welcoming && (model.isConnected(selectedBrand) || health == .sessionExpired) {
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

                    if model.isConnected(selectedBrand) {
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

    private struct CredentialOption {
        let title: String
        let subtitle: String
        let symbol: String
        let isSelected: Bool
    }

    private var polestarFields: some View {
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
            if polestarID {
                enablePolestarID.toggle()
                if !enablePolestarID && !enableDataPortal {
                    enableDataPortal = true
                }
            } else {
                enableDataPortal.toggle()
                if !enablePolestarID && !enableDataPortal {
                    enablePolestarID = true
                }
            }
            preferences.polestarConnectionMode = polestarConnectionMode
        }
        if preferences.hasResumableSession(for: .polestar) {
            onSettingsChanged(.credentials)
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

    private var isPolestarIDSignedIn: Bool {
        preferences.hasSessionToken(for: .polestar)
    }

    private func activeAccountSubtitle(activeLabel: String) -> String {
        if selectedBrand == .polestar, preferences.polestarConnectionMode == .augmented {
            if !isPolestarIDSignedIn {
                return L10n.format("Vehicle: %@ · Developer Portal active (Polestar ID needs sign-in)", activeLabel)
            }
            return L10n.format("Vehicle: %@ · Polestar ID & Developer Portal active", activeLabel)
        }
        return L10n.format("Vehicle: %@", activeLabel)
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
        guard let outcome = model.savePolestar(mode: polestarConnectionMode) else { return }
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

    private func beginVolvoSignIn() {
        guard let request = model.beginVolvoSignIn() else { return }
        onSettingsChanged(.volvoSignIn(
            clientID: request.clientID,
            clientSecret: request.clientSecret,
            vccApiKey: request.vccApiKey,
            nickname: request.nickname
        ))
    }

    private func triggerSavedFeedbackReset() {
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(reduceMotion ? nil : Motion.theme) {
                showSavedFeedback = false
            }
        }
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
