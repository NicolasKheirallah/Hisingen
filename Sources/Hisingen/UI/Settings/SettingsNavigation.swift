import SwiftUI

enum SettingsValidation {
    static func isValidEmail(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !trimmed.contains(" ")
    }

    static func isValidOptionalVIN(_ value: String) -> Bool {
        let vin = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !vin.isEmpty else { return true }
        guard vin.count == 17 else { return false }
        return vin.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            && !vin.contains(where: { "IOQ".contains($0) })
    }

    static func isValidElectricityPrice(_ text: String) -> Bool {
        guard let value = NumberParsing.decimal(from: text) else { return false }
        return (0.01...1_000).contains(value)
    }

    static func isValidCurrencySymbol(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...8).contains(value.count) && !value.contains(where: \.isNewline)
    }
}

/// Stable, testable settings destinations. Search is intentionally section based: it
/// keeps every control in its explanatory card instead of returning orphaned toggles.
enum SettingsSection: String, CaseIterable, Identifiable {
    case all, accounts, appearance, general, features, notifications, privacyData, updates, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L10n.text("All")
        case .accounts: return L10n.text("Accounts")
        case .appearance: return L10n.text("Appearance")
        case .general: return L10n.text("General")
        case .features: return L10n.text("Features")
        case .notifications: return L10n.text("Notifications")
        case .privacyData: return L10n.text("Privacy & Data")
        case .updates: return L10n.text("Updates")
        case .about: return L10n.text("About")
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .accounts: return "person.crop.circle"
        case .appearance: return "paintpalette"
        case .general: return "gearshape"
        case .features: return "switch.2"
        case .notifications: return "bell"
        case .privacyData: return "hand.raised"
        case .updates: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        }
    }

    private var searchTerms: String {
        switch self {
        case .all: return ""
        case .accounts: return "account login sign in polestar volvo credentials vehicle vin garage fleet"
        case .appearance: return "appearance theme color dark light screenshot privacy floating panel car image"
        case .general: return "general display menu bar panel size density units language launch charging order"
        case .features: return "feature capability vehicle data remote control lock climate charge schedule location weather"
        case .notifications: return "notification alert sound quiet hours warning battery rain unlocked reminder"
        case .privacyData: return "privacy data database storage history retention export backup diagnostics location"
        case .updates: return "update automatic download version channel release"
        case .about: return "about help diagnostics quit sign out version reset"
        }
    }

    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return needle.isEmpty || title.lowercased().contains(needle) || searchTerms.contains(needle)
    }
}

struct SettingsNavigationBar: View {
    @Binding var selection: SettingsSection
    @Binding var searchText: String

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        selection = section
                    } label: {
                        Label(section.title, systemImage: section.symbol)
                            .font(.system(size: 10, weight: selection == section ? .semibold : .regular))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selection == section ? HisingenTheme.accent : .secondary)
                    .background(
                        selection == section ? HisingenTheme.accent.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
                }
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.text("Search settings"), text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(L10n.text("Search settings"))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("Clear Search"))
                    .accessibilityLabel(L10n.text("Clear Search"))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

enum CapabilityFilter: String, CaseIterable, Identifiable {
    case all, supported, automatic, unavailable, serviceDependent
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L10n.text("All capabilities")
        case .supported: return L10n.text("Supported")
        case .automatic: return L10n.text("Automatic")
        case .unavailable: return L10n.text("Not available")
        case .serviceDependent: return L10n.text("Service dependent")
        }
    }

    func matches(_ support: VehicleCapabilitySupport) -> Bool {
        switch self {
        case .all: return true
        case .supported: return support == .supported
        case .automatic: return support == .vehicleManaged
        case .unavailable: return support == .unavailable
        case .serviceDependent: return support == .backendDependent
        }
    }
}
