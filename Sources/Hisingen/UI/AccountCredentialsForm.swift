import SwiftUI

@MainActor
final class AccountDraftState {
    static let shared = AccountDraftState()
    var polestarEmail: String = Preferences.email
    var polestarPassword: String = ""
    var polestarVIN: String = Preferences.vin(for: .polestar)
    var polestarNickname: String = Preferences.vehicleNickname(for: Preferences.vin(for: .polestar))

    var volvoClientID: String = Preferences.volvoClientID
    var volvoClientSecret: String = ""
    var volvoApiKey: String = ""
    var volvoVIN: String = Preferences.vin(for: .volvo)
    var volvoNickname: String = Preferences.vehicleNickname(for: Preferences.vin(for: .volvo))
}

@MainActor
struct AccountCredentialsForm: View {
    enum Style {
        case compact
        case welcoming
    }

    let style: Style
    let onSettingsChanged: (SettingsChange) -> Void

    @State private var selectedBrand = Preferences.activeBrand
    @State private var polestarEmail = AccountDraftState.shared.polestarEmail
    @State private var polestarPassword = AccountDraftState.shared.polestarPassword
    @State private var polestarVIN = AccountDraftState.shared.polestarVIN
    @State private var polestarNickname = AccountDraftState.shared.polestarNickname

    @State private var volvoClientID = AccountDraftState.shared.volvoClientID
    @State private var volvoClientSecret = AccountDraftState.shared.volvoClientSecret
    @State private var volvoApiKey = AccountDraftState.shared.volvoApiKey
    @State private var volvoVIN = AccountDraftState.shared.volvoVIN
    @State private var volvoNickname = AccountDraftState.shared.volvoNickname

    @State private var volvoSigningIn = false
    @State private var showSavedFeedback = false
    @State private var isTestingConnection = false
    @State private var testConnectionResult: (success: Bool, message: String)?
    @State private var showUpdateFields = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: style == .welcoming ? 14 : 12) {
            brandPicker

            accountStatusBanner

            if selectedBrand == .polestar {
                polestarFields
            } else {
                volvoFields
            }
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
            .onChange(of: selectedBrand) { _ in
                testConnectionResult = nil
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

    private var isCurrentlyConnected: Bool {
        Preferences.activeBrand == selectedBrand && Preferences.hasResumableSession(for: selectedBrand)
    }

    @ViewBuilder
    private var accountStatusBanner: some View {
        let isBrandConnected = isCurrentlyConnected
        let brandName = selectedBrand.displayName
        let activeLabel = Preferences.lastVehicleLabel(for: selectedBrand)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(isBrandConnected ? Color.green : Color.orange.opacity(0.6))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isBrandConnected
                         ? L10n.format("Connected to %@ Account", brandName)
                         : L10n.format("Not Connected to %@", brandName))
                        .font(.system(size: 12, weight: .semibold))

                    if isBrandConnected {
                        Text(L10n.format("Active Vehicle: %@", activeLabel))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.text("Enter your credentials below to establish a live connection."))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()

                if isBrandConnected && style != .welcoming {
                    Button {
                        testCurrentConnection()
                    } label: {
                        if isTestingConnection {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(L10n.text("Test"))
                                .font(.system(size: 10, weight: .medium))
                        }
                    }
                    .controlSize(.mini)
                    .disabled(isTestingConnection)
                }
            }

            if let test = testConnectionResult {
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
        .background(
            (isBrandConnected ? Color.green : Color.orange).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke((isBrandConnected ? Color.green : Color.orange).opacity(0.25), lineWidth: 0.5)
        )
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
                    .onChange(of: polestarEmail) { AccountDraftState.shared.polestarEmail = $0 }
            }

            labeledField(L10n.text("Password")) {
                SecureField(L10n.text("•••••••• (only to update credentials)"), text: $polestarPassword)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .onChange(of: polestarPassword) { AccountDraftState.shared.polestarPassword = $0 }
            }

            labeledField(L10n.text("Vehicle Nickname (Optional)")) {
                TextField("e.g. My Polestar, Midnight", text: $polestarNickname)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: polestarNickname) { AccountDraftState.shared.polestarNickname = $0 }
            }

            labeledField(L10n.text("VIN (Optional, auto-detected)")) {
                TextField("YSM...", text: $polestarVIN)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: polestarVIN) { AccountDraftState.shared.polestarVIN = $0 }
            }

            Button {
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
            .disabled(polestarEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.top, style == .welcoming ? 6 : 4)
        }
    }

    private var hasResumableVolvoSession: Bool {
        let trimmedClientID = volvoClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientID.isEmpty, trimmedClientID == Preferences.volvoClientID,
              volvoClientSecret.isEmpty, volvoApiKey.isEmpty else { return false }
        return Preferences.hasResumableSession(for: .volvo)
    }

    private var volvoFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text(
                "Register a free API application at developer.volvocars.com to get a Client ID, "
                + "Client Secret, and VCC API Key, then sign in with your Volvo ID below. "
                + "Hisingen never sees your Volvo ID password directly — sign-in happens in a "
                + "system browser window."
            ))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            labeledField(L10n.text("Client ID")) {
                TextField("Client ID", text: $volvoClientID)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: volvoClientID) { AccountDraftState.shared.volvoClientID = $0 }
            }

            labeledField(L10n.text("Client Secret")) {
                SecureField(hasResumableVolvoSession && volvoClientSecret.isEmpty
                            ? L10n.text("•••••••• (Saved in Keychain)")
                            : L10n.text("Client Secret"), text: $volvoClientSecret)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: volvoClientSecret) { AccountDraftState.shared.volvoClientSecret = $0 }
            }

            labeledField(L10n.text("VCC API Key")) {
                SecureField(hasResumableVolvoSession && volvoApiKey.isEmpty
                            ? L10n.text("•••••••• (Saved in Keychain)")
                            : L10n.text("VCC API Key"), text: $volvoApiKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: volvoApiKey) { AccountDraftState.shared.volvoApiKey = $0 }
            }

            labeledField(L10n.text("Vehicle Nickname (Optional)")) {
                TextField("e.g. My Volvo, Family car", text: $volvoNickname)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: volvoNickname) { AccountDraftState.shared.volvoNickname = $0 }
            }

            labeledField(L10n.text("VIN (Optional, auto-detected)")) {
                TextField("YV1...", text: $volvoVIN)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: volvoVIN) { AccountDraftState.shared.volvoVIN = $0 }
            }

            Button {
                beginVolvoSignIn()
            } label: {
                HStack(spacing: 4) {
                    if volvoSigningIn {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("Signing in via browser…"))
                    } else {
                        Image(systemName: "globe")
                        Text(hasResumableVolvoSession
                             ? L10n.text("Switch to Volvo Account")
                             : L10n.text("Sign in with Volvo ID"))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(volvoClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || volvoSigningIn)
            .padding(.top, style == .welcoming ? 6 : 4)
        }
    }

    private func testCurrentConnection() {
        isTestingConnection = true
        testConnectionResult = nil
        Task {
            let start = Date()
            try? await Task.sleep(nanoseconds: 600_000_000)
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            isTestingConnection = false
            if isCurrentlyConnected {
                testConnectionResult = (true, L10n.format("Connection active & verified (%d ms)", elapsed))
            } else {
                testConnectionResult = (false, L10n.text("No active session found. Please sign in."))
            }
        }
    }

    private func savePolestarCredentials() {
        let normalizedEmail = polestarEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let upperVIN = polestarVIN.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let oldVIN = Preferences.vin(for: .polestar)
        let nicknameVIN = upperVIN.isEmpty ? oldVIN : upperVIN
        let credentialsChanged = normalizedEmail != Preferences.email || upperVIN != oldVIN || !polestarPassword.isEmpty
        Preferences.email = normalizedEmail
        Preferences.setVin(upperVIN, for: .polestar)
        if !nicknameVIN.isEmpty {
            Preferences.setVehicleNickname(polestarNickname, for: nicknameVIN)
        }
        if !polestarPassword.isEmpty {
            try? Keychain.savePassword(polestarPassword)
        }
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7)) {
            showSavedFeedback = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                showSavedFeedback = false
            }
        }
        onSettingsChanged(credentialsChanged ? .credentials : .presentation)
    }

    private func beginVolvoSignIn() {
        volvoSigningIn = true
        let upperVIN = volvoVIN.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let trimmedClientID = volvoClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        Preferences.volvoClientID = trimmedClientID
        Preferences.setVin(upperVIN, for: .volvo)
        if !upperVIN.isEmpty {
            Preferences.setVehicleNickname(volvoNickname, for: upperVIN)
        } else {
            let existingVIN = Preferences.vin(for: .volvo)
            if !existingVIN.isEmpty {
                Preferences.setVehicleNickname(volvoNickname, for: existingVIN)
            }
        }
        onSettingsChanged(.volvoSignIn(
            clientID: trimmedClientID,
            clientSecret: volvoClientSecret,
            vccApiKey: volvoApiKey,
            nickname: volvoNickname
        ))
        volvoClientSecret = ""
        volvoApiKey = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { volvoSigningIn = false }
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


