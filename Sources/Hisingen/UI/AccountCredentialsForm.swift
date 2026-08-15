import SwiftUI


@MainActor
struct AccountCredentialsForm: View {
    enum Style {


        case compact


        case welcoming
    }

    let style: Style
    let onSettingsChanged: (SettingsChange) -> Void

    @State private var selectedBrand = Preferences.activeBrand
    @State private var email = Preferences.email
    @State private var password = ""
    @State private var vin = Preferences.vin
    @State private var vehicleNickname = Preferences.vehicleNickname(for: Preferences.vin)
    @State private var volvoClientID = Preferences.volvoClientID
    @State private var volvoClientSecret = ""
    @State private var volvoApiKey = ""
    @State private var volvoSigningIn = false
    @State private var showSavedFeedback = false
    @State private var draftSaveTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: style == .welcoming ? 14 : 12) {
            brandPicker

            if selectedBrand == .polestar {
                polestarFields
            } else {
                volvoFields
            }
        }
        .onAppear(perform: restoreDrafts)
        .onDisappear { draftSaveTask?.cancel() }
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
        }
    }

    private func brandCard(_ brand: VehicleBrand) -> some View {
        let isSelected = selectedBrand == brand
        let radius: CGFloat = HisingenTheme.cornerRadius == 0 ? 0 : 10
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                selectedBrand = brand
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
                    .onChange(of: email) { _ in scheduleDraftSave() }
            }

            labeledField(L10n.text("Password")) {
                SecureField(L10n.text("•••••••• (only to update credentials)"), text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .onChange(of: password) { _ in scheduleDraftSave() }
            }

            labeledField(L10n.text("Vehicle Nickname (Optional)")) {
                TextField("e.g. My Polestar, Midnight", text: $vehicleNickname)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: vehicleNickname) { _ in scheduleDraftSave() }
            }

            labeledField(L10n.text("VIN (Optional, auto-detected)")) {
                TextField("YSM...", text: $vin)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: vin) { _ in scheduleDraftSave() }
            }

            Button {
                savePolestarCredentials()
            } label: {
                HStack(spacing: 4) {
                    if showSavedFeedback {
                        Image(systemName: "checkmark")
                        Text(L10n.text("Saved"))
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
        return ((try? Keychain.readVolvoClientSecret()) ?? nil)?.isEmpty == false
            && ((try? Keychain.readVolvoApiKey()) ?? nil)?.isEmpty == false
            && ((try? Keychain.readVolvoSessionToken()) ?? nil)?.isEmpty == false
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
                    .onChange(of: volvoClientID) { _ in scheduleDraftSave() }
            }

            labeledField(L10n.text("Client Secret")) {
                SecureField(L10n.text("•••••••• (only to update credentials)"), text: $volvoClientSecret)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: volvoClientSecret) { _ in scheduleDraftSave() }
            }

            labeledField(L10n.text("VCC API Key")) {
                SecureField(L10n.text("•••••••• (only to update credentials)"), text: $volvoApiKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: volvoApiKey) { _ in scheduleDraftSave() }
            }

            labeledField(L10n.text("Vehicle Nickname (Optional)")) {
                TextField("e.g. My Volvo, Family car", text: $vehicleNickname)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: vehicleNickname) { _ in scheduleDraftSave() }
            }

            Button {
                beginVolvoSignIn()
            } label: {
                HStack(spacing: 4) {
                    if volvoSigningIn {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "globe")
                    }
                    Text(hasResumableVolvoSession
                         ? L10n.text("Switch to Volvo Account")
                         : L10n.text("Sign in with Volvo ID"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(volvoClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || volvoSigningIn)
            .padding(.top, style == .welcoming ? 6 : 4)
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
        try? Keychain.deletePasswordDraft()
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
        onSettingsChanged(.volvoSignIn(
            clientID: volvoClientID.trimmingCharacters(in: .whitespacesAndNewlines),
            clientSecret: volvoClientSecret,
            vccApiKey: volvoApiKey,
            nickname: vehicleNickname
        ))
        volvoClientSecret = ""
        volvoApiKey = ""
        try? Keychain.deleteVolvoClientSecretDraft()
        try? Keychain.deleteVolvoApiKeyDraft()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { volvoSigningIn = false }
    }


    private func restoreDrafts() {
        if password.isEmpty, let draft = (try? Keychain.readPasswordDraft()) ?? nil, !draft.isEmpty {
            password = draft
        }
        if volvoClientSecret.isEmpty, let draft = (try? Keychain.readVolvoClientSecretDraft()) ?? nil, !draft.isEmpty {
            volvoClientSecret = draft
        }
        if volvoApiKey.isEmpty, let draft = (try? Keychain.readVolvoApiKeyDraft()) ?? nil, !draft.isEmpty {
            volvoApiKey = draft
        }
    }

    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            persistDrafts()
        }
    }

    private func persistDrafts() {


        switch selectedBrand {
        case .polestar:
            Preferences.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
            let upperVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            Preferences.vin = upperVIN
            let nicknameVIN = upperVIN.isEmpty ? Preferences.vin : upperVIN
            if !nicknameVIN.isEmpty {
                Preferences.setVehicleNickname(vehicleNickname, for: nicknameVIN)
            }
            if !password.isEmpty { try? Keychain.savePasswordDraft(password) }
        case .volvo:
            Preferences.volvoClientID = volvoClientID.trimmingCharacters(in: .whitespacesAndNewlines)
            let nicknameVIN = Preferences.activeBrand == .volvo ? Preferences.vin : ""
            if !nicknameVIN.isEmpty {
                Preferences.setVehicleNickname(vehicleNickname, for: nicknameVIN)
            }
            if !volvoClientSecret.isEmpty { try? Keychain.saveVolvoClientSecretDraft(volvoClientSecret) }
            if !volvoApiKey.isEmpty { try? Keychain.saveVolvoApiKeyDraft(volvoApiKey) }
        }
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


