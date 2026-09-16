import SwiftUI

/// The "Garage & Fleet" card in Settings → Accounts: every known vehicle with a live
/// summary, per-vehicle nickname/theme controls, a manual reorder, and a fleet roll-up
/// banner. Extracted from `SettingsView`; reorder writes go through `PreferenceBinder`.
@MainActor
struct SettingsFleetCard: View {
    let fleet: FleetSnapshot
    let imageCache: CarImageCache
    let binder: PreferenceBinder

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var prefs: PreferencesStore { binder.preferences }

    private func moveGarageVehicle(_ vin: String, offset: Int, current: [String]) {
        guard let index = current.firstIndex(of: vin) else { return }
        let target = index + offset
        guard current.indices.contains(target) else { return }
        var updated = current
        updated.swapAt(index, target)
        // The order write lands in preferences (a class) and re-renders via bump();
        // without this transaction the ForEach rows teleport instead of sliding.
        withAnimation(reduceMotion ? nil : Motion.layout) {
            prefs.garageVehicleOrder = updated
            binder.bump()
        }
        binder.notify(.presentation)
    }

    var body: some View {
        let activeVin = prefs.vin
        let allVins = fleet.vehicles(orderedBy: prefs.garageVehicleOrder)

        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: "car.2.fill", title: L10n.text("Garage & Fleet"), color: HisingenTheme.accent)
                    Spacer()
                    Text(L10n.format("%d Vehicles", allVins.count))
                        .hisType(.caption, weight: .bold)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(HisingenTheme.accent.opacity(0.12), in: Capsule())
                        .foregroundStyle(HisingenTheme.accent)
                }

                if allVins.isEmpty {
                    Text(L10n.text("No vehicles discovered yet. Sign in to Polestar or Volvo above to connect your cars."))
                        .hisType(.caption)
                        .hisCaptionLeading()
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.secondary)
                } else {
                    if allVins.count > 1 {
                        fleetSummaryBanner(vins: allVins)
                    }

                    ForEach(Array(allVins.enumerated()), id: \.element) { index, vin in
                        HStack(spacing: 6) {
                            FleetVehicleCardRow(
                                vin: vin,
                                isActive: vin == activeVin,
                                vehicleState: fleet.snapshot(for: vin),
                                imageCache: imageCache,
                                onSettingsChanged: binder.notify
                            )
                            VStack(spacing: 2) {
                                Button { moveGarageVehicle(vin, offset: -1, current: allVins) } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .disabled(index == 0)
                                .accessibilityLabel(L10n.format("Move %@ up", vin))
                                Button { moveGarageVehicle(vin, offset: 1, current: allVins) } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .disabled(index == allVins.count - 1)
                                .accessibilityLabel(L10n.format("Move %@ down", vin))
                            }
                            .buttonStyle(.pressable)
                            .controlSize(.mini)
                        }
                    }
                }
            }
        }
    }

    private func fleetSummaryBanner(vins: [String]) -> some View {
        let allStates: [VehicleState] = vins.compactMap { vin in
            fleet.snapshot(for: vin)
        }

        let summary = VehicleFleetSummary(states: allStates)
        let totalChargingWatts = summary.chargingPowerWatts

        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "gauge.with.needle.fill")
                        .hisType(.micro)
                        .foregroundStyle(HisingenTheme.accent)
                    Text(L10n.text("Fleet Range"))
                        .hisType(.micro, weight: .medium)
                        .foregroundStyle(.secondary)
                }
                Text(summary.rangeKm.map { Format.distance(km: $0, unit: prefs.distanceUnit) } ?? "--")
                    .hisType(.body, weight: .bold, design: .rounded)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(7)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: summary.chargingCount == 0 ? "bolt.slash" : "bolt.fill")
                        .hisType(.micro)
                        .foregroundStyle(summary.chargingCount == 0 ? Color.secondary : HisingenTheme.semanticGood)
                    Text(L10n.text("Charging"))
                        .hisType(.micro, weight: .medium)
                        .foregroundStyle(.secondary)
                }
                if summary.chargingCount == 0 {
                    Text(summary.chargingCoverage == vins.count
                         ? L10n.text("No active charging reported") : L10n.text("Incomplete readings"))
                        .hisType(.label, weight: .semibold)
                } else {
                    HStack(spacing: 3) {
                        Text(L10n.format("%d active", summary.chargingCount))
                            .hisType(.label, weight: .bold, design: .rounded)
                            .monospacedDigit()
                            .foregroundStyle(HisingenTheme.semanticGood)
                        if totalChargingWatts > 0 {
                            Text("(\(Format.kilowatts(watts: totalChargingWatts)))")
                                .hisType(.micro)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(7)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "road.lanes")
                        .hisType(.micro)
                        .foregroundStyle(HisingenTheme.accent)
                    Text(L10n.text("Fleet Mileage"))
                        .hisType(.micro, weight: .medium)
                        .foregroundStyle(.secondary)
                }
                Text(summary.odometerKm.map { Format.distance(km: $0, unit: prefs.distanceUnit) } ?? "--")
                    .hisType(.body, weight: .bold, design: .rounded)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(7)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.bottom, 2)
        .help(L10n.text("Totals include fresh readings only. Vehicles with missing or stale readings are excluded."))
    }
}

@MainActor
struct SettingsFleetThumbnailView: View {
    let vin: String
    let brandIcon: String
    let isActive: Bool
    let imageCache: CarImageCache
    @State private var artwork: VehicleArtworkStore.Artwork?

    var body: some View {
        Group {
            if let cgImage = artwork?.image {
                Image(decorative: cgImage, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 26)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 5))
                    .transition(.opacity)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isActive ? HisingenTheme.accent.opacity(0.12) : Color.primary.opacity(0.05))
                        .frame(width: 28, height: 28)
                    Image(systemName: brandIcon)
                        .hisType(.body)
                        .foregroundStyle(isActive ? HisingenTheme.accent : Color.secondary)
                }
                .transition(.opacity)
            }
        }
        .task(id: vin) {
            guard imageCache.hasImage(for: vin) else { return }
            let store = VehicleArtworkStore.shared
            let budget = 128
            let source = VehicleArtworkStore.source(vin: vin, angle: 0)
            if let data = imageCache.image(for: vin) {
                // Decode finishes outside any transaction; wrapping the assignment
                // here is what lets the placeholder→artwork crossfade play.
                if let cached = store.cached(source: source, data: data, pixelBudget: budget) {
                    withAnimation(Motion.resolveCrossfade(Motion.theme)) { artwork = cached }
                } else {
                    let decoded = await store.artwork(source: source, data: data, pixelBudget: budget)
                    withAnimation(Motion.resolveCrossfade(Motion.theme)) { artwork = decoded }
                }
            }
        }
    }
}

@MainActor
struct FleetVehicleCardRow: View {
    let vin: String
    let isActive: Bool
    let vehicleState: VehicleState?
    let imageCache: CarImageCache
    let onSettingsChanged: (SettingsChange) -> Void
    @Environment(\.preferencesStore) private var preferences
    @State private var isHovered = false

    var body: some View {
        let brand: VehicleBrand = vehicleState?.model.brand ?? (vin.hasPrefix("YV") ? .volvo : .polestar)
        let brandIcon = brand == .polestar ? "bolt.car.fill" : "car.fill"
        let displayTitle = preferences.formattedVehicleTitle(
            vin: vin,
            modelName: vehicleState?.identity.modelName,
            modelYear: vehicleState?.identity.modelYear,
            registrationNo: vehicleState?.identity.registrationNo,
            fallbackBrand: brand
        )

        VStack(alignment: .leading, spacing: 8) {
            // Clickable header area
            HStack(spacing: 8) {
                SettingsFleetThumbnailView(vin: vin, brandIcon: brandIcon, isActive: isActive, imageCache: imageCache)

                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 6) {
                        Text(displayTitle)
                            .hisType(.label, weight: .semibold)
                        if isActive {
                            Text(L10n.text("ACTIVE"))
                                .hisType(.nano, weight: .bold)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(HisingenTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(HisingenTheme.accent)
                                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        }
                    }
                    HStack(spacing: 4) {
                        Text(preferences.displayVIN(vin))
                            .hisType(.micro, design: .monospaced)
                            .foregroundStyle(.secondary)
                            .privacySensitive(preferences.privacyRedactionEnabled)
                        if let vehicleState {
                            Text("· " + vehicleState.freshnessDescription)
                                .hisType(.micro)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                if !isActive {
                    Button {
                        onSettingsChanged(.selectVehicle(vin))
                    } label: {
                        Text(L10n.text("Switch To"))
                            .hisType(.caption, weight: .medium)
                    }
                    .controlSize(.small)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .contentShape(Rectangle())

            if let vehicleState {
                HStack(spacing: 12) {
                    if let battery = vehicleState.energy.batteryPercentage {
                        HStack(spacing: 4) {
                            Image(systemName: vehicleState.isCharging ? "bolt.fill" : "battery.100")
                                .hisType(.micro)
                                .foregroundStyle(HisingenTheme.fleetBatteryTint(level: vehicleState.batteryLevel))
                            Text(String(format: "%.0f%%", battery))
                                .hisType(.caption, weight: .semibold, design: .rounded)
                                .monospacedDigit()
                            if vehicleState.isCharging, let power = vehicleState.energy.powerWatts, power > 0 {
                                Text(Format.kilowatts(watts: power))
                                    .hisType(.micro)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if let fuel = vehicleState.fuelSystem.levelPercent {
                        HStack(spacing: 4) {
                            Image(systemName: "fuelpump.fill")
                                .hisType(.micro)
                                .foregroundStyle(Color.secondary)
                            Text(String(format: "%.0f%%", fuel))
                                .hisType(.caption, weight: .semibold, design: .rounded)
                                .monospacedDigit()
                        }
                    }

                    if let range = vehicleState.primaryRangeKm {
                        HStack(spacing: 3) {
                            Image(systemName: "gauge.with.needle.fill")
                                .hisType(.micro)
                                .foregroundStyle(.secondary)
                            Text(Format.distance(km: range, unit: preferences.distanceUnit))
                                .hisType(.caption, weight: .medium)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let isLocked = vehicleState.exteriorStatus?.isLocked {
                        HStack(spacing: 3) {
                            Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                                .hisType(.micro)
                                .foregroundStyle(isLocked ? Color.secondary : HisingenTheme.semanticWarning)
                            Text(isLocked ? L10n.text("Locked") : L10n.text("Unlocked"))
                                .hisType(.caption, weight: .medium)
                                .foregroundStyle(isLocked ? Color.secondary : HisingenTheme.semanticWarning)
                        }
                    }

                    Spacer()
                }
                .padding(.leading, 6)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isActive {
                        onSettingsChanged(.selectVehicle(vin))
                    }
                }
                .accessibilityAddTraits(isActive ? [] : [.isButton])
            }

            // Nickname & Theme Controls
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text(L10n.text("Nickname:"))
                        .hisType(.micro)
                        .foregroundStyle(.secondary)

                    TextField(L10n.text("Nickname"), text: Binding(
                        get: { preferences.vehicleNickname(for: vin) },
                        set: { preferences.setVehicleNickname($0, for: vin) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.mini)
                    .frame(maxWidth: 110)
                }

                HStack(spacing: 4) {
                    Text(L10n.text("Theme:"))
                        .hisType(.micro)
                        .foregroundStyle(.secondary)

                    Picker("", selection: Binding(
                        get: { preferences.theme(for: vin, brand: brand) },
                        set: { newTheme in
                            preferences.setTheme(newTheme, for: vin, brand: brand)
                            if isActive {
                                preferences.appTheme = newTheme
                                preferences.syncAppThemeStorageKey()
                            }
                            onSettingsChanged(.presentation)
                        }
                    )) {
                        ForEach(AppTheme.allCases, id: \.self) { t in
                            Text(t.title).tag(t)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.mini)
                    .frame(maxWidth: 130)
                }
            }
            .padding(.leading, 6)
        }
        .padding(9)
        .background(
            Color.primary.opacity(isActive ? 0.05 : (isHovered ? 0.045 : 0.025)),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? HisingenTheme.accent.opacity(0.35) : (isHovered && !isActive ? HisingenTheme.accent.opacity(0.25) : Color.clear), lineWidth: 1)
        )
        // isActive flips from an app-level SettingsChange with no transaction of
        // its own; this binding drives the badge/button swap and hover tint.
        .hisAnimation(Motion.interaction, value: isHovered)
        .hisAnimation(Motion.stateChange, value: isActive)
        .onHover { hovering in
            if !isActive {
                isHovered = hovering
            }
        }
    }
}
