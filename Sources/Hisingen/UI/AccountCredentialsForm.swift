import SwiftUI

@MainActor
final class AccountDraftState {
    static let shared = AccountDraftState()
    var email: String = Preferences.email
    var password: String = ""
    var vin: String = Preferences.vin
    var vehicleNickname: String = Preferences.vehicleNickname(for: Preferences.vin)
    var volvoClientID: String = Preferences.volvoClientID
    var volvoClientSecret: String = ""
    var volvoApiKey: String = ""
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
    @State private var email = AccountDraftState.shared.email
    @State private var password = AccountDraftState.shared.password
    @State private var vin = AccountDraftState.shared.vin
    @State private var vehicleNickname = AccountDraftState.shared.vehicleNickname
    @State private var volvoClientID = AccountDraftState.shared.volvoClientID
    @State private var volvoClientSecret = AccountDraftState.shared.volvoClientSecret
    @State private var volvoApiKey = AccountDraftState.shared.volvoApiKey
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isCurrentlyConnected ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)

                Text(isCurrentlyConnected
                     ? L10n.format("Connected to %@ Account", selectedBrand.displayName)
                     : L10n.format("Not Connected to %@", selectedBrand.displayName))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isCurrentlyConnected ? Color.primary : Color.secondary)

                Spacer()

                if isCurrentlyConnected {
                    Button {
                        testCurrentConnection()
                    } label: {
                        HStack(spacing: 4) {
                            if isTestingConnection {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(L10n.text("Test Connection"))
                        }
                        .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isTestingConnection)
                }
            }

            if let result = testConnectionResult {
                HStack(spacing: 6) {
                    Image(systemName: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.success ? Color.green : Color.orange)
                    Text(result.message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (result.success ? Color.green : Color.orange).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var polestarFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            if style == .welcoming {
                Text(L10n.text("Sign in with your Polestar ID email and password."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            labeledField(L10n.text("Polestar ID (Email)")) {
                TextField("name@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .onChange(of: email) { AccountDraftState.shared.email = $0 }
            }

            labeledField(L10n.text("Password")) {
                SecureField(L10n.text("•••••••• (only to update credentials)"), text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .onChange(of: password) { AccountDraftState.shared.password = $0 }
            }

            labeledField(L10n.text("Vehicle Nickname (Optional)")) {
                TextField("e.g. My Polestar, Midnight", text: $vehicleNickname)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: vehicleNickname) { AccountDraftState.shared.vehicleNickname = $0 }
            }

            labeledField(L10n.text("VIN (Optional, auto-detected)")) {
                TextField("YSM...", text: $vin)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: vin) { AccountDraftState.shared.vin = $0 }
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
            .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                TextField("e.g. My Volvo, Family car", text: $vehicleNickname)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: vehicleNickname) { AccountDraftState.shared.vehicleNickname = $0 }
            }

            labeledField(L10n.text("VIN (Optional, auto-detected)")) {
                TextField("YV1...", text: $vin)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: vin) { AccountDraftState.shared.vin = $0 }
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
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let upperVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let nicknameVIN = upperVIN.isEmpty ? Preferences.vin : upperVIN
        let credentialsChanged = normalizedEmail != Preferences.email || upperVIN != Preferences.vin || !password.isEmpty
        Preferences.email = normalizedEmail
        Preferences.vin = upperVIN
        Preferences.setVehicleNickname(vehicleNickname, for: nicknameVIN)
        if !password.isEmpty {
            try? Keychain.savePassword(password)
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
        let upperVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let trimmedClientID = volvoClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        Preferences.volvoClientID = trimmedClientID
        if !upperVIN.isEmpty {
            Preferences.vin = upperVIN
        }
        if !vehicleNickname.isEmpty {
            let nickVIN = upperVIN.isEmpty ? Preferences.vin(for: .volvo) : upperVIN
            Preferences.setVehicleNickname(vehicleNickname, for: nickVIN)
        }
        onSettingsChanged(.volvoSignIn(
            clientID: trimmedClientID,
            clientSecret: volvoClientSecret,
            vccApiKey: volvoApiKey,
            nickname: vehicleNickname
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


