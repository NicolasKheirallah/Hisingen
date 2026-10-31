import SwiftUI

/// The account card's credential form. The shell lives here (brand choice, status banner,
/// test flow); the Polestar and Volvo sections live in `AccountCredentialsForm+Polestar.swift`
/// and `AccountCredentialsForm+Volvo.swift`. Each section is an extension of this struct so
/// all of them share one set of `@State`.
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

    @State var selectedBrand = VehicleBrand.polestar
    @Environment(\.preferencesStore) var preferences
    /// The Polestar sign-in options the reader has enabled. Seeded from the stored mode on appear.
    @State var credentialSelection = AccountConnectionModel.PolestarCredentialSelection(mode: .polestarID)

    @State var showCustomVolvoApp = false
    @State var showSavedFeedback = false
    @State var isTestingConnection = false
    @State var testConnectionResult: ConnectionCheck?
    /// Local Keychain-save failures, kept separate from `testConnectionResult` so the
    /// banner's sessionExpired suppression can never hide them.
    @State var keychainError: String?
    @State private var showUpdateFields = false
    /// Non-nil when the check (or the session state itself) says the interactive sign-in
    /// window is the way back in. The card copy adapts to which failure it represents.
    @State var polestarFallbackKind: SignInFailureKind?
    @State var attemptedPolestarSignIn = false
    @State var attemptedVolvoSignIn = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion

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
    var inheritedPolestarFallbackKind: SignInFailureKind? {
        guard selectedBrand == .polestar, connectionHealth == .sessionExpired else { return nil }
        return .sessionExpired
    }

    func fallbackCopy(for kind: SignInFailureKind) -> String {
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
            credentialSelection = AccountConnectionModel.PolestarCredentialSelection(
                mode: preferences.polestarConnectionMode
            )
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

    var isPolestarIDSignedIn: Bool {
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

    func labeledField<Content: View>(_ label: String, @ViewBuilder field: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .hisType(.label, weight: .medium)
                .foregroundStyle(.secondary)
            field()
        }
    }

    func testCurrentConnection() {
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
                if let kind = AccountConnectionModel.interactiveFallbackKind(for: result, brand: brand) {
                    polestarFallbackKind = kind
                }
            }
        }
    }
}
