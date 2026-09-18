import AppKit
import SwiftUI

/// The Info tab. The card bodies are split across `InfoTabView+*.swift` (Hero, Capabilities,
/// Diagnostics, BatteryHealth, Location, Specs); this file keeps the section list, the nav
/// bar, async data loading, and the shared vehicle-report export. Swift extensions in other
/// files can only reach `internal` members, so the view state and helpers those cards touch
/// are declared without `private`.
@MainActor
struct InfoTabView: View {

    /// The reader's layout for this tab: what to draw, and in what order. The default draws
    /// everything exactly as designed.
    var layout: TabLayout = .everything

    func draws(_ item: TabItemID) -> Bool { layout.draws(item) }

    func ordered<T>(_ entries: [T], by item: (T) -> TabItemID) -> [T] {
        layout.ordered(entries, by: item)
    }

    let state: VehicleState
    let database: VehicleDatabase
    let imageCache: CarImageCache
    let reverseGeocoder: ReverseGeocoder
    var onRefresh: () -> Void = {}
    var onNavigateToHistory: () -> Void = {}
    var onRemoteCommand: (RemoteCommand) -> Void = { _ in }

    @State var selectedAngleIndex: Int = CarRenderAngle.frontThreeQuarter.rawValue
    @State var addressText: String?
    @State var addressResolved = false
    @Environment(\.preferencesStore) var preferences
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var vinCopied = false
    @State var asyncData = InfoAsyncData()
    /// Whether the local read has completed once. The activity section used to be added only when
    /// it had rows, so "nothing recorded" and "not read yet" were both simply silence: the section
    /// appeared out of nowhere a moment after the tab opened, and an empty store looked the same
    /// as an unread one.
    @State var asyncDataLoaded = false
    @State var showAllCapabilities = false
    @State var reportError: String?
    @State private var isRefreshing = false
    @State private var selectedCategory: InfoCategory = .all

    enum InfoCategory: String, CaseIterable, Identifiable {
        case all
        case specs
        case battery
        case status

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return L10n.text("All")
            case .specs: return L10n.text("Specs")
            case .battery: return L10n.text("Battery")
            case .status: return L10n.text("Status")
            }
        }

        func matches(_ section: InfoSection) -> Bool {
            switch self {
            case .all:
                return true
            case .specs:
                return section == .overview || section == .factoryBuild || section == .exterior || section == .interior || section == .software || section == .connectivity
            case .battery:
                return section == .powertrain || section == .batteryHealth || section == .batteryDiagnostics || section == .chargeLocations
            case .status:
                return section == .doors || section == .tyres || section == .fluids || section == .location || section == .weather || section == .trip || section == .airQuality || section == .service || section == .warranty || section == .capabilities || section == .activity || section == .freshness
            }
        }
    }

    /// Declared explicitly: non-`private` `@State`/`@Environment` (needed so the split-out
    /// `InfoTabView+*.swift` extensions can reach them) otherwise perturbs the synthesized
    /// memberwise initializer.
    init(
        state: VehicleState,
        database: VehicleDatabase,
        imageCache: CarImageCache,
        reverseGeocoder: ReverseGeocoder,
        onRefresh: @escaping () -> Void = {},
        onNavigateToHistory: @escaping () -> Void = {},
        onRemoteCommand: @escaping (RemoteCommand) -> Void = { _ in },
        layout: TabLayout = .everything
    ) {
        self.state = state
        self.database = database
        self.imageCache = imageCache
        self.reverseGeocoder = reverseGeocoder
        self.onRefresh = onRefresh
        self.onNavigateToHistory = onNavigateToHistory
        self.onRemoteCommand = onRemoteCommand
        self.layout = layout
    }

    /// Everything the Info tab derives from the local store lives on the Vehicle History
    /// ledger's read model (aliased here so the split-out card extensions keep their names).
    typealias InfoAsyncData = VehicleHistoryLedger.RecentRecords

    /// Stable identity + ordering for every card, so the "jump to section" menu and the render
    /// loop derive from one list instead of two hand-synced copies.
    enum InfoSection: String, CaseIterable, Hashable {
        case overview, doors, tyres, fluids, software, location, weather
        case trip, powertrain, batteryHealth, batteryDiagnostics, airQuality
        case connectivity, service, warranty, exterior, interior, chargeLocations
        case factoryBuild, capabilities, activity, freshness

        var title: String {
            switch self {
            case .overview: return L10n.text("Overview")
            case .doors: return L10n.text("Doors & Openings")
            case .tyres: return L10n.text("Tyres")
            case .fluids: return L10n.text("Fluids & Lighting")
            case .software: return L10n.text("Software & Updates")
            case .location: return L10n.text("Parking Location")
            case .weather: return L10n.text("Ambient Conditions")
            case .trip: return L10n.text("Trip Computer")
            case .powertrain: return L10n.text("Powertrain & Specs")
            case .batteryHealth: return L10n.text("Battery Health")
            case .batteryDiagnostics: return L10n.text("Battery Diagnostics")
            case .airQuality: return L10n.text("Air Quality")
            case .connectivity: return L10n.text("Connectivity & Wake")
            case .service: return L10n.text("Service Schedule")
            case .warranty: return L10n.text("Warranty & Protection")
            case .exterior: return L10n.text("Exterior & Styling")
            case .interior: return L10n.text("Interior & Cabin")
            case .chargeLocations: return L10n.text("Saved Charge Locations")
            case .factoryBuild: return L10n.text("Factory Build & Identity")
            case .capabilities: return L10n.text("Vehicle Capabilities")
            case .activity: return L10n.text("Activity History")
            case .freshness: return L10n.text("Reading Freshness")
            }
        }
    }


    /// The composition identity of each section. The section list and the catalog are the same
    /// inventory under two names, and this is the one place they are tied together.
    static func item(for section: InfoSection) -> TabItemID {
        switch section {
        case .overview: return .infoOverview
        case .doors: return .infoDoors
        case .tyres: return .infoTyres
        case .fluids: return .infoFluids
        case .software: return .infoSoftware
        case .location: return .infoLocation
        case .weather: return .infoWeather
        case .trip: return .infoTrip
        case .powertrain: return .infoPowertrain
        case .batteryHealth: return .infoBatteryHealth
        case .batteryDiagnostics: return .infoBatteryDiagnostics
        case .airQuality: return .infoAirQuality
        case .connectivity: return .infoConnectivity
        case .service: return .infoService
        case .warranty: return .infoWarranty
        case .exterior: return .infoExterior
        case .interior: return .infoInterior
        case .chargeLocations: return .infoChargeLocations
        case .factoryBuild: return .infoFactoryBuild
        case .capabilities: return .infoCapabilities
        case .activity: return .infoActivity
        case .freshness: return .infoFreshness
        }
    }

    /// Sections this tab builds. Exposed so the catalog can verify completeness against it.
    static var shippedSections: [InfoSection] {
        InfoSection.allCases
    }


    struct InfoSectionEntry: Identifiable {
        let id: InfoSection
        let view: AnyView
    }

    var availableExteriorAngles: [CarRenderAngle] {
        CarRenderAngle.allCases.filter { angle in
            imageCache.hasImage(for: state.identity.vin, angle: angle.rawValue)
                || (angle == preferences.carRenderAngle && state.identity.imageData != nil)
        }
    }

    var body: some View {
        let allEntries = makeSections()
        let entries = selectedCategory == .all ? allEntries : allEntries.filter { selectedCategory.matches($0.id) }
        return ScrollViewReader { proxy in
            VStack(spacing: HisingenTheme.sectionSpacing) {
                if draws(.infoNavBar) {
                    infoNavBar(proxy: proxy, entries: allEntries)
                    Picker("", selection: $selectedCategory) {
                        ForEach(InfoCategory.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel(L10n.text("Info section category"))
                }
                ForEach(entries) { entry in
                    entry.view
                        .id(entry.id)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .hisAnimation(Motion.cardChange, value: entries.map(\.id))
            .onAppear {
                let preferred = preferences.carRenderAngle
                selectedAngleIndex = availableExteriorAngles.contains(preferred)
                    ? preferred.rawValue
                    : (availableExteriorAngles.first?.rawValue ?? selectedAngleIndex)
            }
            .task(id: "\(state.identity.vin)|\(state.freshness.fetchedAt.timeIntervalSince1970)") { await loadAsyncData() }
            .task(id: coordinateKey) { await resolveAddressIfNeeded() }
            .alert(
                L10n.text("Something Went Wrong"),
                isPresented: Binding(get: { reportError != nil }, set: { if !$0 { reportError = nil } })
            ) {
                Button(L10n.text("OK"), role: .cancel) {}
            } message: {
                Text(reportError ?? "")
            }
        }
    }

    // MARK: - Section assembly

    private func makeSections() -> [InfoSectionEntry] {
        var out: [InfoSectionEntry] = []
        func add(_ id: InfoSection, _ view: some View) {
            // The reader's layout decides what this tab draws. Hidden sections are simply not
            // built, so a card switched off costs nothing to render.
            guard draws(Self.item(for: id)) else { return }
            out.append(InfoSectionEntry(id: id, view: AnyView(view)))
        }

        add(.overview, heroVisualSection)
        add(.freshness, readingFreshnessCard)

        if let ext = state.exteriorStatus, !ext.openings.isEmpty {
            add(.doors, DoorsAndOpeningsCardView(ext: ext, isLocked: ext.isLocked,
                                                 isTailgateLocked: ext.isTailgateLocked,
                                                 model: state.model))
        }
        if let tyres = state.maintenance.details?.tyres, !tyres.isEmpty {
            add(.tyres, TireStatusCardView(tyres: tyres, model: state.model))
        }
        add(.fluids, fluidsAndLightingCard)
        if softwareCardHasContent {
            add(.software, softwareUpdateCard)
        }
        if state.location?.latitude != nil {
            add(.location, parkingLocationCard)
        }
        if weatherCardHasContent {
            add(.weather, ambientWeatherCard)
        }
        if state.tripComputer.manualTripKm != nil || state.tripComputer.automaticTripKm != nil || state.tripComputer.sinceChargeTripKm != nil || state.tripComputer.averageSpeedKmH != nil {
            add(.trip, tripComputerCard)
        }
        add(.powertrain, powertrainSpecsCard)
        if state.powertrain.hasElectricRange {
            add(.batteryHealth, batteryHealthCard)
        }
        if !batteryDiagnosticsRows.isEmpty {
            add(.batteryDiagnostics, batteryDiagnosticsCard)
        }
        if state.airQuality != nil {
            add(.airQuality, airQualityCleanZoneCard)
        }
        if state.connectivity != nil {
            add(.connectivity, connectivityWakeCard)
        }
        if serviceCardHasContent {
            add(.service, serviceAndHealthCard)
        }
        add(.warranty, warrantyAndProtectionCard)
        if exteriorCardHasContent {
            add(.exterior, exteriorStylingCard)
        }
        if interiorCardHasContent {
            add(.interior, interiorCabinCard)
        }
        if !savedChargeLocations.isEmpty {
            add(.chargeLocations, chargeLocationsCard)
        }
        add(.factoryBuild, factoryBuildCard)
        if state.otaCapabilities != nil, state.isVolvo == false {
            add(.capabilities, capabilityInspectorCard)
        } else if !capabilityProfileEntries.positive.isEmpty || !capabilityProfileEntries.negative.isEmpty {
            add(.capabilities, vehicleCapabilityCard)
        }
        // Present from the first paint, with a placeholder until the read lands and an explicit
        // empty state after it, rather than appearing only once it has something to show.
        if !asyncDataLoaded {
            add(.activity, activityPlaceholderCard(message: nil))
        } else if asyncData.recentTelemetry.isEmpty, asyncData.recentCommands.isEmpty,
                  asyncData.recentActivities.isEmpty {
            add(.activity, activityPlaceholderCard(message: L10n.text("No local activity recorded yet.")))
        } else {
            add(.activity, activityHistoryCard)
        }
        // The reader's order, when they have one. Sections the layout does not name — none by
        // default — keep the position they were added in, after the ones it does.
        return ordered(out, by: { Self.item(for: $0.id) })
    }

    /// The activity section's loading and empty states, matching the header the loaded card uses so
    /// the section does not change shape when its rows arrive.
    @ViewBuilder
    private func activityPlaceholderCard(message: String?) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "clock.arrow.circlepath", title: L10n.text("Vehicle Activity History"), color: .indigo)
                if let message {
                    Text(message).hisType(.label).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private func infoNavBar(proxy: ScrollViewProxy, entries: [InfoSectionEntry]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: state.hasOldData() ? "moon.stars.fill" : "clock.arrow.circlepath")
                .hisType(.label)
                .foregroundStyle(state.hasOldData() ? HisingenTheme.semanticWarning : Color.secondary.opacity(0.7))
                .hisAnimation(Motion.theme, value: state.hasOldData())
                .accessibilityHidden(true)
            Text(state.freshness.isCached ? L10n.text("Showing an offline copy") : state.freshnessDescription)
                .hisType(.caption, weight: state.hasOldData() ? .semibold : .regular)
                .foregroundStyle(state.hasOldData() ? HisingenTheme.semanticWarning : Color.secondary.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .truncationMode(.middle)
                .hisAnimation(Motion.theme, value: state.hasOldData())

            Spacer(minLength: 6)

            Menu {
                ForEach(entries) { entry in
                    Button(entry.id.title) {
                        withAnimation(Motion.resolve(Motion.entrance)) {
                            proxy.scrollTo(entry.id, anchor: .top)
                        }
                    }
                }
            } label: {
                Image(systemName: "list.bullet.indent")
                    .hisType(.label, weight: .medium)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .hisCaptionLeading()
            .fixedSize(horizontal: false, vertical: true)
            .help(L10n.text("Jump to section"))
            .accessibilityLabel(L10n.text("Jump to section"))

            Menu {
                Button {
                    copyVehicleReport()
                } label: {
                    Label(L10n.text("Copy Vehicle Report"), systemImage: "doc.on.doc")
                }
                Button {
                    exportVehicleReport()
                } label: {
                    Label(L10n.text("Export Vehicle Report…"), systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .hisType(.label, weight: .medium)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .hisCaptionLeading()
            .fixedSize(horizontal: false, vertical: true)
            .help(L10n.text("Vehicle report"))
            .accessibilityLabel(L10n.text("Vehicle report"))

            Button {
                guard !isRefreshing else { return }
                isRefreshing = true
                onRefresh()
                Task {
                    // Backstop only. The spinner is normally cleared by the `.onChange` below when
                    // the refresh actually lands. A fixed 2.5s cleared it regardless, so a slow
                    // wake showed a finished spinner while data was still arriving, and a fast
                    // local read kept spinning after it had finished.
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    isRefreshing = false
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .hisType(.label, weight: .semibold)
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(
                        Motion.resolve(isRefreshing ? Motion.spin : .default),
                        value: isRefreshing
                    )
            }
            .buttonStyle(.pressable)
            .disabled(isRefreshing)
            .onChange(of: state.freshness.fetchedAt) { _, _ in isRefreshing = false }
            // "Refresh Telemetry", matching the footer's button and its tooltip: one action,
            // one description. It was "Refresh now" here and "Refresh Telemetry" there.
            .help(L10n.text("Refresh Telemetry"))
            .accessibilityLabel(L10n.text("Refresh Telemetry"))
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Async data

    private var coordinateKey: String? {
        guard let lat = state.location?.latitude, let lon = state.location?.longitude else { return nil }
        return "\(lat),\(lon)"
    }

    private func loadAsyncData() async {
        let vin = state.identity.vin
        let db = database
        let capacity = state.configuredCapacityReference(
            specification: preferences.vehicleSpecificationOverride(for: vin)).kwh
        let loaded = await Task.detached(priority: .userInitiated) { () -> InfoAsyncData in
            return db.history.recent(vin: vin, chargingCapacityKwh: capacity)
        }.value
        guard !Task.isCancelled else { return }
        asyncData = loaded
        asyncDataLoaded = true
    }

    private func resolveAddressIfNeeded() async {
        guard let lat = state.location?.latitude, let lon = state.location?.longitude else { return }
        addressResolved = false
        addressText = nil
        let resolved = await reverseGeocoder.geocode(latitude: lat, longitude: lon)
        guard !Task.isCancelled else { return }
        addressText = resolved
        addressResolved = true
    }

    // MARK: - Section visibility helpers

    var weatherCardHasContent: Bool {
        guard let w = state.weather else { return false }
        return w.temperatureCelsius != nil || (w.condition?.isEmpty == false) || w.relativeHumidity != nil
            || w.apparentTemperatureCelsius != nil
    }

    private var serviceCardHasContent: Bool {
        state.maintenance.service.daysToService != nil
            || (state.maintenance.service.engineHoursToService ?? 0) > 0
            || (state.maintenance.service.preferredWorkshopName?.isEmpty == false)
            || (state.maintenance.service.preferredWorkshopID?.isEmpty == false)
    }

    private var exteriorCardHasContent: Bool {
        (state.identity.externalColour?.isEmpty == false)
            || ((state.exteriorStatus?.physicalDoorCount ?? 0) > 0)
    }

    private var interiorCardHasContent: Bool {
        (state.identity.upholstery?.isEmpty == false)
            || (state.formattedSteeringOrientation?.isEmpty == false)
            || state.climateStatus != nil
    }

    var savedChargeLocations: [ChargeLocationSnapshot] {
        state.energy.locations.filter { $0.isSavedLocation || !$0.alias.isEmpty }
    }

    private var softwareCardHasContent: Bool {
        guard let sw = state.softwareInfo else { return false }
        return sw.noUpdateAvailable == true || (sw.installedVersion?.isEmpty == false)
            || (sw.version?.isEmpty == false)
            || (sw.latestAvailableVersion?.isEmpty == false)
            || sw.state != .unknown
            || sw.scheduledAt != nil
    }

    var batteryHealthEstimate: BatteryHealthEstimate? {
        if let current = BatteryHealthEstimator.estimate(
            state: state,
            specification: preferences.vehicleSpecificationOverride(for: state.identity.vin)
        ) { return current }
        guard let saved = asyncData.batteryHealthHistory.first(where: {
            $0.measurementSource == BatteryHealthRecord.fullChargeRangeSource
        }) else { return nil }
        return BatteryHealthEstimator.remembered(
            stateOfHealthPercent: saved.stateOfHealthPct,
            degradationPercent: saved.degradationPct,
            estimatedUsableCapacityKwh: saved.effectiveUsableKwh,
            recordedAt: saved.timestamp,
            fallbackReferenceCapacityKwh: state.configuredCapacityReference(
                specification: preferences.vehicleSpecificationOverride(for: state.identity.vin)).kwh
        )
    }

    // MARK: - Chart & geo helpers

    func headingToCardinal(_ heading: Double) -> String {
        let normalized = (heading.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"].map { L10n.text($0) }
        let index = Int(((normalized + 22.5) / 45.0).truncatingRemainder(dividingBy: 8))
        return directions[index]
    }

    // MARK: - Vehicle report

    private func buildVehicleReport() -> String {
        // A report is easy to paste into an email or forum thread, so honour the same
        // screenshot-privacy switch that redacts the VIN, plate, and coordinates on screen.
        let redacted = preferences.privacyRedactionEnabled
        var lines: [String] = []
        func row(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            lines.append("\(key): \(value)")
        }

        lines.append(L10n.text("Vehicle Report"))
        lines.append(String(repeating: "=", count: 44))
        row(L10n.text("Generated"), Format.dateTimeFormatter.string(from: Date()))
        row(L10n.text("Data From"), Format.relativeAge(since: state.dataTimestamp))
        if redacted {
            row(L10n.text("Privacy"), L10n.text("VIN, plate, and location redacted"))
        }
        lines.append("")

        row(L10n.text("Model"), [state.identity.modelName, state.identity.modelYear].compactMap { $0 }.joined(separator: " "))
        row(L10n.text("VIN"), redacted
            ? String(repeating: "•", count: max(0, state.identity.vin.count - 4)) + state.identity.vin.suffix(4)
            : state.identity.vin)
        if !redacted { row(L10n.text("Registration"), state.identity.registrationNo) }
        row(L10n.text("Vehicle ID"), state.identity.internalVehicleIdentifier)
        row(L10n.text("Architecture"), state.powertrain.displayName)
        if let odo = state.maintenance.odometerKm {
            row(L10n.text("Odometer"), Format.distance(km: odo, grouped: true, unit: preferences.distanceUnit))
        }
        if let battery = state.energy.batteryPercentage {
            row(L10n.text("Battery"), String(format: "%.0f%%", battery))
        }
        if let range = state.primaryRangeKm {
            row(L10n.text("Range"), Format.distance(km: range, unit: preferences.distanceUnit))
        }
        if state.powertrain.hasElectricRange {
            row(L10n.text("Charging"), state.energy.chargingState.displayName)
            if let target = state.energy.targetPercentage {
                row(L10n.text("Charge Target"), "\(target)%")
            }
        }
        row(L10n.text("Exterior Paint"), state.identity.externalColour)
        row(L10n.text("Interior Trim"), state.identity.upholstery)
        row(L10n.text("Factory Build Week"), state.formattedBuildWeek ?? state.identity.structureWeek)
        row(L10n.text("Factory Spec (PNO34)"), state.identity.pno34)
        row(L10n.text("Market Delivery"), state.otaCapabilities?.identity?.market ?? state.identity.accountMarket)
        row(L10n.text("Backend-Reported Software"), state.softwareInfo?.installedVersion ?? state.softwareInfo?.version)

        if let days = state.maintenance.service.daysToService {
            row(L10n.text("Service Due"), L10n.format("in %d days", days))
        }
        if let inService = preferences.warrantyInServiceDate(for: state.identity.vin) {
            row(L10n.text("In-Service Date"), Format.dateFormatter.string(from: inService))
        }
        if let warranty = state.maintenance.warranty?.factoryWarrantyValidUntil {
            row(L10n.text("Manufacturer Warranty"), Format.dateFormatter.string(from: warranty))
        }

        if let estimate = batteryHealthEstimate {
            lines.append("")
            row(L10n.text("Calculated SoH"), String(format: "%.1f%%", estimate.stateOfHealthPercent))
            row(L10n.text("Calculation Method"), L10n.text("Full-charge range estimate"))
            row(L10n.text("Last 100% calculation"), Format.dateTimeFormatter.string(from: estimate.recordedAt))
            row(L10n.text("Calculated Degradation"), String(format: "%.1f%%", estimate.degradationPercent))
        }

        if !redacted {
            if let address = addressText {
                lines.append("")
                row(L10n.text("Parking Address"), address)
            }
            if let lat = state.location?.latitude, let lon = state.location?.longitude {
                row(L10n.text("Coordinates"), String(format: "%.5f, %.5f", lat, lon))
            }
        }

        lines.append("")
        lines.append(L10n.text("Generated by Hisingen. Calculated values are estimates, not vehicle telemetry."))
        return lines.joined(separator: "\n")
    }

    private func copyVehicleReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(buildVehicleReport(), forType: .string)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    private func exportVehicleReport() {
        let report = buildVehicleReport()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "vehicle_report_\(state.identity.vin.prefix(8)).txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            } catch {
                reportError = error.localizedDescription
            }
        }
    }
}
