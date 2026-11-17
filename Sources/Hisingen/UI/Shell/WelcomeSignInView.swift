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
                        .padding(.horizontal, HisingenTheme.cardPadding)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
                // The form sits on the canvas. It was wrapped in a section that drew nothing
                // but an Increase Contrast outline, one more box around a form that is already
                // ruled.
                AccountCredentialsForm(style: .welcoming, onSettingsChanged: onSettingsChanged,
                                        onTestConnection: onTestConnection,
                                        model: accountConnection)
                    .padding(.horizontal, HisingenTheme.cardPadding)
            }
            .padding(.vertical, HisingenTheme.sectionSpacing)
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
        Text(message)
            .hisType(.label)
            .foregroundStyle(HisingenTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .padding(.leading, 2)
            .hisNotice(HisingenTheme.semanticWarning)
            .accessibilityElement(children: .combine)
    }
}
