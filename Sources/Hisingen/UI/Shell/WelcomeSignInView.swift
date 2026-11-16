import SwiftUI


@MainActor
struct WelcomeSignInView: View {
    let error: String?
    let onSettingsChanged: (SettingsChange) -> Void
    let accountConnection: AccountConnectionModel
    var onTestConnection: (VehicleBrand) async -> ConnectionCheck = { _ in
        ConnectionCheck(success: false, message: L10n.text("Connection testing is not available."), failureKind: nil)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let error, !error.isEmpty {
                    errorBanner(error)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
                Card {
                    AccountCredentialsForm(style: .welcoming, onSettingsChanged: onSettingsChanged,
                                            onTestConnection: onTestConnection,
                                            model: accountConnection)
                }
            }
            .padding(HisingenTheme.sectionSpacing)
            .hisAnimation(Motion.stateChange, value: error)
        }
        .frame(width: HisingenTheme.layoutWidth)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.text("Hisingen"))
                .hisType(.displayLarge)
                .foregroundStyle(HisingenTheme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(L10n.text("Monitor your Polestar or Volvo from the menu bar. Pick your vehicle's brand and sign in below."))
                .hisType(.body)
                .foregroundStyle(HisingenTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            PanelRule()
                .padding(.top, 7)
        }
        .padding(.horizontal, HisingenTheme.cardPadding)
        .padding(.top, 24)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .hisType(.body)
                .foregroundStyle(HisingenTheme.semanticWarning)
            Text(message)
                .hisType(.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(HisingenTheme.semanticWarning.opacity(0.1), in: RoundedRectangle(cornerRadius: 0, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
