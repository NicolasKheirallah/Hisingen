import AppKit
import SwiftUI

/// The Info tab. The card bodies are split across `InfoTabView+*.swift` (Hero, Capabilities,
/// Diagnostics, BatteryHealth, Location, Specs); this file keeps the section list, the nav
/// bar, async data loading, and the shared vehicle-report export. Swift extensions in other
/// files can only reach `internal` members, so the view state and helpers those cards touch
/// are declared without `private`.
@MainActor
struct InfoTabView: View {
    let state: VehicleState
    let database: VehicleDatabase
    let imageCache: CarImageCache
    let reverseGeocoder: ReverseGeocoder
    var onRefresh: () -> Void = {}
    var onNavigateToHistory: () -> Void = {}

    @State var selectedAngleIndex: Int = CarRenderAngle.frontThreeQuarter.rawValue
    @State var addressText: String?
    @State var addressResolved = false
    @Environment(\.preferencesStore) var preferences
    @State var vinCopied = false
    @State var asyncData = InfoAsyncData()
    @State var showAllCapabilities = false
    @State var reportError: String?
    @State private var isRefreshing = false

    /// Declared explicitly: non-`private` `@State`/`@Environment` (needed so the split-out
    /// `InfoTabView+*.swift` extensions can reach them) otherwise perturbs the synthesized
    /// memberwise initializer.
    init(
        state: VehicleState,
        database: VehicleDatabase,
        imageCache: CarImageCache,
        reverseGeocoder: ReverseGeocoder,
        onRefresh: @escaping () -> Void = {},
        onNavigateToHistory: @escaping () -> Void = {}
    ) {
        self.state = state
        self.database = database
        self.imageCache = imageCache
        self.reverseGeocoder = reverseGeocoder
        self.onRefresh = onRefresh
        self.onNavigateToHistory = onNavigateToHistory
    }

    /// Everything the Info tab derives from the local SQLite store. Loaded once per VIN on a
    /// detached task so no card touches the database from inside `body` (which re-runs on every
    /// scroll / state change).
    struct InfoAsyncData: Sendable {
        var recentTelemetry: [HistoricalTelemetryRecord] = []
        var recentCommands: [RemoteCommandAuditRecord] = []
        var airQualityHistory: [AirQualityRecord] = []
        var connectivityHistory: [VehicleDatabase.ConnectivityRecord] = []
        var chargingSessions: [ChargingSession] = []
        var batteryHealthHistory: [BatteryHealthRecord] = []
    }

    /// Stable identity + ordering for every card, so the "jump to section" menu and the render
    /// loop derive from one list instead of two hand-synced copies.
    enum InfoSection: String, CaseIterable, Hashable {
        case overview, doors, tyres, fluids, errors, software, location, weather
        case trip, powertrain, batteryHealth, batteryDiagnostics, airQuality
        case connectivity, service, warranty, exterior, interior, chargeLocations
        case factoryBuild, capabilities, activity

        var title: String {
            switch self {
            case .overview: return L10n.text("Overview")
            case .doors: return L10n.text("Doors & Openings")
            case .tyres: return L10n.text("Tyres")
            case .fluids: return L10n.text("Fluids & Lighting")
            case .errors: return L10n.text("Vehicle Errors")
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
            }
        }
    }

    struct InfoSectionEntry: Identifiable {
        let id: InfoSection
        let view: AnyView
    }

    var availableExteriorAngles: [CarRenderAngle] {
        CarRenderAngle.allCases.filter { angle in
            imageCache.hasImage(for: state.vin, angle: angle.rawValue)
                || (angle == preferences.carRenderAngle && state.imageData != nil)
        }
    }

    var body: some View {
        let entries = makeSections()
        return ScrollViewReader { proxy in
            VStack(spacing: HisingenTheme.sectionSpacing) {
                infoNavBar(proxy: proxy, entries: entries)
                ForEach(entries) { entry in
                    entry.view.id(entry.id)
                }
            }
            .dynamicTypeSize(.xSmall ... .accessibility1)
            .onAppear {
                let preferred = preferences.carRenderAngle
                selectedAngleIndex = availableExteriorAngles.contains(preferred)
                    ? preferred.rawValue
                    : (availableExteriorAngles.first?.rawValue ?? selectedAngleIndex)
            }
            .task(id: state.vin) { await loadAsyncData() }
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
            out.append(InfoSectionEntry(id: id, view: AnyView(view)))
        }

        add(.overview, heroVisualSection)

        if let ext = state.exteriorStatus, !ext.openings.isEmpty {
            add(.doors, DoorsAndOpeningsCardView(ext: ext, isLocked: ext.isLocked))
        }
        if let tyres = state.healthDetails?.tyres, !tyres.isEmpty {
            add(.tyres, TireStatusCardView(tyres: tyres))
        }
        add(.fluids, fluidsAndLightingCard)
        if !state.vehicleErrors.isEmpty {
            add(.errors, vehicleErrorsCard)
        }
        if softwareCardHasContent {
            add(.software, softwareUpdateCard)
        }
        if state.location?.latitude != nil {
            add(.location, parkingLocationCard)
        }
        if weatherCardHasContent {
            add(.weather, ambientWeatherCard)
        }
        if state.tripMeterManualKm != nil || state.tripMeterAutomaticKm != nil || state.averageSpeedKmH != nil {
            add(.trip, tripComputerCard)
        }
        add(.powertrain, powertrainSpecsCard)
        if batteryHealthEstimate != nil {
            add(.batteryHealth, batteryHealthCard)
        }
        if !batteryDiagnosticsRows.isEmpty {
            add(.batteryDiagnostics, batteryDiagnosticsCard)
        }
        if state.airQuality != nil {
            add(.airQuality, airQualityCleanZoneCard)
        }
        if state.connectivity?.wakeReason != nil || state.connectivity?.networkType != nil {
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
        if !asyncData.recentTelemetry.isEmpty || !asyncData.recentCommands.isEmpty {
            add(.activity, activityHistoryCard)
        }
        return out
    }

    private func infoNavBar(proxy: ScrollViewProxy, entries: [InfoSectionEntry]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: state.isStale() ? "moon.stars.fill" : "clock.arrow.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(state.isStale() ? HisingenTheme.semanticWarning : Color.secondary.opacity(0.7))
                .accessibilityHidden(true)
            Text(state.isCachedSnapshot ? L10n.text("Showing an offline copy") : state.freshnessDescription)
                .font(.system(size: 10.5, weight: state.isStale() ? .semibold : .regular))
                .foregroundStyle(state.isStale() ? HisingenTheme.semanticWarning : Color.secondary.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            Menu {
                ForEach(entries) { entry in
                    Button(entry.id.title) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(entry.id, anchor: .top)
                        }
                    }
                }
            } label: {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
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
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n.text("Vehicle report"))
            .accessibilityLabel(L10n.text("Vehicle report"))

            Button {
                guard !isRefreshing else { return }
                isRefreshing = true
                onRefresh()
                Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    isRefreshing = false
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(
                        isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                        value: isRefreshing
                    )
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .help(L10n.text("Refresh now"))
            .accessibilityLabel(L10n.text("Refresh now"))
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
        let vin = state.vin
        let db = database
        let capacity = preferences.vehicleSpecificationOverride(for: vin)?.usableBatteryCapacityKwh
            ?? state.configuredUsableBatteryCapacityKwh
        let loaded = await Task.detached(priority: .userInitiated) { () -> InfoAsyncData in
            var d = InfoAsyncData()
            d.recentTelemetry = db.recentTelemetry(for: vin, limit: 40)
            d.recentCommands = db.recentCommandAudits(for: vin, limit: 5)
            d.airQualityHistory = db.recentAirQuality(for: vin, limit: 500)
            d.connectivityHistory = db.recentConnectivity(for: vin, limit: 60)
            d.batteryHealthHistory = db.batteryHealthHistory(for: vin)
            d.chargingSessions = db.recentChargingSessions(for: vin, limit: 20)
                .map { $0.toDomainSession(database: db, usableCapacityKwh: capacity) }
                .filter { $0.percentageAdded > 0 && $0.kwhDelivered > 0 }
            return d
        }.value
        guard !Task.isCancelled else { return }
        asyncData = loaded
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
        state.daysToService != nil
            || (state.engineHoursToService ?? 0) > 0
            || (state.preferredWorkshopName?.isEmpty == false)
            || (state.preferredWorkshopId?.isEmpty == false)
    }

    private var exteriorCardHasContent: Bool {
        (state.externalColour?.isEmpty == false)
            || (state.wheels?.isEmpty == false)
            || ((state.exteriorStatus?.physicalDoorCount ?? 0) > 0)
            || !state.packages.isEmpty
    }

    private var interiorCardHasContent: Bool {
        (state.upholstery?.isEmpty == false)
            || (state.formattedSteeringOrientation?.isEmpty == false)
            || state.climateStatus != nil
    }

    var savedChargeLocations: [ChargeLocationSnapshot] {
        state.chargeLocations.filter { $0.isSavedLocation || !$0.alias.isEmpty }
    }

    private var softwareCardHasContent: Bool {
        guard let sw = state.softwareInfo else { return false }
        return (sw.installedVersion?.isEmpty == false)
            || (sw.version?.isEmpty == false)
            || (sw.latestAvailableVersion?.isEmpty == false)
            || sw.state != .unknown
            || sw.scheduledAt != nil
    }

    var batteryHealthEstimate: BatteryHealthEstimate? {
        let previous = asyncData.batteryHealthHistory.first
            .map { BatteryHealthPriorEstimate(stateOfHealthPercent: $0.stateOfHealthPct, timestamp: $0.timestamp) }
        return BatteryHealthEstimator.estimate(
            state: state,
            chargingSessions: asyncData.chargingSessions,
            specification: preferences.vehicleSpecificationOverride(for: state.vin),
            previous: previous
        )
    }

    // MARK: - Chart & geo helpers

    func headingToCardinal(_ heading: Double) -> String {
        let normalized = (heading.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"].map { L10n.text($0) }
        let index = Int(((normalized + 22.5) / 45.0).truncatingRemainder(dividingBy: 8))
        return directions[index]
    }

    func chartAccessibilityValue(points: [Double]) -> String {
        guard let first = points.first, let last = points.last, !points.isEmpty else {
            return L10n.text("No samples")
        }
        let lo = Int((points.min() ?? first).rounded())
        let hi = Int((points.max() ?? first).rounded())
        let latest = Int(last.rounded())
        let trendKey = last > first ? "rising" : (last < first ? "falling" : "steady")
        return L10n.format("%d samples, latest %d, range %d to %d, %@",
                           points.count, latest, lo, hi, L10n.text(trendKey))
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

        row(L10n.text("Model"), [state.modelName, state.modelYear].compactMap { $0 }.joined(separator: " "))
        row(L10n.text("VIN"), redacted
            ? String(repeating: "•", count: max(0, state.vin.count - 4)) + state.vin.suffix(4)
            : state.vin)
        if !redacted { row(L10n.text("Registration"), state.registrationNo) }
        row(L10n.text("Vehicle ID"), state.internalVehicleIdentifier)
        row(L10n.text("Architecture"), state.powertrain.displayName)
        if let odo = state.odometerKm {
            row(L10n.text("Odometer"), Format.distance(km: odo, grouped: true, unit: preferences.distanceUnit))
        }
        if let battery = state.batteryPercentage {
            row(L10n.text("Battery"), String(format: "%.0f%%", battery))
        }
        if let range = state.primaryRangeKm {
            row(L10n.text("Range"), Format.distance(km: range, unit: preferences.distanceUnit))
        }
        if state.powertrain.hasElectricRange {
            row(L10n.text("Charging"), state.chargingState.displayName)
            if let target = state.chargeTargetPercentage {
                row(L10n.text("Charge Target"), "\(target)%")
            }
        }
        row(L10n.text("Exterior Paint"), state.externalColour)
        row(L10n.text("Wheels"), state.wheels)
        row(L10n.text("Interior Trim"), state.upholstery)
        if !state.packages.isEmpty {
            row(L10n.text("Factory Packages"), state.packages.joined(separator: ", "))
        }
        row(L10n.text("Factory Build Week"), state.formattedBuildWeek ?? state.structureWeek)
        row(L10n.text("Factory Spec (PNO34)"), state.pno34)
        row(L10n.text("Market Delivery"), state.accountMarket)
        row(L10n.text("Backend-Reported Software"), state.softwareInfo?.installedVersion ?? state.softwareInfo?.version)

        if let days = state.daysToService {
            row(L10n.text("Service Due"), L10n.format("in %d days", days))
        }
        if let inService = preferences.warrantyInServiceDate(for: state.vin) {
            row(L10n.text("In-Service Date"), Format.dateFormatter.string(from: inService))
        }
        if let warranty = state.warrantyInfo?.factoryWarrantyValidUntil {
            row(L10n.text("Manufacturer Warranty"), Format.dateFormatter.string(from: warranty))
        }

        if let estimate = batteryHealthEstimate {
            lines.append("")
            row(L10n.text("Calculated SoH"), String(format: "%.1f%% (%@)", estimate.stateOfHealthPercent, estimate.confidence.displayName))
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
        panel.nameFieldStringValue = "vehicle_report_\(state.vin.prefix(8)).txt"
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
