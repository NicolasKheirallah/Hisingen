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
        history: HistoryWorkspace,
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
                VehicleChargingCard(state: state, history: history)

            case .vehicleChargingPlanner, .controlsChargingPlanner:
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
                ComposableReceiptsCard(state: state, onDismiss: onDismissCommandReceipt,
                                       onVerify: { _ in onRefresh() })

            case .vehicleAttention:
                ComposableAttentionCard(state: state, error: error, onRefresh: onRefresh)

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

/// Reports upward whether a card-reorder drag owns the pointer. The panel's scroll
/// container reads this so its own drag coordinator stands down: the same movement is
/// both a card being dragged and, to a coordinator that does not know, a page swipe or
/// a pull waiting to commit.
struct ReorderDragActiveKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// One live card-reorder drag. The card tracks the pointer one-to-one from wherever on it
/// the handle took hold, sibling cards part as it crosses them ("put this where that is"),
/// and release settles it into the slot the move created on the flick spring. Replaces the
/// `onDrag`/`DropDelegate` pair, whose system drag image was a snapshot of the card rather
/// than the card: nothing under the pointer, no continuity, no settle.
struct ReorderDrag: Equatable {
    let item: TabItemID
    /// Pointer position in global coordinates at the latest event.
    var pointer: CGPoint
    /// Where the pointer sat inside the card at grab time, so the card stays glued to the
    /// point that took hold of it instead of snapping its corner to the pointer.
    let grabOffset: CGSize
}

/// A tab the reader built, drawn from the cards they placed on it.
@MainActor
struct TabCardStack: View {
    let tab: TabRef
    let state: VehicleState
    let preferences: PreferencesStore
    let history: HistoryWorkspace
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

    /// Bumped after every drag move so the stack re-reads the composition. The preferences
    /// store is unobserved by design, and a pure reorder changes no feature membership, so
    /// the reflow is local: persistence is the defaults write, the re-render is this pulse.
    @State private var reorderPulse = 0
    /// The live reorder drag, if any.
    @State private var reorder: ReorderDrag?
    /// The layout origin the dragged card's offset is computed against. Rebased to the
    /// target card's origin at each live move, so the card stays glued to the pointer
    /// through the reflow instead of jumping by the slot distance for one refresh.
    @State private var reorderBaseline: CGPoint?
    /// The last card a move targeted, so hovering across one boundary cannot rewrite the
    /// composition on every event between the move and the next frame.
    @State private var lastReorderTarget: TabItemID?
    /// Every placed card's layout frame in global coordinates. Measurement, not drag
    /// state: the offsets below are transforms, so these frames stay the resting layout
    /// the crossing math and the pointer glue are computed against.
    @State private var cardFrames: [TabItemID: CGRect] = [:]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var composition: TabComposition { preferences.tabComposition }

    private var placed: [TabItemID] {
        _ = reorderPulse
        return composition.visibleItems(for: tab).filter { ComposableCards.isReusable($0) }
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
                    history: history,
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
                // Attached before the drag transforms, so what it reports is the resting
                // layout, never the card's own offset.
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    cardFrames[item] = frame
                    if reorder?.item == item { reorderBaseline = frame.origin }
                }
                .overlay(alignment: .topTrailing) {
                    CardDragHandle(
                        item: item,
                        isActive: reorder?.item == item,
                        dragStarted: { startReorder(item, at: $0) },
                        dragChanged: { moveReorder(to: $0) },
                        dragEnded: { endReorder() }
                    )
                    .padding(4)
                }
                .scaleEffect(reorder?.item == item ? 1.02 : 1)
                .offset(reorderOffset(for: item))
                .zIndex(reorder?.item == item ? 1 : 0)
                .accessibilityAction(named: L10n.text("Move Up")) { moveItem(item, slots: -1) }
                .accessibilityAction(named: L10n.text("Move Down")) { moveItem(item, slots: 1) }
            }

            if placed.isEmpty { emptyCard }
            if !tabOwned.isEmpty { tabOwnedCard }
        }
        .hisAnimation(Motion.cardChange, value: placed)
        .preference(key: ReorderDragActiveKey.self, value: reorder != nil)
    }

    private func startReorder(_ item: TabItemID, at pointer: CGPoint) {
        guard let origin = cardFrames[item]?.origin else { return }
        lastReorderTarget = item
        reorderBaseline = origin
        reorder = ReorderDrag(
            item: item,
            pointer: pointer,
            grabOffset: CGSize(width: pointer.x - origin.x, height: pointer.y - origin.y)
        )
    }

    private func moveReorder(to pointer: CGPoint) {
        guard var drag = reorder else { return }
        drag.pointer = pointer
        reorder = drag
        guard let frame = cardFrames[drag.item] else { return }
        let centerY = pointer.y - drag.grabOffset.height + frame.height / 2
        guard let target = Self.reorderTarget(of: drag.item, center: centerY, in: cardFrames),
              target != lastReorderTarget,
              let slot = cardFrames[target]?.origin else { return }
        lastReorderTarget = target
        var updated = composition
        updated.move(drag.item, onto: target, in: tab)
        preferences.tabComposition = updated
        // The dragged card takes the target's place, so the target's origin is where its
        // offset is computed from until the measured frame confirms it.
        reorderBaseline = slot
        reorderPulse += 1
    }

    /// The non-visual reorder route: one slot at a time through the same move the drag
    /// performs. The drag handle stays pointer-only; this is its keyboard/VoiceOver twin.
    private func moveItem(_ item: TabItemID, slots: Int) {
        let order = placed
        guard let index = order.firstIndex(of: item) else { return }
        let neighbor = index + slots
        guard order.indices.contains(neighbor) else { return }
        var updated = composition
        updated.move(item, onto: order[neighbor], in: tab)
        preferences.tabComposition = updated
    }

    private func endReorder() {
        guard reorder != nil else { return }
        // The card settles into the slot the moves created, on the spring reserved for
        // motion a gesture threw. Reduce Motion places it without the settle.
        withAnimation(reduceMotion ? nil : Motion.flick) {
            reorder = nil
            reorderBaseline = nil
            lastReorderTarget = nil
        }
    }

    private func reorderOffset(for item: TabItemID) -> CGSize {
        guard let drag = reorder, drag.item == item,
              let frame = cardFrames[item] else { return .zero }
        let origin = reorderBaseline ?? frame.origin
        return CGSize(width: drag.pointer.x - drag.grabOffset.width - origin.x,
                      height: drag.pointer.y - drag.grabOffset.height - origin.y)
    }

    /// The card the dragged card's centre is over: the one whose frame contains it, else
    /// the nearest by midline. Pure so the crossing rule is testable without a view.
    static func reorderTarget(
        of dragged: TabItemID,
        center: CGFloat,
        in frames: [TabItemID: CGRect]
    ) -> TabItemID? {
        var nearest: (item: TabItemID, distance: CGFloat)?
        for (item, frame) in frames where item != dragged {
            if center >= frame.minY, center <= frame.maxY { return item }
            let distance = abs(center - frame.midY)
            if nearest == nil || distance < nearest!.distance { nearest = (item, distance) }
        }
        return nearest?.item
    }

    private var emptyCard: some View {
        Card {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.dashed")
                    .hisSymbolSize(22)
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
                Text(L10n.text("They own the state of the tab they came from: a period to chart, a section list to scroll. Open that tab to see them."))
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

/// The drag handle overlaying a reorderable card: appears on hover at the card's top-right,
/// and is the only place a drag can start, so the card's own controls keep every click.
@MainActor
private struct CardDragHandle: View {
    let item: TabItemID
    /// Whether this handle's drag is live, which keeps the gesture's `onChanged` feeding
    /// the stack rather than starting a second drag on every event.
    let isActive: Bool
    let dragStarted: (CGPoint) -> Void
    let dragChanged: (CGPoint) -> Void
    let dragEnded: () -> Void
    @State private var hovered = false

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .hisType(.micro, weight: .medium)
            .foregroundStyle(hovered ? HisingenTheme.inkMuted : Color.secondary)
            .padding(6)
            .contentShape(Rectangle())
            .opacity(hovered ? 1 : 0)
            .onHover { hovered = $0 }
            .gesture(
                // A SwiftUI drag keeps reporting after the pointer leaves the handle, so
                // the small handle can start a drag that tracks the whole panel.
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        if isActive {
                            dragChanged(value.location)
                        } else {
                            dragStarted(value.location)
                        }
                    }
                    .onEnded { _ in dragEnded() }
            )
            .help(L10n.text("Drag to reorder"))
            // Hidden because the drag itself is pointer-only; the card carries named
            // Move Up / Move Down actions as the non-visual equivalent.
            .accessibilityHidden(true)
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
                    CardHeader(symbol: "car.side.lock", title: L10n.text("Doors & Openings"), color: HisingenTheme.chartInfo)
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
    var onVerify: ((UUID) -> Void)? = nil

    var body: some View {
        let receipts = state.commandState.receipts
        if !receipts.isEmpty {
            VStack(spacing: HisingenTheme.sectionSpacing) {
                ForEach(Array(receipts.reversed()), id: \.id) { receipt in
                    CommandReceiptChip(receipt: receipt, onDismiss: onDismiss, onVerify: onVerify)
                }
            }
        }
    }
}

@MainActor
private struct ComposableAttentionCard: View {
    let state: VehicleState
    let error: String?
    let onRefresh: () -> Void

    var body: some View {
        let items = (error.map { [$0] } ?? []) + state.freshness.dataWarnings
        if !items.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    CardHeader(symbol: "exclamationmark.triangle.fill", title: L10n.text("Attention"),
                               color: HisingenTheme.semanticWarning, isSemantic: true)
                    ForEach(items, id: \.self) { Text("• \($0)").hisType(.label).foregroundStyle(.secondary) }
                    Button(L10n.text("Refresh")) { onRefresh() }
                        .buttonStyle(.pressable)
                        .hisType(.label, weight: .semibold)
                        .foregroundStyle(HisingenTheme.accent)
                        .help(L10n.text("Reload the vehicle state"))
                        .accessibilityLabel(L10n.text("Refresh"))
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
                                        .matchedGeometryEffect(id: "garageChipSelection", in: namespace)
                                } else {
                                    HoverChipFill(shape: Capsule(), resting: 0.04)
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
