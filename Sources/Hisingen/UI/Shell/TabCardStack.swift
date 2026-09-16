import AppKit
import SwiftUI

/// The cards a reader can place on a tab of their own, drawn by the same views the shipped
/// tabs use.
///
/// Membership is a real constraint, not a preference: a card is here only when it draws purely
/// from the vehicle snapshot, the reader's preferences, and the shared command gate. Cards that
/// own a tab's own state — the History period picker and its charts, the Info section bars —
/// belong to the tab that gives them that state and stay there. The Settings pane names them so
/// the omission is visible rather than mysterious.
@MainActor
enum ComposableCards {
    static let reusable: Set<TabItemID> = [
        .vehicleSwitcher,
        .vehicleHero,
        .vehicleCharging,
        .vehicleChargingPlanner,
        .vehicleOpenings,
        .vehicleTyres,
        .vehicleReadiness,
        .vehicleLocation,
        .vehicleReceipts,
        .vehicleAttention,
        .controlsClimate,
        .controlsAccess,
        .controlsWindowsLocate,
        .controlsOTA
    ]

    static func isReusable(_ item: TabItemID) -> Bool { reusable.contains(item) }

    @ViewBuilder
    static func view(
        _ item: TabItemID,
        state: VehicleState,
        preferences: PreferencesStore,
        database: VehicleDatabase,
        reverseGeocoder: ReverseGeocoder,
        imageCache: CarImageCache,
        brand: VehicleBrand,
        cars: [CarSummary],
        activeVin: String?,
        error: String?,
        remoteCommandInProgress: Bool,
        inFlightCommandID: String?,
        onRefresh: @escaping () -> Void,
        onRemoteCommand: @escaping (RemoteCommand) -> Void,
        onSelectCar: @escaping (String) -> Void,
        onDismissCommandReceipt: @escaping (UUID) -> Void
    ) -> some View {
        // A card whose data the reader switched off must not draw, and must not start work:
        // the planner's `.task` fetches spot prices. One declared rule, consulted in one place.
        if CardAvailability.of(item, enabledFeatures: preferences.features.enabled) == .drawable {
            switch item {
            case .vehicleSwitcher:
                GarageChipStrip(cars: cars, activeVin: activeVin, brand: brand, onSelectCar: onSelectCar)

            case .vehicleHero:
                VehicleHeroCard(state: state, displayedStateSummary: state.stateSummary, imageCache: imageCache)

            case .vehicleCharging:
                VehicleChargingCard(state: state, database: database)

            case .vehicleChargingPlanner:
                ChargingPlannerCard(state: state)

            case .vehicleOpenings:
                ComposableOpeningsCard(state: state)

            case .vehicleTyres:
                ComposableTyresCard(state: state)

            case .vehicleReadiness:
                VehicleReadinessCard(state: state, lowBatteryThreshold: preferences.lowBatteryThreshold)

            case .vehicleLocation:
                ComposableLocationCard(state: state, reverseGeocoder: reverseGeocoder)

            case .vehicleReceipts:
                ComposableReceiptsCard(state: state, onDismiss: onDismissCommandReceipt)

            case .vehicleAttention:
                ComposableAttentionCard(state: state, error: error)

            case .controlsClimate:
                ClimateControlCard(state: state, gate: gate(state, preferences, brand, remoteCommandInProgress,
                                                             inFlightCommandID, onRemoteCommand),
                                   onShowSchedule: { _ in })

            case .controlsAccess:
                AccessControlsCard(state: state, gate: gate(state, preferences, brand, remoteCommandInProgress,
                                                            inFlightCommandID, onRemoteCommand))

            case .controlsWindowsLocate:
                WindowsLocateCard(state: state, gate: gate(state, preferences, brand, remoteCommandInProgress,
                                                           inFlightCommandID, onRemoteCommand))

            case .controlsOTA:
                OTAControlsCard(state: state, gate: gate(state, preferences, brand, remoteCommandInProgress,
                                                         inFlightCommandID, onRemoteCommand),
                                onRefresh: onRefresh)

            default:
                EmptyView()
            }
        }
    }

    private static func gate(
        _ state: VehicleState,
        _ preferences: PreferencesStore,
        _ brand: VehicleBrand,
        _ remoteCommandInProgress: Bool,
        _ inFlightCommandID: String?,
        _ onRemoteCommand: @escaping (RemoteCommand) -> Void
    ) -> ControlsCommandGate {
        ControlsCommandGate(
            state: state,
            brand: brand,
            preferences: preferences,
            remoteCommandInProgress: remoteCommandInProgress,
            inFlightCommandID: inFlightCommandID,
            onRemoteCommand: onRemoteCommand
        )
    }
}

/// A tab the reader built, drawn from the cards they placed on it.
@MainActor
struct TabCardStack: View {
    let tab: TabRef
    let state: VehicleState
    let preferences: PreferencesStore
    let database: VehicleDatabase
    let reverseGeocoder: ReverseGeocoder
    let imageCache: CarImageCache
    let cars: [CarSummary]
    let activeVin: String?
    let error: String?
    let remoteCommandInProgress: Bool
    let inFlightRemoteCommandID: String?
    let onRefresh: () -> Void
    let onRemoteCommand: (RemoteCommand) -> Void
    let onSelectCar: (String) -> Void
    let onDismissCommandReceipt: (UUID) -> Void

    private var composition: TabComposition { preferences.tabComposition }

    private var placed: [TabItemID] {
        composition.visibleItems(for: tab).filter { ComposableCards.isReusable($0) }
    }

    /// Cards the reader placed that belong to the tab they came from.
    private var tabOwned: [TabItemID] {
        composition.visibleItems(for: tab).filter { !ComposableCards.isReusable($0) }
    }

    var body: some View {
        VStack(spacing: HisingenTheme.sectionSpacing) {
            ForEach(placed, id: \.self) { item in
                ComposableCards.view(
                    item,
                    state: state,
                    preferences: preferences,
                    database: database,
                    reverseGeocoder: reverseGeocoder,
                    imageCache: imageCache,
                    brand: preferences.activeBrand,
                    cars: cars,
                    activeVin: activeVin,
                    error: error,
                    remoteCommandInProgress: remoteCommandInProgress,
                    inFlightCommandID: inFlightRemoteCommandID,
                    onRefresh: onRefresh,
                    onRemoteCommand: onRemoteCommand,
                    onSelectCar: onSelectCar,
                    onDismissCommandReceipt: onDismissCommandReceipt
                )
                .transition(.opacity)
            }

            if placed.isEmpty { emptyCard }
            if !tabOwned.isEmpty { tabOwnedCard }
        }
        .hisAnimation(Motion.cardChange, value: placed)
    }

    private var emptyCard: some View {
        Card {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(L10n.text("Nothing on this tab yet"))
                    .hisType(.heading, weight: .semibold)
                Text(L10n.text("Add cards to this tab in Settings → Tabs & Cards. Everything you add is the same card the other tabs draw."))
                    .hisType(.label)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }

    /// Cards that belong to the tab they came from, named rather than silently dropped, so the
    /// tab cannot quietly disagree with Settings about what is on it.
    private var tabOwnedCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                CardHeader(symbol: "info.circle", title: L10n.text("These cards stay on their own tab"),
                           color: .secondary)
                Text(L10n.text("They own the state of the tab they came from — a period to chart, a section list to scroll. Open that tab to see them."))
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(tabOwned, id: \.self) { item in
                    HStack(spacing: 6) {
                        Image(systemName: TabItemCatalog.symbol(item)).hisType(.micro).foregroundStyle(.tertiary)
                        Text(TabItemCatalog.title(item)).hisType(.micro).foregroundStyle(.secondary)
                        if let source = TabItemCatalog.item(item)?.sourceTab {
                            Text(source.title).hisType(.nano).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Cards that had no standalone view before

@MainActor
private struct ComposableOpeningsCard: View {
    let state: VehicleState

    var body: some View {
        if let exterior = state.exteriorStatus, !exterior.openings.isEmpty {
            DoorsAndOpeningsCardView(
                ext: exterior,
                isLocked: exterior.isLocked,
                isTailgateLocked: exterior.isTailgateLocked,
                model: state.model
            )
        } else {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardHeader(symbol: "car.side.lock", title: L10n.text("Doors & Openings"), color: .indigo)
                    Text(state.isVolvo
                         ? L10n.text("Requires 'Connected Vehicle API' subscription on developer.volvocars.com and 'Volvo Connected Services' enabled in vehicle privacy settings.")
                         : L10n.text("No door or window state was reported on the last refresh."))
                        .hisType(.label)
                        .foregroundStyle(HisingenTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

@MainActor
private struct ComposableTyresCard: View {
    let state: VehicleState

    var body: some View {
        if let tyres = state.maintenance.details?.tyres, !tyres.isEmpty {
            TireStatusCardView(tyres: tyres, model: state.model)
        } else {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardHeader(symbol: "circle.grid.2x2", title: L10n.text("Tyre Status"), color: HisingenTheme.semanticActive)
                    Text(L10n.text("No tyre pressures or warning levels were reported on the last refresh."))
                        .hisType(.label)
                        .foregroundStyle(HisingenTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

@MainActor
private struct ComposableLocationCard: View {
    let state: VehicleState
    let reverseGeocoder: ReverseGeocoder

    var body: some View {
        if let location = state.location, let latitude = location.latitude, let longitude = location.longitude {
            LocationCardView(
                lat: latitude, lon: longitude,
                speed: location.speed, heading: location.heading,
                timestamp: location.timestamp, altitude: location.altitudeMeters,
                accuracy: location.accuracyMeters,
                parkingBrake: location.parkingBrakeEngaged, gear: location.gear,
                weather: state.weather,
                isLive: !state.hasOldData(),
                freshnessText: state.freshnessDescription,
                reverseGeocoder: reverseGeocoder
            )
        } else {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardHeader(symbol: "location.fill", title: L10n.text("Vehicle Location"), color: HisingenTheme.semanticCritical)
                    Text(state.isVolvo
                         ? L10n.text("Location requires subscribing to the Location API in developer.volvocars.com and enabling 'Share Location' in vehicle settings.")
                         : L10n.text("Parking position unavailable."))
                        .hisType(.label)
                        .foregroundStyle(HisingenTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

@MainActor
private struct ComposableReceiptsCard: View {
    let state: VehicleState
    let onDismiss: (UUID) -> Void

    var body: some View {
        let receipts = state.commandState.receipts
        if !receipts.isEmpty {
            VStack(spacing: HisingenTheme.sectionSpacing) {
                ForEach(Array(receipts.reversed()), id: \.id) { receipt in
                    CommandReceiptChip(receipt: receipt, onDismiss: onDismiss)
                }
            }
        }
    }
}

@MainActor
private struct ComposableAttentionCard: View {
    let state: VehicleState
    let error: String?

    var body: some View {
        let items = (error.map { [$0] } ?? []) + state.freshness.dataWarnings
        if !items.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    CardHeader(symbol: "exclamationmark.triangle.fill", title: L10n.text("Attention"),
                               color: HisingenTheme.semanticWarning, isSemantic: true)
                    ForEach(items, id: \.self) { Text("• \($0)").hisType(.label).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

/// The garage chip strip, so a reader with more than one car can keep the switcher wherever
/// they look for it.
@MainActor
private struct GarageChipStrip: View {
    let cars: [CarSummary]
    let activeVin: String?
    let brand: VehicleBrand
    let onSelectCar: (String) -> Void
    @Namespace private var namespace

    var body: some View {
        if cars.count > 1 {
            let currentVin = activeVin ?? cars.first?.vin ?? ""
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(cars, id: \.vin) { car in
                        let selected = car.vin == currentVin
                        Button { onSelectCar(car.vin) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: brand == .polestar ? "bolt.car.fill" : "car.fill")
                                    .hisType(.caption)
                                Text(car.title).hisType(.label, weight: selected ? .bold : .medium)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background {
                                if selected {
                                    Capsule()
                                        .fill(HisingenTheme.accent.opacity(0.12))
                                        .overlay(Capsule().stroke(HisingenTheme.accent, lineWidth: 1.2))
                                        .matchedGeometryEffect(id: "garageChipSelection", in: namespace)
                                } else {
                                    Capsule()
                                        .fill(Color.primary.opacity(0.04))
                                        .overlay(Capsule().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                                }
                            }
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }
}
