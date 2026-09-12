import SwiftUI

@MainActor
struct VehicleTabView: View {
    let state: VehicleState
    let cars: [CarSummary]
    let activeVin: String?
    let onSelectCar: (String) -> Void
    let onDismissCommandReceipt: (UUID) -> Void
    let error: String?
    let database: VehicleDatabase
    let reverseGeocoder: ReverseGeocoder
    let imageCache: CarImageCache

    @Environment(\.preferencesStore) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moreExpanded = true
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
    private var displayedStateSummary: VehicleStateSummary {
        if let software = state.softwareInfo, software.hasActionableFailure(),
           dismissedSoftwareEventIdentifier == software.eventIdentifier,
           state.stateSummary.message == L10n.text("Software update failed") {
            return VehicleStateSummary(message: L10n.text("Software event dismissed locally"), severity: .neutral)
        }
        return state.stateSummary
    }

    var body: some View {
        VStack(spacing: HisingenTheme.sectionSpacing) {
            multiCarChips
            VehicleHeroCard(state: state, displayedStateSummary: displayedStateSummary, imageCache: imageCache)
            ForEach(Array(state.commandState.receipts.reversed()), id: \.id) { receipt in
                CommandReceiptChip(receipt: receipt, onDismiss: onDismissCommandReceipt)
                    .transition(cardTransition)
            }
            if let card = attentionCard { card.transition(cardTransition) }
            if let card = ExceptionsCard.make(state: state, features: features, dismissedSoftwareEventIdentifier: dismissedSoftwareEventIdentifier) { card.transition(cardTransition) }
            VehicleChargingCard(state: state, database: database).transition(cardTransition)
            if let card = chargingPlannerCard { card.transition(cardTransition) }
            adaptiveCardsRow(FuelAndEngineCard.make(state: state, preferences: preferences), openingsCard)
            adaptiveCardsRow(tireSchematicCard, locationCard)
            if features.contains(.vehicleHealth) || features.contains(.exteriorStatus) {
                VehicleReadinessCard(state: state, lowBatteryThreshold: preferences.lowBatteryThreshold)
            }
            moreDetailsSection
        }
        .animation(cardChangeAnimation, value: warningsSignature)
        .animation(cardChangeAnimation, value: pillSignature)
        .task(id: state.identity.vin) {
            dismissedSoftwareEventIdentifier = preferences.dismissedSoftwareEventIdentifier(for: state.identity.vin)
        }
    }

    private static let twoColumnThreshold: CGFloat = 500
    private var usesTwoColumnCards: Bool {
        preferences.wideCardLayout == .twoColumns && HisingenTheme.layoutWidth >= Self.twoColumnThreshold
    }

    @ViewBuilder
    private func adaptiveCardsRow(_ primary: AnyView?, _ secondary: AnyView?) -> some View {
        switch (primary, secondary) {
        case (.some(let first), .some(let second)) where usesTwoColumnCards:
            HStack(alignment: .top, spacing: HisingenTheme.sectionSpacing) {
                first.frame(maxWidth: .infinity)
                second.frame(maxWidth: .infinity)
            }.transition(cardTransition)
        case (.some(let first), .some(let second)):
            VStack(spacing: HisingenTheme.sectionSpacing) { first; second }.transition(cardTransition)
        case (.some(let only), _):
            only.transition(cardTransition)
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
                                Image(systemName: preferences.activeBrand == .polestar ? "bolt.car.fill" : "car.fill").font(.system(size: 10))
                                Text(car.title).font(.system(size: 11, weight: selected ? .bold : .medium))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(selected ? HisingenTheme.accent.opacity(0.12) : Color.primary.opacity(0.04), in: Capsule())
                            .overlay(Capsule().stroke(selected ? HisingenTheme.accent : Color.primary.opacity(0.15), lineWidth: selected ? 1.2 : 0.5))
                            .animation(reduceMotion ? nil : Motion.selection, value: selected)
                        }.buttonStyle(.pressable)
                    }
                }.padding(.horizontal, 2)
            }
        }
    }

    private var moreDetailsSection: some View {
        let cards = [
            (id: "identity", view: VehicleIdentityCard.make(state: state, features: features, preferences: preferences)),
            (id: "lighting", view: LightingAndFluidCard.make(state: state, features: features)),
            (id: "climate", view: VehicleClimateCard.make(state: state, features: features, preferences: preferences)),
            (id: "software", view: VehicleSoftwareCard.make(state: state, features: features, preferences: preferences, dismissedSoftwareEventIdentifier: $dismissedSoftwareEventIdentifier)),
            (id: "diagnostics", view: VehicleDiagnosticsCard.make(state: state, features: features, preferences: preferences))
        ].compactMap { entry -> (id: String, view: AnyView)? in
            guard let view = entry.view else { return nil }
            return (entry.id, view)
        }
        guard !cards.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            DisclosureGroup(isExpanded: $moreExpanded) {
                VStack(spacing: HisingenTheme.sectionSpacing) {
                    ForEach(cards, id: \.id) { $0.view }
                }.padding(.top, HisingenTheme.sectionSpacing)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "ellipsis.circle").foregroundStyle(HisingenTheme.inkMuted).font(.system(size: 13, weight: HisingenTheme.headingWeight)).accessibilityHidden(true)
                    Text(L10n.format("More (%d)", cards.count)).font(.system(size: 13, weight: HisingenTheme.headingWeight)).foregroundStyle(HisingenTheme.ink)
                    Spacer()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.format("More, %d sections", cards.count))
                .accessibilityHint(L10n.text("Vehicle identity, tyres, climate, location, software, and diagnostics"))
            }
            .disclosureGroupStyle(WholeRowDisclosureStyle())
            .padding(HisingenTheme.cardPadding)
            .background(HisingenTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HisingenTheme.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: HisingenTheme.cornerRadius, style: .continuous).stroke(HisingenTheme.hairline, lineWidth: HisingenTheme.cardBorderWidth))
        )
    }

    private var chargingPlannerCard: AnyView? {
        guard features.contains(.smartChargingPlanner), state.powertrain.hasElectricRange,
              state.energy.batteryPercentage != nil, state.energy.targetPercentage != nil else { return nil }
        return AnyView(ChargingPlannerCard(state: state))
    }

    private var openingsCard: AnyView? {
        guard features.contains(.exteriorStatus) else { return nil }
        guard let exterior = state.exteriorStatus, !exterior.openings.isEmpty else {
            if state.isVolvo { return AnyView(volvoUnavailableCard(symbol: "car.side.lock", title: L10n.text("Doors & Openings"), color: .indigo, message: L10n.text("Requires 'Connected Vehicle API' subscription on developer.volvocars.com and 'Volvo Connected Services' enabled in vehicle privacy settings."))) }
            return UnavailableFeatureCard.make(state: state, feature: .exteriorStatus, symbol: "car.side.lock", title: L10n.text("Doors & Openings"), color: .indigo, badge: AppFeature.exteriorStatus.title)
        }
        return AnyView(DoorsAndOpeningsCardView(ext: exterior, isLocked: exterior.isLocked))
    }

    private var tireSchematicCard: AnyView? {
        guard features.contains(.tyreAndWarnings) else { return nil }
        guard let tyres = state.maintenance.details?.tyres, !tyres.isEmpty else {
            if state.isVolvo { return AnyView(volvoUnavailableCard(symbol: "circle.grid.2x2", title: L10n.text("Tire Status (iTPMS)"), color: .blue, message: L10n.text("Requires 'Connected Vehicle API' subscription on developer.volvocars.com and vehicle driven to calibrate iTPMS sensors."))) }
            return UnavailableFeatureCard.make(state: state, feature: .tyreAndWarnings, symbol: "circle.grid.2x2", title: L10n.text("Tire Status (iTPMS)"), color: .blue, badge: AppFeature.tyreAndWarnings.title)
        }
        return AnyView(TireStatusCardView(tyres: tyres))
    }

    private var locationCard: AnyView? {
        guard features.contains(.vehicleLocation) else { return nil }
        guard let location = state.location, let latitude = location.latitude, let longitude = location.longitude else {
            let explanation = state.isVolvo ? L10n.text("Location requires subscribing to the Location API in developer.volvocars.com and enabling 'Share Location' in vehicle settings.") : L10n.text("Parking position unavailable.")
            return AnyView(Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardHeader(symbol: "location.fill", title: L10n.text("Vehicle Location"), color: .red)
                    HStack(spacing: 8) {
                        Image(systemName: "location.slash.fill").font(.system(size: 15)).foregroundStyle(HisingenTheme.semanticWarning)
                        Text(explanation).font(.system(size: 11)).foregroundStyle(HisingenTheme.inkMuted)
                    }.padding(8).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                }
            })
        }
        return AnyView(LocationCardView(lat: latitude, lon: longitude, speed: location.speed, heading: location.heading, timestamp: location.timestamp, altitude: location.altitudeMeters, accuracy: location.accuracyMeters, parkingBrake: location.parkingBrakeEngaged, gear: location.gear, weather: state.weather, isLive: !state.isStale(), freshnessText: state.freshnessDescription, reverseGeocoder: reverseGeocoder))
    }

    private func volvoUnavailableCard(symbol: String, title: String, color: Color, message: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: symbol, title: title, color: color)
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(HisingenTheme.semanticWarning)
                    Text(message).font(.system(size: 11)).foregroundStyle(HisingenTheme.inkMuted)
                }.padding(8).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
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
                ForEach(items, id: \.self) { Text("• \($0)").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        })
    }
}
