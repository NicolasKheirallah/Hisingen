import SwiftUI

/// Stable, testable settings destinations. Search is intentionally section based: it
/// keeps every control in its explanatory card instead of returning orphaned toggles.
enum SettingsSection: String, CaseIterable, Identifiable {
    case all, accounts, appearance, tabsAndCards, general, electricity, features, notifications, privacyData, updates, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L10n.text("All")
        case .accounts: return L10n.text("Accounts")
        case .appearance: return L10n.text("Appearance")
        case .tabsAndCards: return L10n.text("Tabs & Cards")
        case .general: return L10n.text("General")
        case .electricity: return L10n.text("Electricity")
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
        case .tabsAndCards: return "rectangle.3.group"
        case .general: return "gearshape"
        case .electricity: return "bolt.circle"
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
        case .accounts: return "account login sign in polestar volvo credentials vehicle vin garage fleet authorize authorization remote commands"
        case .appearance: return "appearance theme color dark light screenshot privacy floating panel car image battery and range estimated range position relative to car first reading"
        case .tabsAndCards: return "tab tabs card cards dashboard layout sections order reorder hide show customize custom widgets panels log observed changes rows per page"
        case .general: return "general display menu bar panel size density units language launch charging order"
        case .electricity: return "electricity rate price tariff cost kwh country sweden spot price elspot zone provider contract markup vat tax grid fee night charging planner elpris home assistant nexblue easee zaptec tibber access token charger wallbox"
        case .features: return "feature capability vehicle data remote control remote commands lock climate charge schedule location weather authorize authorization"
        case .notifications: return "notification alert sound quiet hours warning battery rain unlocked reminder"
        case .privacyData: return "privacy data database storage history retention export backup diagnostics location"
        case .updates: return "update automatic frequency interval download version channel release"
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

    /// The panel's tab bar animates one indicator between destinations; the section row draws
    /// the same mark from its own namespace, so the two rows speak one navigation language.
    @Namespace private var sectionIndicatorNamespace

    var body: some View {
        VStack(spacing: 8) {
            // Ten sections in one row, in a panel that can be 350pt wide: after padding and gaps
            // each tab had 31 to 59pt while "Notifications" needs about 75pt, so `.lineLimit(1)`
            // truncated every multi-word section at every panel size. The row scrolls now and the
            // labels keep their natural width, which is the one control a reader needs in order to
            // reach the others.
            //
            // Styled to match the panel's tab bar — icon and label, ink on the current section,
            // the shared indicator under it — because this row is the same kind of control, one
            // level down, and the accent-filled pill it used to wear was a second grammar.
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(SettingsSection.allCases) { section in
                            Button {
                                selection = section
                            } label: {
                                Text(section.title)
                                    .hisType(.body)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                .foregroundStyle(selection == section ? HisingenTheme.ink : HisingenTheme.inkMuted)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                                .overlay(alignment: .bottom) {
                                    if selection == section { sectionIndicator.padding(.bottom, 3) }
                                }
                            }
                            .buttonStyle(.pressable)
                            .focusEffectDisabled()
                            .help(section.title)
                            .accessibilityAddTraits(selection == section ? .isSelected : [])
                            .id(section)
                        }
                    }
                    .padding(.horizontal, 1)
                }
                // The indicator travels between sections instead of snapping.
                .hisAnimation(Motion.selection, value: selection)
                // A row that scrolls can hide the section the reader is in, so it comes back into
                // view whenever the selection changes from anywhere: this row, search, or a link.
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
                .onChange(of: selection) { _, section in
                    withAnimation(Motion.resolve(Motion.selection)) {
                        proxy.scrollTo(section, anchor: .center)
                    }
                }
            }

            SettingsSearchField(text: $searchText)
        }
    }

    /// The indicator the panel's tab bar draws, so a reader learns one mark for "you are here".
    private var sectionIndicator: some View {
        PanelDatum(color: HisingenTheme.accent)
            .matchedGeometryEffect(id: "settingsSectionIndicator", in: sectionIndicatorNamespace)
    }
}

struct SettingsSidebar: View {
    @Binding var selection: SettingsSection
    @Binding var searchText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("Settings"))
                    .hisType(.display)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.text("Changes save automatically"))
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.inkMuted)
            }

            SettingsSearchField(text: $searchText)

            ScrollView(.vertical) {
                VStack(spacing: 3) {
                    ForEach(SettingsSection.allCases) { section in
                        if searchText.isEmpty || section == .all || section.matches(searchText) {
                            Button { selection = section } label: {
                                HStack(spacing: 0) {
                                    Text(section.title)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .hisType(.subhead)
                                .foregroundStyle(selection == section ? HisingenTheme.ink : HisingenTheme.inkMuted)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .frame(minHeight: 34)
                                // The panel's place mark, turned on its side for a vertical list.
                                .overlay(alignment: .leading) {
                                    if selection == section {
                                        Rectangle().fill(HisingenTheme.ink).frame(width: 2)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.pressable)
                            .focusEffectDisabled()
                            .accessibilityAddTraits(selection == section ? .isSelected : [])
                        }
                    }
                }
            }
        }
        .padding(22)
    }
}

private struct SettingsSearchField: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Binding var text: String

    private var increasedContrast: Bool { contrast == .increased }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(HisingenTheme.inkMuted)
                .accessibilityHidden(true)
            TextField(L10n.text("Search settings"), text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel(L10n.text("Search settings"))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(HisingenTheme.inkMuted)
                }
                .buttonStyle(.pressable)
                .help(L10n.text("Clear Search"))
                .accessibilityLabel(L10n.text("Clear Search"))
            }
        }
        .hisType(.body)
        .padding(.horizontal, 2)
        .frame(minHeight: 34)
        // polestar.com's input: no box, a 1pt rule underneath.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(increasedContrast ? HisingenTheme.cardBoundaryIncreased : HisingenTheme.inkMuted)
                .frame(height: 1)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
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
