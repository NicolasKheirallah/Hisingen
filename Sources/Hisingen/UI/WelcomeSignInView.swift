import SwiftUI


@MainActor
struct WelcomeSignInView: View {
    let error: String?
    let onSettingsChanged: (SettingsChange) -> Void
    var onTestConnection: (VehicleBrand) async -> (success: Bool, message: String) = { _ in
        (false, L10n.text("Connection testing is not available."))
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 18) {
                header
                if let error, !error.isEmpty {
                    errorBanner(error)
                }
                Card {
                    AccountCredentialsForm(style: .welcoming, onSettingsChanged: onSettingsChanged,
                                            onTestConnection: onTestConnection)
                }
            }
            .padding(HisingenTheme.sectionSpacing)
        }
        .frame(width: HisingenTheme.layoutWidth)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 52, height: 52)
                .padding(.top, 8)
            Text(L10n.text("Welcome to Hisingen"))
                .font(.system(size: 17, weight: HisingenTheme.headingWeight))
                .tracking(HisingenTheme.displayTracking * 0.3)
                .foregroundStyle(HisingenTheme.ink)
            Text(L10n.text("Monitor your Polestar or Volvo from the menu bar — pick your vehicle's brand and sign in below."))
                .font(.system(size: 12))
                .foregroundStyle(HisingenTheme.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(HisingenTheme.semanticWarning)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(HisingenTheme.semanticWarning.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}


