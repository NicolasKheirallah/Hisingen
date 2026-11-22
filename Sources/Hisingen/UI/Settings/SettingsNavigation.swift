import SwiftUI

/// Stable settings sidebar sections and search destinations.
enum SettingsSection: String, CaseIterable, Identifiable {
    case all, accounts, appearance, tabsAndCards, general, electricity, features, notifications, privacyData, updates

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
        }
    }

    func matches(_ query: String) -> Bool {
        let terms = SettingsDestination.searchTerms(query)
        if terms.isEmpty { return true }
        let sectionTitle = SettingsDestination.searchTerms(title)
        if terms.allSatisfy({ term in sectionTitle.contains(where: { $0.hasPrefix(term) }) }) { return true }
        return SettingsDestination.allCases.contains { $0.section == self && $0.matches(query) }
    }
}

enum SettingsDestination: String, CaseIterable, Identifiable {
    case account, remoteAuthorization, garage, vehicleReferences
    case appearance, vehicleAppearance, menuBar, panel, general
    case electricity, gridTariff, plannerSettings, homeCharging, electricitySupplier, houseMeter
    case tabLayout, nowControls, chargingLayout
    case vehicleData, remoteFeatures, vehicleCapabilities, automation
    case notifications, plannerAlerts
    case privacy, localData, backup
    case updates

    var id: String { rawValue }

    var section: SettingsSection {
        switch self {
        case .account, .remoteAuthorization, .garage, .vehicleReferences: .accounts
        case .appearance, .vehicleAppearance, .menuBar, .panel: .appearance
        case .general: .general
        case .electricity, .plannerSettings, .homeCharging, .electricitySupplier, .gridTariff, .houseMeter: .electricity
        case .tabLayout, .nowControls, .chargingLayout: .tabsAndCards
        case .vehicleData, .remoteFeatures, .vehicleCapabilities, .automation: .features
        case .notifications, .plannerAlerts: .notifications
        case .privacy, .localData, .backup: .privacyData
        case .updates: .updates
        }
    }

    var title: String {
        switch self {
        case .account: L10n.text("Account")
        case .remoteAuthorization: L10n.text("Remote Command Permissions")
        case .garage: L10n.text("Garage & Fleet")
        case .vehicleReferences: L10n.text("Vehicle References")
        case .appearance: L10n.text("Appearance & Themes")
        case .vehicleAppearance: L10n.text("Vehicle Presentation")
        case .menuBar: L10n.text("Menu Bar")
        case .panel: L10n.text("Panel")
        case .general: L10n.text("Language & Units")
        case .electricity: L10n.text("Electricity Rate")
        case .plannerSettings: L10n.text("Charging Planner")
        case .homeCharging: L10n.text("Home Charging")
        case .electricitySupplier: L10n.text("Electricity Supplier")
        case .gridTariff: L10n.text("Grid Tariff")
        case .houseMeter: L10n.text("House Meter")
        case .tabLayout: L10n.text("Tabs & Cards")
        case .nowControls: L10n.text("Controls on Now")
        case .chargingLayout: L10n.text("Charging Stat Order")
        case .vehicleData: L10n.text("Vehicle Data")
        case .remoteFeatures: L10n.text("Remote Controls")
        case .vehicleCapabilities: L10n.text("Vehicle Capability Matrix")
        case .automation: L10n.text("Automations")
        case .notifications: L10n.text("Notifications")
        case .plannerAlerts: L10n.text("Charging Planner Alerts")
        case .privacy: L10n.text("Privacy")
        case .localData: L10n.text("SQLite Storage & Data")
        case .backup: L10n.text("Settings Backup")
        case .updates: L10n.text("Hisingen Updates")
        }
    }

    private var aliases: String {
        switch self {
        case .account: "login sign in sign out polestar volvo credentials VIN test connection"
        case .remoteAuthorization: "remote command authorize authorization commands polestar volvo restricted scopes approved permissions reauthenticate"
        case .garage: "fleet nickname rename vehicle switch active vehicle theme per vehicle reorder"
        case .vehicleReferences: "warranty service date delivery usable battery capacity wltp override kilometrage"
        case .appearance: "theme color dark light mode create theme default"
        case .vehicleAppearance: "image vehicle perspective battery range model badge license plate display name first reading"
        case .menuBar: "menu bar tint status icon style display"
        case .panel: "floating charging panel window size density auto close"
        case .general: "general language time format clock am pm 24h 12h distance units temperature pressure fuel consumption launch login"
        case .electricity: "rate price zone tariff country market spot elspot elpris contract markup vat tax night fixed cost kwh grid carbon intensity emissions"
        case .plannerSettings: "smart charging planner charging power cheapest hours estimate"
        case .homeCharging: "connected services home assistant nexblue easee zaptec wallbox charger pair import earlier sessions"
        case .electricitySupplier: "connected services tibber supplier token home quarter hour"
        case .gridTariff: "network fee fuse capacity charge grid tariff operator vattenfall"
        case .houseMeter: "connected services perific enegic house meter hushållsmätare han port load balancing"
        case .tabLayout: "tab card layout sections order reorder hide show customize custom widgets rows per page pagination history log"
        case .nowControls: "quick control actions limit step lock climate windows honk tailgate now"
        case .chargingLayout: "charging order statistics stat rows rearrange details"
        case .vehicleData: "data fetch readings telemetry VIN charging schedules air quality vehicle location maps weather software status diagnostics real time updates"
        case .remoteFeatures: "remote commands lock climate charge window software remote feature"
        case .vehicleCapabilities: "capability matrix supported available TPMS support export"
        case .automation: "autostart auto start routines calendar preconditioning schedule event cheap window sleep awake keep mac awake sleep prevention"
        case .notifications: "alert warning sound quiet hours low battery unlock rain threshold delay private banners mute badge daily summary"
        case .plannerAlerts: "charging planner notifications notify cheap window lead time tomorrow prices"
        case .privacy: "privacy dashboard screenshot redaction blur VIN plate coordinates device owner command authentication touch id"
        case .localData: "history location retention database prune samples erase sign out exports diagnostics backup"
        case .backup: "settings actions transfer export import backup reset preferences"
        case .updates: "app automatic update check download version frequency interval channel release about"
        }
    }

    func matches(_ query: String) -> Bool {
        let words = Self.searchTerms(title + " " + aliases)
        return Self.searchTerms(query).allSatisfy { term in words.contains { $0.hasPrefix(term) } }
    }

    static func searchTerms(_ text: String) -> [Substring] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: L10n.displayLocale)
            .split { !$0.isLetter && !$0.isNumber }
    }

    static func owner(of feature: AppFeature) -> Self {
        if feature.isRemoteControl { return .remoteFeatures }
        switch feature {
        case .smartChargingPlanner: return .plannerSettings
        case .notifications: return .notifications
        case .updateChecks: return .updates
        default: return .vehicleData
        }
    }

    static func matches(_ item: TabItem, query: String) -> Bool {
        let words = searchTerms(item.title + " " + item.detail)
        return searchTerms(query).allSatisfy { term in words.contains { $0.hasPrefix(term) } }
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
        .padding(.vertical, 22)
        .padding(.horizontal, HisingenTheme.layoutWidth < 600 ? 14 : 22)
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
