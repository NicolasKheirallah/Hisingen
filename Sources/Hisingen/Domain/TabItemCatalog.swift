import Foundation

/// One addressable piece of the interface: a card, a section, a banner, or a tab header.
///
/// Every card a tab can draw is named here. The alternative — each tab view deciding for
/// itself what it renders — is what let five tabs accumulate dozens of cards with no single
/// place a reader could turn any of them off, and no place a new card could be added without
/// editing a second list (a jump menu) to keep up.
enum TabItemID: String, CaseIterable, Codable, Hashable, Sendable {
    // Vehicle
    case vehicleHero = "vehicle-hero"
    case vehicleReceipts = "vehicle-receipts"
    case vehicleAttention = "vehicle-attention"
    case vehicleExceptions = "vehicle-exceptions"
    case vehicleCharging = "vehicle-charging"
    case vehicleChargingPlanner = "vehicle-charging-planner"
    case vehicleFuelEngine = "vehicle-fuel-engine"
    case vehicleReadiness = "vehicle-readiness"
    case vehicleOpenings = "vehicle-openings"
    case vehicleTyres = "vehicle-tyres"
    case vehicleLocation = "vehicle-location"
    case vehicleMore = "vehicle-more"
    case vehicleIdentityDetail = "vehicle-identity-detail"
    case vehicleLighting = "vehicle-lighting"
    case vehicleClimate = "vehicle-climate"
    case vehicleSoftware = "vehicle-software"
    case vehicleDiagnostics = "vehicle-diagnostics"

    // Info
    case infoOverview = "info-overview"
    case infoFreshness = "info-freshness"
    case infoDoors = "info-doors"
    case infoTyres = "info-tyres"
    case infoFluids = "info-fluids"
    case infoSoftware = "info-software"
    case infoLocation = "info-location"
    case infoWeather = "info-weather"
    case infoTrip = "info-trip"
    case infoPowertrain = "info-powertrain"
    case infoBatteryHealth = "info-battery-health"
    case infoBatteryDiagnostics = "info-battery-diagnostics"
    case infoAirQuality = "info-air-quality"
    case infoConnectivity = "info-connectivity"
    case infoService = "info-service"
    case infoWarranty = "info-warranty"
    case infoExterior = "info-exterior"
    case infoInterior = "info-interior"
    case infoChargeLocations = "info-charge-locations"
    case infoFactoryBuild = "info-factory-build"
    case infoCapabilities = "info-capabilities"
    case infoActivity = "info-activity"

    // History
    case historyOverview = "history-overview"
    case historyActivity = "history-activity"
    case historyMonth = "history-month"
    case historyAirCleaning = "history-air-cleaning"
    case historyEmissions = "history-emissions"
    case historyDrivingPatterns = "history-driving-patterns"
    case historyDistance = "history-distance"
    case historyMonthlyMileage = "history-monthly-mileage"
    case historyTrips = "history-trips"
    case historyChargingSessions = "history-charging-sessions"
    case historyChargingCurve = "history-charging-curve"
    case historyMonthlyCharging = "history-monthly-charging"
    case historyChargeLocations = "history-charge-locations"
    case historyChargingHistory = "history-charging-history"
    case historyFuelEconomy = "history-fuel-economy"
    case historyRecentFills = "history-recent-fills"
    case historyEfficiency = "history-efficiency"
    case historyConsumption = "history-consumption"
    case historyOdometer = "history-odometer"
    case historyBatteryHealth = "history-battery-health"
    case historyAirQuality = "history-air-quality"
    case historyCabinClimate = "history-cabin-climate"
    case historyAutomations = "history-automations"

    // Controls
    case controlsBanners = "controls-banners"
    case controlsReceipts = "controls-receipts"
    case controlsClimate = "controls-climate"
    case controlsEngine = "controls-engine"
    case controlsCharging = "controls-charging"
    case controlsAccess = "controls-access"
    case controlsWindowsLocate = "controls-windows-locate"
    case controlsOTA = "controls-ota"

    // Shared headers, offered to any tab
    case vehicleSwitcher = "vehicle-switcher"
    case infoNavBar = "info-nav-bar"
    case historyPeriodPicker = "history-period-picker"
}

/// How a tab item behaves in the layout.
enum TabItemKind: String, Codable, Hashable, Sendable {
    /// A card. Ordered, movable, hideable.
    case card
    /// A strip pinned above the cards (a nav bar, a period picker, a banner stack). Hideable
    /// but never reordered away from the top: a period picker that could be dropped between
    /// two charts would silently change what those charts describe.
    case header
}

/// One catalogued item. `title` is the reader-facing name used in Settings and in the tab's
/// jump menu, so both name the same thing.
struct TabItem: Identifiable, Hashable, Sendable {
    let id: TabItemID
    let title: String
    let symbol: String
    /// The tab this item was designed for. Curation uses it to group the catalog, and a new
    /// tab preselects it; a reader may place an item on any tab regardless.
    let sourceTab: BuiltInTab
    let kind: TabItemKind
    let detail: String
    /// The stored data this card draws on. Hiding the last card that needs it is what
    /// switches the corresponding provider request off, so an item with no feature over
    /// here is drawing on data the app always fetches.
    let feature: AppFeature?

    var isCard: Bool { kind == .card }
}

/// The complete inventory of things a tab can render.
///
/// `defaultItems(for:)` is the shipped layout of each built-in tab, in the order it was
/// designed in. It is the fallback for every reader who never opens the new settings pane,
/// so a tab must render identically to the pre-composition build when nothing is customised.
enum TabItemCatalog {
    static let all: [TabItem] = [
        // MARK: Vehicle
        TabItem(id: .vehicleHero, title: L10n.text("Vehicle hero"), symbol: "car.side.fill",
                sourceTab: .vehicle, kind: .card,
                detail: "Render, model badge, plate, and the at-a-glance state line.", feature: .vehicleImage),
        TabItem(id: .vehicleReceipts, title: L10n.text("Command receipts"), symbol: "checkmark.circle",
                sourceTab: .vehicle, kind: .card,
                detail: "Outcome of remote commands still awaiting confirmation.", feature: nil),
        TabItem(id: .vehicleAttention, title: L10n.text("Attention"), symbol: "exclamationmark.triangle.fill",
                sourceTab: .vehicle, kind: .card,
                detail: "Refresh errors and provider data warnings.", feature: nil),
        TabItem(id: .vehicleExceptions, title: L10n.text("Needs attention"), symbol: "exclamationmark.circle.fill",
                sourceTab: .vehicle, kind: .card,
                detail: "Alarm, open panel, tyre, fluid and software exceptions.", feature: nil),
        TabItem(id: .vehicleCharging, title: L10n.text("Charging"), symbol: "bolt.fill",
                sourceTab: .vehicle, kind: .card,
                detail: "Charge level, power, connector state and completion time.", feature: .chargingDetails),
        TabItem(id: .vehicleChargingPlanner, title: L10n.text("Smart Charging Planner"), symbol: "calendar.badge.clock",
                sourceTab: .vehicle, kind: .card,
                detail: "Cheapest charging window from spot prices.", feature: .smartChargingPlanner),
        TabItem(id: .vehicleFuelEngine, title: L10n.text("Fuel & Engine"), symbol: "fuelpump.fill",
                sourceTab: .vehicle, kind: .card,
                detail: "Fuel level, range and combustion engine state.", feature: nil),
        TabItem(id: .vehicleReadiness, title: L10n.text("Vehicle readiness"), symbol: "checklist",
                sourceTab: .vehicle, kind: .card,
                detail: "Whether the car is ready to drive, and what is not.", feature: nil),
        TabItem(id: .vehicleOpenings, title: L10n.text("Doors & Openings"), symbol: "car.side.lock",
                sourceTab: .vehicle, kind: .card,
                detail: "Door, window, frunk and tailgate state.", feature: .exteriorStatus),
        TabItem(id: .vehicleTyres, title: L10n.text("Tyre Status"), symbol: "circle.grid.2x2",
                sourceTab: .vehicle, kind: .card,
                detail: "Per-wheel pressure schematic and iTPMS state.", feature: .tyreAndWarnings),
        TabItem(id: .vehicleLocation, title: L10n.text("Vehicle Location"), symbol: "location.fill",
                sourceTab: .vehicle, kind: .card,
                detail: "Parking position, address and Apple Maps link.", feature: .vehicleLocation),
        TabItem(id: .vehicleMore, title: L10n.text("More"), symbol: "ellipsis.circle",
                sourceTab: .vehicle, kind: .card,
                detail: "The collapsed disclosure that holds the five detail cards below.", feature: nil),
        TabItem(id: .vehicleIdentityDetail, title: L10n.text("Vehicle Identity"), symbol: "car.side",
                sourceTab: .vehicle, kind: .card,
                detail: "Plate, VIN, odometer, service due and trip meters.", feature: .vehicleIdentity),
        TabItem(id: .vehicleLighting, title: L10n.text("Vehicle Health & Lighting"), symbol: "shield.lefthalf.filled",
                sourceTab: .vehicle, kind: .card,
                detail: "Fluid and lamp warning flags, 12 V battery.", feature: .vehicleHealth),
        TabItem(id: .vehicleClimate, title: L10n.text("Climate & Timers"), symbol: "fan",
                sourceTab: .vehicle, kind: .card,
                detail: "Cabin climate, active timers, schedules, air quality, weather.", feature: .climateStatus),
        TabItem(id: .vehicleSoftware, title: L10n.text("Vehicle Software"), symbol: "gearshape.2.fill",
                sourceTab: .vehicle, kind: .card,
                detail: "Installed and announced versions with release notes.", feature: .softwareUpdates),
        TabItem(id: .vehicleDiagnostics, title: L10n.text("Diagnostics & Sensors"), symbol: "stethoscope",
                sourceTab: .vehicle, kind: .card,
                detail: "Range versus WLTP, network state, average speed and consumption.", feature: .batteryDiagnostics),

        // MARK: Info
        TabItem(id: .infoOverview, title: L10n.text("Overview"), symbol: "photo.artframe",
                sourceTab: .info, kind: .card,
                detail: "Studio render with exterior angle and interior switcher.", feature: .vehicleImage),
        TabItem(id: .infoFreshness, title: L10n.text("Reading Freshness"), symbol: "clock",
                sourceTab: .info, kind: .card,
                detail: "What the vehicle reported, and what it left out.", feature: nil),
        TabItem(id: .infoDoors, title: L10n.text("Doors & Openings"), symbol: "car.side.lock",
                sourceTab: .info, kind: .card,
                detail: "Every opening with per-panel lock state.", feature: .exteriorStatus),
        TabItem(id: .infoTyres, title: L10n.text("Tyres"), symbol: "circle.grid.2x2",
                sourceTab: .info, kind: .card,
                detail: "Pressure schematic with recommended ranges.", feature: .tyreAndWarnings),
        TabItem(id: .infoFluids, title: L10n.text("Fluids & Lighting"), symbol: "drop.fill",
                sourceTab: .info, kind: .card,
                detail: "Fluid levels and lamp warning flags.", feature: .vehicleHealth),
        TabItem(id: .infoSoftware, title: L10n.text("Software & Updates"), symbol: "arrow.triangle.2.circlepath",
                sourceTab: .info, kind: .card,
                detail: "Full software state including release notes.", feature: .softwareUpdates),
        TabItem(id: .infoLocation, title: L10n.text("Parking Location"), symbol: "mappin.and.ellipse",
                sourceTab: .info, kind: .card,
                detail: "Address, coordinates, altitude and a map.", feature: .vehicleLocation),
        TabItem(id: .infoWeather, title: L10n.text("Ambient Conditions"), symbol: "cloud.sun.fill",
                sourceTab: .info, kind: .card,
                detail: "Weather at the vehicle's reported position.", feature: .vehicleWeather),
        TabItem(id: .infoTrip, title: L10n.text("Trip Computer"), symbol: "chart.xyaxis.line",
                sourceTab: .info, kind: .card,
                detail: "Manual and automatic trip meters.", feature: .tripMeters),
        TabItem(id: .infoPowertrain, title: L10n.text("Powertrain & Specs"), symbol: "engine.combustion",
                sourceTab: .info, kind: .card,
                detail: "Architecture, performance and capacity figures.", feature: .vehicleIdentity),
        TabItem(id: .infoBatteryHealth, title: L10n.text("Battery Health"), symbol: "batteryblock",
                sourceTab: .info, kind: .card,
                detail: "State of health, degradation and usable capacity.", feature: .batteryDiagnostics),
        TabItem(id: .infoBatteryDiagnostics, title: L10n.text("Battery Diagnostics"), symbol: "gauge.with.dots.needle.67percent",
                sourceTab: .info, kind: .card,
                detail: "Raw battery state, module health and energy use.", feature: .batteryDiagnostics),
        TabItem(id: .infoAirQuality, title: L10n.text("Air Quality"), symbol: "wind",
                sourceTab: .info, kind: .card,
                detail: "Cabin AQI, particulate matter and clean-zone state.", feature: .airQuality),
        TabItem(id: .infoConnectivity, title: L10n.text("Connectivity & Wake"), symbol: "antenna.radiowaves.left.and.right",
                sourceTab: .info, kind: .card,
                detail: "Modem state, signal strength and wake reason.", feature: .connectivityDiagnostics),
        TabItem(id: .infoService, title: L10n.text("Service Schedule"), symbol: "wrench.and.screwdriver",
                sourceTab: .info, kind: .card,
                detail: "Distance and time to the next service.", feature: .vehicleHealth),
        TabItem(id: .infoWarranty, title: L10n.text("Warranty & Protection"), symbol: "shield.checkered",
                sourceTab: .info, kind: .card,
                detail: "Factory warranty and corrosion coverage.", feature: nil),
        TabItem(id: .infoExterior, title: L10n.text("Exterior & Styling"), symbol: "paintpalette",
                sourceTab: .info, kind: .card,
                detail: "Paint, wheels and exterior equipment.", feature: .vehicleIdentity),
        TabItem(id: .infoInterior, title: L10n.text("Interior & Cabin"), symbol: "carseat.left.fill",
                sourceTab: .info, kind: .card,
                detail: "Upholstery, steering orientation and cabin equipment.", feature: .vehicleIdentity),
        TabItem(id: .infoChargeLocations, title: L10n.text("Saved Charge Locations"), symbol: "mappin.circle.fill",
                sourceTab: .info, kind: .card,
                detail: "Saved charging locations and their aliases.", feature: .chargingDetails),
        TabItem(id: .infoFactoryBuild, title: L10n.text("Factory Build & Identity"), symbol: "hammer.fill",
                sourceTab: .info, kind: .card,
                detail: "Build week, factory specification and market data.", feature: .vehicleIdentity),
        TabItem(id: .infoCapabilities, title: L10n.text("Vehicle Capabilities"), symbol: "checklist",
                sourceTab: .info, kind: .card,
                detail: "Which provider capabilities this exact car reports.", feature: nil),
        TabItem(id: .infoActivity, title: L10n.text("Vehicle Activity History"), symbol: "clock.arrow.circlepath",
                sourceTab: .info, kind: .card,
                detail: "Local log of telemetry changes and commands.", feature: nil),

        // MARK: History
        TabItem(id: .historyOverview, title: L10n.text("Overview"), symbol: "chart.pie.fill",
                sourceTab: .history, kind: .card,
                detail: "Period totals for distance, energy and cost.", feature: nil),
        TabItem(id: .historyActivity, title: L10n.text("Activity"), symbol: "clock.arrow.circlepath",
                sourceTab: .history, kind: .card,
                detail: "Observed changes recorded in this period.", feature: nil),
        TabItem(id: .historyMonth, title: L10n.text("Month Comparison"), symbol: "calendar",
                sourceTab: .history, kind: .card,
                detail: "This month against the previous one.", feature: nil),
        TabItem(id: .historyAirCleaning, title: L10n.text("Air Cleaning"), symbol: "sparkles",
                sourceTab: .history, kind: .card,
                detail: "Cabin cleaning cycles and their runtime.", feature: nil),
        TabItem(id: .historyEmissions, title: L10n.text("Emissions"), symbol: "leaf.fill",
                sourceTab: .history, kind: .card,
                detail: "Avoided and actual tailpipe emissions.", feature: nil),
        TabItem(id: .historyDrivingPatterns, title: L10n.text("Driving Patterns"), symbol: "steeringwheel",
                sourceTab: .history, kind: .card,
                detail: "When and how the car is driven.", feature: nil),
        TabItem(id: .historyDistance, title: L10n.text("Distance"), symbol: "road.lanes",
                sourceTab: .history, kind: .card,
                detail: "Distance over time for the selected period.", feature: nil),
        TabItem(id: .historyMonthlyMileage, title: L10n.text("Monthly Mileage"), symbol: "calendar.badge.clock",
                sourceTab: .history, kind: .card,
                detail: "Distance per month across the whole record.", feature: nil),
        TabItem(id: .historyTrips, title: L10n.text("Trips"), symbol: "point.topleft.down.to.point.bottomright.curvepath",
                sourceTab: .history, kind: .card,
                detail: "Segment list with search, sort and hiding.", feature: nil),
        TabItem(id: .historyChargingSessions, title: L10n.text("Charging Sessions"), symbol: "powerplug.fill",
                sourceTab: .history, kind: .card,
                detail: "Session list with energy, cost and location.", feature: nil),
        TabItem(id: .historyChargingCurve, title: L10n.text("Charging Curve"), symbol: "chart.line.uptrend.xyaxis",
                sourceTab: .history, kind: .card,
                detail: "Power curve of the selected session.", feature: nil),
        TabItem(id: .historyMonthlyCharging, title: L10n.text("Charging by Month"), symbol: "calendar.badge.plus",
                sourceTab: .history, kind: .card,
                detail: "Energy and cost per month.", feature: nil),
        TabItem(id: .historyChargeLocations, title: L10n.text("Charge Locations"), symbol: "mappin.and.ellipse",
                sourceTab: .history, kind: .card,
                detail: "Where charging happened, and how much.", feature: nil),
        TabItem(id: .historyChargingHistory, title: L10n.text("Charging History"), symbol: "list.bullet.rectangle",
                sourceTab: .history, kind: .card,
                detail: "Full session table with export.", feature: nil),
        TabItem(id: .historyFuelEconomy, title: L10n.text("Fuel Economy"), symbol: "fuelpump.fill",
                sourceTab: .history, kind: .card,
                detail: "Measured consumption between fill-ups.", feature: nil),
        TabItem(id: .historyRecentFills, title: L10n.text("Recent Fill-ups"), symbol: "drop.fill",
                sourceTab: .history, kind: .card,
                detail: "Logged fill-ups with price and odometer.", feature: nil),
        TabItem(id: .historyEfficiency, title: L10n.text("Efficiency"), symbol: "gauge.with.needle",
                sourceTab: .history, kind: .card,
                detail: "Consumption per distance over time.", feature: nil),
        TabItem(id: .historyConsumption, title: L10n.text("Consumption"), symbol: "chart.bar.fill",
                sourceTab: .history, kind: .card,
                detail: "Combustion consumption over time.", feature: nil),
        TabItem(id: .historyOdometer, title: L10n.text("Odometer"), symbol: "speedometer",
                sourceTab: .history, kind: .card,
                detail: "Mileage progression across the record.", feature: nil),
        TabItem(id: .historyBatteryHealth, title: L10n.text("Battery Health"), symbol: "batteryblock",
                sourceTab: .history, kind: .card,
                detail: "State of health over time.", feature: nil),
        TabItem(id: .historyAirQuality, title: L10n.text("Air Quality"), symbol: "wind",
                sourceTab: .history, kind: .card,
                detail: "Cabin and outside particulate matter over time.", feature: nil),
        TabItem(id: .historyCabinClimate, title: L10n.text("Cabin Climate"), symbol: "thermometer.medium",
                sourceTab: .history, kind: .card,
                detail: "Cabin temperature and climate runtime.", feature: nil),
        TabItem(id: .historyAutomations, title: L10n.text("Automations"), symbol: "wand.and.stars",
                sourceTab: .history, kind: .card,
                detail: "Audit trail of every remote command sent.", feature: nil),

        // MARK: Controls
        TabItem(id: .controlsBanners, title: L10n.text("Command status banners"), symbol: "text.bubble",
                sourceTab: .controls, kind: .header,
                detail: "Sent, failed and offline notices, above the controls.", feature: nil),
        TabItem(id: .controlsReceipts, title: L10n.text("Command receipts"), symbol: "checkmark.circle",
                sourceTab: .controls, kind: .card,
                detail: "Receipts for commands still awaiting confirmation.", feature: nil),
        TabItem(id: .controlsClimate, title: L10n.text("Climate controls"), symbol: "fan",
                sourceTab: .controls, kind: .card,
                detail: "Start climate, set temperature and seat heating.", feature: .remoteClimate),
        TabItem(id: .controlsEngine, title: L10n.text("Engine controls"), symbol: "engine.combustion.fill",
                sourceTab: .controls, kind: .card,
                detail: "Remote start and stop for combustion vehicles.", feature: .remoteClimate),
        TabItem(id: .controlsCharging, title: L10n.text("Charging controls"), symbol: "bolt.badge.clock",
                sourceTab: .controls, kind: .card,
                detail: "Charge target, current limit and charging override.", feature: .remoteCharging),
        TabItem(id: .controlsAccess, title: L10n.text("Lock controls"), symbol: "lock.fill",
                sourceTab: .controls, kind: .card,
                detail: "Lock, unlock and tailgate control.", feature: .remoteLocks),
        TabItem(id: .controlsWindowsLocate, title: L10n.text("Windows, honk & flash"), symbol: "car.window.left",
                sourceTab: .controls, kind: .card,
                detail: "Window closing, honk and flash to locate.", feature: .remoteWindows),
        TabItem(id: .controlsOTA, title: L10n.text("Vehicle software controls"), symbol: "arrow.down.circle.fill",
                sourceTab: .controls, kind: .card,
                detail: "Install an available software update now.", feature: .remoteOTA),

        // MARK: Shared headers
        TabItem(id: .vehicleSwitcher, title: L10n.text("Vehicle switcher"), symbol: "car.2.fill",
                sourceTab: .vehicle, kind: .header,
                detail: "Chips for moving between the vehicles on this account.", feature: .multipleVehicles),
        TabItem(id: .infoNavBar, title: L10n.text("Section jump bar"), symbol: "list.bullet.indent",
                sourceTab: .info, kind: .header,
                detail: "Freshness line, jump menu and the vehicle report menu.", feature: nil),
        TabItem(id: .historyPeriodPicker, title: L10n.text("Period picker"), symbol: "calendar",
                sourceTab: .history, kind: .header,
                detail: "7 / 30 / 90 day, year, all and custom range controls.", feature: nil)
    ]

    private static let byID: [TabItemID: TabItem] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    static func item(_ id: TabItemID) -> TabItem? { byID[id] }

    /// Falls back to the raw value so an item that somehow escaped the table still renders
    /// with a readable name instead of crashing a tab.
    static func title(_ id: TabItemID) -> String { byID[id]?.title ?? id.rawValue }

    static func symbol(_ id: TabItemID) -> String { byID[id]?.symbol ?? "square.dashed" }

    static func items(in tab: BuiltInTab) -> [TabItem] { all.filter { $0.sourceTab == tab } }

    static var headers: [TabItem] { all.filter { $0.kind == .header } }

    static var cards: [TabItem] { all.filter(\.isCard) }

    /// The shipped layout of each built-in tab, in the order it was designed in.
    static func defaultItems(for tab: BuiltInTab) -> [TabItemID] {
        switch tab {
        case .vehicle:
            return [
                .vehicleSwitcher, .vehicleHero, .vehicleReceipts, .vehicleAttention,
                .vehicleExceptions, .vehicleCharging, .vehicleChargingPlanner,
                .vehicleFuelEngine, .vehicleReadiness, .vehicleOpenings, .vehicleTyres,
                .vehicleLocation, .vehicleMore, .vehicleIdentityDetail, .vehicleLighting,
                .vehicleClimate, .vehicleSoftware, .vehicleDiagnostics
            ]
        case .info:
            return [
                .infoNavBar, .infoOverview, .infoFreshness, .infoDoors, .infoTyres,
                .infoFluids, .infoSoftware, .infoLocation, .infoWeather, .infoTrip,
                .infoPowertrain, .infoBatteryHealth, .infoBatteryDiagnostics, .infoAirQuality,
                .infoConnectivity, .infoService, .infoWarranty, .infoExterior, .infoInterior,
                .infoChargeLocations, .infoFactoryBuild, .infoCapabilities, .infoActivity
            ]
        case .history:
            return [
                .historyPeriodPicker, .historyOverview, .historyActivity, .historyMonth,
                .historyAirCleaning, .historyEmissions, .historyDrivingPatterns, .historyDistance,
                .historyMonthlyMileage, .historyTrips, .historyChargingSessions,
                .historyChargingCurve, .historyMonthlyCharging, .historyChargeLocations,
                .historyChargingHistory, .historyFuelEconomy, .historyRecentFills,
                .historyEfficiency, .historyConsumption, .historyOdometer, .historyBatteryHealth,
                .historyAirQuality, .historyCabinClimate, .historyAutomations
            ]
        case .controls:
            return [
                .controlsBanners, .controlsReceipts, .controlsClimate, .controlsEngine,
                .controlsCharging, .controlsAccess, .controlsWindowsLocate, .controlsOTA
            ]
        case .settings:
            // Settings is its own surface, managed by the settings sections rather than by
            // this catalog. It is listed so a hidden-tab set can name it.
            return []
        }
    }

    /// Default placement of every catalogued item, as items rather than ids, for callers that
    /// need titles and symbols too.
    static func defaultEntries(for tab: BuiltInTab) -> [TabItem] {
        defaultItems(for: tab).compactMap(item)
    }
}
