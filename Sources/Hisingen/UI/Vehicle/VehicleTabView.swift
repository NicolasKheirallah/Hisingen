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

    @Environment(\.preferencesStore) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var dismissedSoftwareEventIdentifier: String?
    @Namespace private var carChipNamespace

    private var features: FeatureSelection { preferences.features }
    private var commandGate: ControlsCommandGate {
        ControlsCommandGate(
            state: state,
            brand: brand,
            preferences: preferences,
            remoteCommandInProgress: remoteCommandInProgress,
            inFlightCommandID: inFlightCommandID,
            onRemoteCommand: onRemoteCommand
        )
    }
    private var cardChangeAnimation: Animation? { reduceMotion ? nil : Motion.cardChange }
    private var chipSelectionAnimation: Animation? { reduceMotion ? nil : Motion.selection }
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

    var body: some View {
        let twoColumns = preferences.wideCardLayout == .twoColumns
            && HisingenTheme.layoutWidth >= 500 && !typeSize.isAccessibilitySize
        let rows = Self.cardRows(layout: layout, features: features, twoColumns: twoColumns)
        VStack(spacing: HisingenTheme.sectionSpacing) {
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
        .animation(cardChangeAnimation, value: warningsSignature)
        .animation(cardChangeAnimation, value: pillSignature)
        .animation(cardChangeAnimation, value: state.commandState.receipts.map(\.id))
        .animation(cardChangeAnimation, value: plannerSignature)
        .task(id: state.identity.vin) {
            dismissedSoftwareEventIdentifier = preferences.dismissedSoftwareEventIdentifier(for: state.identity.vin)
        }
    }

    static func cardRows(layout: TabLayout, features: FeatureSelection, twoColumns: Bool) -> [[TabItemID]] {
        let items = layout.ordered(TabItemCatalog.defaultItems(for: .vehicle), by: { $0 }).filter { item in
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
        case .vehicleSwitcher:
            multiCarChips
        case .vehicleHero:
            NowInstrument(state: state, imageCache: imageCache, commandGate: commandGate,
                          feedback: feedback, onAuthorizeRemoteCommands: onAuthorizeRemoteCommands)
        case .vehicleReceipts:
            ForEach(Array(state.commandState.receipts.reversed()), id: \.id) { receipt in
                CommandReceiptChip(receipt: receipt, onDismiss: onDismissCommandReceipt,
                                   onVerify: onVerifyReceipt)
                    .transition(cardTransition)
            }
        case .vehicleAttention:
            if let card = attentionCard { card.transition(cardTransition) }
        case .vehicleExceptions:
            if let card = ExceptionsCard.make(state: state, features: features, dismissedSoftwareEventIdentifier: dismissedSoftwareEventIdentifier) {
                card.transition(cardTransition)
            }
        case .vehicleWeather:
            if features.contains(.vehicleWeather) {
                NowWeatherReadout(state: state)
            }
        case .vehicleCharging:
            VehicleChargingCard(state: state, history: history, repeatsDisconnectedStatus: !draws(.vehicleHero))
                .transition(cardTransition)
        case .vehicleChargingPlanner:
            if let card = chargingPlannerCard { card.transition(cardTransition) }
        case .vehicleFuelEngine:
            if state.powertrain.hasCombustionEngine,
               let row = VehicleDashboardRows.fuel(state: state, distanceUnit: preferences.distanceUnit) {
                row.transition(cardTransition)
            }
        case .vehicleOpenings:
            if let row = openingsRow {
                row.transition(cardTransition)
            }
        case .vehicleTyres:
            tireSchematicCard.transition(cardTransition)
        case .vehicleLocation:
            locationCard.transition(cardTransition)
        case .vehicleReadiness:
            if state.powertrain.hasElectricRange,
               features.contains(.vehicleHealth) || features.contains(.exteriorStatus) {
                DepartureCheckDisclosure(state: state)
                    .padding(.horizontal, HisingenTheme.cardPadding)
                    .transition(cardTransition)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var multiCarChips: some View {
        if cars.count > 1 {
            let currentVin = activeVin ?? cars.first?.vin ?? ""
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(cars, id: \.vin) { car in
                        let selected = car.vin == currentVin
                        Button { onSelectCar(car.vin) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: preferences.activeBrand == .polestar ? "bolt.car" : "car").hisType(.caption)
                                Text(car.title).hisType(.label, weight: selected ? .bold : .medium)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            // One shared capsule slides between chips; matched
                            // geometry requires exactly one visible source. Selection is a
                            // tinted fill only: the outline the selected chip drew said what
                            // the fill already said.
                            .background {
                                if selected {
                                    RoundedRectangle(cornerRadius: 0)
                                        .fill(HisingenTheme.accent.opacity(0.12))
                                        .matchedGeometryEffect(id: "carChipSelection", in: carChipNamespace)
                                } else {
                                    RoundedRectangle(cornerRadius: 0)
                                        .fill(Color.primary.opacity(0.04))
                                }
                            }
                        }
                        .buttonStyle(.pressable)
                    }
                }.padding(.horizontal, 2)
            }
            // The slide is keyed on the selection itself so programmatic car
            // switches move the capsule the same way a tap does.
            .animation(chipSelectionAnimation, value: currentVin)
        }
    }

    private var chargingPlannerCard: AnyView? {
        guard preferences.smartChargingPlannerAvailable, state.powertrain.hasElectricRange,
              state.energy.batteryPercentage != nil, state.energy.targetPercentage != nil else { return nil }
        return AnyView(ChargingPlannerCard(state: state))
    }

    /// The doors-and-locks row, with the availability gating the openings card carried: a
    /// missing feature or a data-less snapshot still owes the reader the explanation of *why*,
    /// which is the unavailable card's whole job.
    private var openingsRow: AnyView? {
        guard features.contains(.exteriorStatus) else { return nil }
        guard let row = VehicleDashboardRows.doors(state: state) else {
            if state.isVolvo { return AnyView(volvoUnavailableCard(symbol: "car.side.lock", title: L10n.text("Doors & Openings"), color: .indigo, message: L10n.text("Requires 'Connected Vehicle API' subscription on developer.volvocars.com and 'Volvo Connected Services' enabled in vehicle privacy settings."))) }
            return UnavailableFeatureCard.make(
                state: state, feature: .exteriorStatus, symbol: "car.side.lock",
                title: L10n.text("Doors & Openings"), color: .indigo, badge: AppFeature.exteriorStatus.title,
                message: L10n.text("No door or window state was reported on the last refresh.")
            )
        }
        return row
    }

    private var tireSchematicCard: AnyView {
        guard let tyres = state.maintenance.details?.tyres, !tyres.isEmpty else {
            if state.isVolvo { return AnyView(volvoUnavailableCard(symbol: "circle.grid.2x2", title: L10n.text("Tire Status (iTPMS)"), color: HisingenTheme.semanticActive, message: L10n.text("Requires 'Connected Vehicle API' subscription on developer.volvocars.com and vehicle driven to calibrate iTPMS sensors."))) }
            return AnyView(UnavailableFeatureCard(
                symbol: "circle.grid.2x2", title: L10n.text("Tyre Status"),
                color: HisingenTheme.semanticActive, badge: AppFeature.tyreAndWarnings.title,
                message: L10n.text("No tyre pressures or warning levels were reported on the last refresh."),
                state: state.freshness.unavailableFeatures.contains(.tyreAndWarnings) ? .unsupported : .unavailable
            ))
        }
        return AnyView(TireStatusCardView(tyres: tyres, model: state.model))
    }

    private var locationCard: AnyView {
        guard let location = state.location, let latitude = location.latitude, let longitude = location.longitude else {
            let explanation = state.isVolvo ? L10n.text("Location requires subscribing to the Location API in developer.volvocars.com and enabling 'Share Location' in vehicle settings.") : L10n.text("Parking position unavailable.")
            return AnyView(Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardHeader(symbol: "location", title: L10n.text("Vehicle Location"), color: HisingenTheme.semanticCritical)
                    HStack(spacing: 8) {
                        Image(systemName: "location.slash").hisType(.title).foregroundStyle(HisingenTheme.semanticWarning)
                        Text(explanation).hisType(.label).foregroundStyle(HisingenTheme.inkMuted)
                    }.padding(8).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 0))
                }
            })
        }
        return AnyView(LocationCardView(lat: latitude, lon: longitude, speed: location.speed, heading: location.heading, timestamp: location.timestamp, altitude: location.altitudeMeters, accuracy: location.accuracyMeters, parkingBrake: location.parkingBrakeEngaged, gear: location.gear, weather: nil, isLive: !state.hasOldData(), freshnessText: state.freshnessDescription, reverseGeocoder: reverseGeocoder))
    }

    /// A section that cannot show its data.
    ///
    /// Every cause rendered the same: `.inkMuted` at `.label` behind a 3 % wash, which is the
    /// weakest content on the surface, so a total provider failure was presented with less emphasis
    /// than a fluid flag. An error now reads as an error and offers the one action that might help.
    private func volvoUnavailableCard(
        symbol: String,
        title: String,
        color: Color,
        message: String,
        isError: Bool = false,
        onRetry: (() -> Void)? = nil
    ) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: symbol, title: title, color: color)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: isError ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .hisType(.heading)
                        .foregroundStyle(isError ? HisingenTheme.semanticCritical : HisingenTheme.semanticWarning)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message)
                            .hisType(.label, weight: isError ? .semibold : .regular)
                            .foregroundStyle(isError ? HisingenTheme.ink : HisingenTheme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        if let onRetry {
                            Button(L10n.text("Try Again"), action: onRetry)
                                .buttonStyle(.hisSecondary)
                                .controlSize(.small)
                        }
                    }
                }
                .padding(8)
                .background(
                    (isError ? HisingenTheme.semanticCritical : Color.primary).opacity(isError ? 0.08 : 0.03),
                    in: RoundedRectangle(cornerRadius: 0)
                )
                .hisCaptionLeading()
            }
        }
    }

    private var attentionCard: AnyView? {
        var items = error.map { [$0] } ?? []
        items.append(contentsOf: state.freshness.dataWarnings)
        guard !items.isEmpty else { return nil }
        return AnyView(Card {
            VStack(alignment: .leading, spacing: 6) {
                CardHeader(symbol: "exclamationmark.triangle.fill", title: L10n.text("Attention"), color: HisingenTheme.semanticWarning, isSemantic: true)
                ForEach(items, id: \.self) { Text("• \($0)").hisType(.label).foregroundStyle(.secondary) }
            }
        })
    }
}
