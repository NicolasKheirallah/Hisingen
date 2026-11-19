import SwiftUI

@MainActor
struct VehicleTabView: View {

    /// The reader's layout for this tab: what to draw, and in what order. The default draws
    /// everything exactly as designed.
    var layout: TabLayout = .everything

    func draws(_ item: TabItemID) -> Bool { layout.draws(item) }

    let state: VehicleState
    let cars: [CarSummary]
    let activeVin: String?
    let brand: VehicleBrand
    let remoteCommandInProgress: Bool
    let inFlightCommandID: String?
    var feedback: RemoteCommandFeedback? = nil
    var onAuthorizeRemoteCommands: (() -> Void)? = nil
    let onRemoteCommand: (RemoteCommand) -> Void
    let onSelectCar: (String) -> Void
    let onDismissCommandReceipt: (UUID) -> Void
    /// Re-reads the vehicle so an acknowledged command receipt can settle against fresh
    /// telemetry. Optional: tabs without a refresh action simply omit the Verify button.
    var onVerifyReceipt: ((UUID) -> Void)? = nil
    let error: String?
    let history: HistoryWorkspace
    let reverseGeocoder: ReverseGeocoder
    let imageCache: CarImageCache
    var onRefresh: (() -> Void)? = nil
    var onOpenPlan: ((TabItemID) -> Void)? = nil
    var onOpenCar: ((TabItemID) -> Void)? = nil
    var onOpenSession: ((String) -> Void)? = nil

    @Environment(\.preferencesStore) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.homeCharging) private var homeCharging
    @State private var dismissedSoftwareEventIdentifier: String?

    private var features: FeatureSelection { preferences.features }
    private var cardChangeAnimation: Animation? { reduceMotion ? nil : Motion.cardChange }
    private var cardTransition: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity)
    }
    private var warningsSignature: String {
        "\(error ?? "")|\(state.freshness.dataWarnings.joined())|\(displayedStateSummary.message)"
    }
    private var pillSignature: String {
        "\(String(describing: state.exteriorStatus?.isLocked))|\(state.energy.chargingState.displayName)|\(String(describing: state.climateStatus?.activity))|\(String(describing: state.fuelSystem.isEngineRunning))|\(String(describing: state.fuelSystem.levelPercent))"
    }
    /// Inputs of the smart-charging-planner presence guard, so the declared
    /// card transition actually fires when a threshold is crossed.
    private var plannerSignature: String {
        "\(preferences.smartChargingPlannerAvailable)|\(state.powertrain.hasElectricRange)|\(String(describing: state.energy.batteryPercentage))|\(String(describing: state.energy.targetPercentage))"
    }
    private var displayedStateSummary: VehicleStateSummary {
        if let software = state.softwareInfo, software.hasActionableFailure(),
           dismissedSoftwareEventIdentifier == software.eventIdentifier,
           state.stateSummary.message == L10n.text("Software update failed") {
            return VehicleStateSummary(message: L10n.text("Software event dismissed locally"), severity: .neutral)
        }
        return state.stateSummary
    }

    private var combinesAttention: Bool {
        if usesCompactNow || !draws(.vehicleAttention) || !draws(.vehicleExceptions) { return false }
        let items = layout.items
        guard let index = items.firstIndex(of: .vehicleAttention) else { return layout.isDefault }
        return items.dropFirst(index + 1).first == .vehicleExceptions
    }

    private var usesCompactNow: Bool { layout.includesNewItems && draws(.vehicleHero) }

    var body: some View {
        let twoColumns = preferences.wideCardLayout == .twoColumns
            && HisingenTheme.layoutWidth >= 500 && !typeSize.isAccessibilitySize
        let rows = Self.cardRows(layout: layout, features: features, twoColumns: twoColumns)
        VStack(spacing: HisingenTheme.sectionSpacing) {
            if usesCompactNow {
                let overview: Set<TabItemID> = [
                    .vehicleSwitcher, .vehicleHero, .vehicleReadiness, .vehicleReceipts, .vehicleAttention
                ]
                cardStack(rows.filter { row in row.first.map(overview.contains) == true })
                let details = rows.compactMap { row -> [TabItemID]? in
                    let items = row.filter { !overview.contains($0) && hasSecondaryContent($0) }
                    return items.isEmpty ? nil : items
                }
                if !details.isEmpty {
                    DisclosureGroup {
                        cardStack(details)
                            .padding(.top, HisingenTheme.sectionSpacing)
                    } label: {
                        Text(L10n.text("Vehicle details"))
                            .hisType(.body, weight: .medium)
                            .foregroundStyle(HisingenTheme.ink)
                    }
                    .disclosureGroupStyle(WholeRowDisclosureStyle())
                    .padding(.horizontal, HisingenTheme.cardPadding)
                }
            } else {
                cardStack(rows)
            }
        }
        .animation(cardChangeAnimation, value: warningsSignature)
        .animation(cardChangeAnimation, value: pillSignature)
        .animation(cardChangeAnimation, value: state.commandState.receipts.map(\.id))
        .animation(cardChangeAnimation, value: plannerSignature)
        .task(id: state.identity.vin) {
            dismissedSoftwareEventIdentifier = preferences.dismissedSoftwareEventIdentifier(for: state.identity.vin)
        }
    }

    private func cardStack(_ rows: [[TabItemID]]) -> some View {
        ForEach(rows, id: \.first) { row in
            if row.count == 2 {
                HStack(alignment: .top, spacing: HisingenTheme.sectionSpacing) {
                    ForEach(row, id: \.self) { item in
                        card(item).frame(maxWidth: .infinity)
                    }
                }
                .transition(cardTransition)
            } else if let item = row.first {
                card(item)
            }
        }
    }

    private func hasSecondaryContent(_ item: TabItemID) -> Bool {
        switch item {
        case .vehicleWeather:
            return false
        case .vehicleExceptions:
            return !ExceptionsCard.attentionRows(state: state, features: features,
                                                dismissedSoftwareEventIdentifier: dismissedSoftwareEventIdentifier).isEmpty
        case .vehicleOpenings:
            return features.contains(.exteriorStatus) && state.exteriorStatus?.openings.isEmpty == false
        case .vehicleLocation:
            return state.location?.latitude != nil && state.location?.longitude != nil
        case .vehicleCharging:
            return state.powertrain.hasElectricRange
                && (features.contains(.chargingDetails) || features.contains(.batteryDiagnostics))
        case .vehicleHomeCharger:
            return homeCharging?.cardInput(for: state) != nil
        default:
            return TabItemAvailability.of(item, state: state, enabledFeatures: features.enabled,
                                          plannerAvailable: preferences.smartChargingPlannerAvailable) == .drawable
        }
    }

    static func cardRows(layout: TabLayout, features: FeatureSelection, twoColumns: Bool) -> [[TabItemID]] {
        let nowItems = TabItemCatalog.nowInlineItems
        let orderedItems = layout.includesNewItems
            ? TabItemCatalog.defaultItems(for: .vehicle) + layout.items.filter {
                nowItems.contains($0) && !TabItemCatalog.defaultItems(for: .vehicle).contains($0)
            }
            : layout.items.filter { nowItems.contains($0) }
        let items = layout.ordered(orderedItems, by: { $0 }).filter { item in
            guard layout.draws(item) else { return false }
            switch item {
            case .vehicleTyres, .vehicleLocation:
                return CardAvailability.of(item, enabledFeatures: features.enabled) == .drawable
            default:
                return true
            }
        }
        return items.reduce(into: [[TabItemID]]()) { rows, item in
            if twoColumns,
               (rows.last == [.vehicleTyres] && item == .vehicleLocation
                || rows.last == [.vehicleLocation] && item == .vehicleTyres) {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
    }

    @ViewBuilder
    private func card(_ item: TabItemID) -> some View {
        switch item {
        case .vehicleFuelEngine:
            if state.powertrain.hasCombustionEngine,
               let row = VehicleDashboardRows.fuel(state: state, distanceUnit: preferences.distanceUnit) {
                row.transition(cardTransition)
            }
        case .vehicleExceptions where combinesAttention:
            EmptyView()
        case .vehicleWeather where draws(.vehicleHero):
            EmptyView()
        default:
            ComposableCards.view(
                item, state: state, preferences: preferences, history: history,
                reverseGeocoder: reverseGeocoder, imageCache: imageCache, brand: brand,
                cars: cars, activeVin: activeVin, error: error,
                remoteCommandInProgress: remoteCommandInProgress, inFlightCommandID: inFlightCommandID,
                onRefresh: onRefresh, onRemoteCommand: onRemoteCommand, onSelectCar: onSelectCar,
                onDismissCommandReceipt: onDismissCommandReceipt, onVerifyReceipt: onVerifyReceipt,
                feedback: feedback, onAuthorizeRemoteCommands: onAuthorizeRemoteCommands,
                onOpenPlan: onOpenPlan, onOpenCar: onOpenCar, onOpenSession: onOpenSession,
                compact: true, repeatsDisconnectedStatus: !draws(.vehicleHero),
                showsExceptions: item == .vehicleHero ? draws(.vehicleExceptions) : combinesAttention,
                showsCommandReceipts: draws(.vehicleReceipts),
                showsWeatherIcon: draws(.vehicleWeather),
                usesCompactNow: usesCompactNow,
                dismissedSoftwareEventIdentifier: dismissedSoftwareEventIdentifier
            )
            .transition(cardTransition)
        }
    }
}
