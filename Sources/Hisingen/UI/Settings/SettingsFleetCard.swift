import SwiftUI

/// The "Garage & Fleet" card in Settings → Accounts: every known vehicle with a live
/// summary, per-vehicle nickname/theme controls, a manual reorder, and a fleet roll-up
/// banner. Extracted from `SettingsView`; reorder writes go through `PreferenceBinder`.
@MainActor
struct SettingsFleetCard: View {
    let state: VehicleState?
    let cachedSnapshots: [String: VehicleState]
    let database: VehicleDatabase
    let imageCache: CarImageCache
    let binder: PreferenceBinder

    private var prefs: PreferencesStore { binder.preferences }

    private func moveGarageVehicle(_ vin: String, offset: Int, current: [String]) {
        guard let index = current.firstIndex(of: vin) else { return }
        let target = index + offset
        guard current.indices.contains(target) else { return }
        var updated = current
        updated.swapAt(index, target)
        prefs.garageVehicleOrder = updated
        binder.bump()
        binder.notify(.presentation)
    }

    var body: some View {
        let activeVin = prefs.vin
        let order = prefs.garageVehicleOrder
        var allVins: [String] = []
        for brand in VehicleBrand.allCases {
            let bVin = prefs.vin(for: brand)
            if !bVin.isEmpty && !allVins.contains(bVin) { allVins.append(bVin) }
        }
        if !activeVin.isEmpty && !allVins.contains(activeVin) { allVins.append(activeVin) }
        if let stateVin = state?.vin, !allVins.contains(stateVin) { allVins.append(stateVin) }
        for vin in cachedSnapshots.keys where !allVins.contains(vin) { allVins.append(vin) }
        allVins.sort {
            let left = order.firstIndex(of: $0) ?? Int.max
            let right = order.firstIndex(of: $1) ?? Int.max
            return left == right ? $0 < $1 : left < right
        }

        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: "car.2.fill", title: L10n.text("Garage & Fleet"), color: HisingenTheme.accent)
                    Spacer()
                    Text(L10n.format("%d Vehicles", allVins.count))
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(HisingenTheme.accent.opacity(0.12), in: Capsule())
                        .foregroundStyle(HisingenTheme.accent)
                }

                if allVins.isEmpty {
                    Text(L10n.text("No vehicles discovered yet. Sign in to Polestar or Volvo above to connect your cars."))
                        .font(.system(size: 10.5))
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
                                state: state,
                                cachedSnapshots: cachedSnapshots,
                                database: database,
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
                            .buttonStyle(.borderless)
                            .controlSize(.mini)
                        }
                    }
                }
            }
        }
    }

    private func fleetSummaryBanner(vins: [String]) -> some View {
        let allStates: [VehicleState] = vins.compactMap { vin in
            (vin == state?.vin ? state : nil) ?? cachedSnapshots[vin] ?? VehicleStateStore(database: database).snapshot(for: vin)
        }

        let totalRange = allStates.compactMap(\.primaryRangeKm).reduce(0, +)
        let chargingCars = allStates.filter(\.isCharging)
        let totalChargingWatts = chargingCars.compactMap(\.chargingPowerWatts).reduce(0, +)
        let totalOdometer = allStates.compactMap(\.odometerKm).reduce(0, +)

        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "gauge.with.needle.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(HisingenTheme.accent)
                    Text(L10n.text("Fleet Range"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(totalRange > 0 ? Format.distance(km: totalRange, unit: prefs.distanceUnit) : "--")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(7)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: chargingCars.isEmpty ? "bolt.slash" : "bolt.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(chargingCars.isEmpty ? Color.secondary : Color.green)
                    Text(L10n.text("Charging"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                if chargingCars.isEmpty {
                    Text(L10n.text("All Idle"))
                        .font(.system(size: 11.5, weight: .semibold))
                } else {
                    HStack(spacing: 3) {
                        Text(L10n.format("%d active", chargingCars.count))
                            .font(.system(size: 11.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.green)
                        if totalChargingWatts > 0 {
                            Text("(\(Format.kilowatts(watts: totalChargingWatts)))")
                                .font(.system(size: 9))
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
                        .font(.system(size: 9.5))
                        .foregroundStyle(HisingenTheme.accent)
                    Text(L10n.text("Fleet Mileage"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(totalOdometer > 0 ? Format.distance(km: totalOdometer, unit: prefs.distanceUnit) : "--")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(7)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.bottom, 2)
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
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isActive ? HisingenTheme.accent.opacity(0.12) : Color.primary.opacity(0.05))
                        .frame(width: 28, height: 28)
                    Image(systemName: brandIcon)
                        .font(.system(size: 12))
                        .foregroundStyle(isActive ? HisingenTheme.accent : Color.secondary)
                }
            }
        }
        .task(id: vin) {
            guard imageCache.hasImage(for: vin) else { return }
            let store = VehicleArtworkStore.shared
            let budget = 128
            let source = VehicleArtworkStore.source(vin: vin, angle: 0)
            if let data = imageCache.image(for: vin) {
                if let cached = store.cached(source: source, data: data, pixelBudget: budget) {
                    artwork = cached
                } else {
                    artwork = await store.artwork(source: source, data: data, pixelBudget: budget)
                }
            }
        }
    }
}

@MainActor
struct FleetVehicleCardRow: View {
    let vin: String
    let isActive: Bool
    let state: VehicleState?
    let cachedSnapshots: [String: VehicleState]
    let database: VehicleDatabase
    let imageCache: CarImageCache
    let onSettingsChanged: (SettingsChange) -> Void
    @Environment(\.preferencesStore) private var preferences
    @State private var isHovered = false

    var body: some View {
        let vehicleState = (vin == state?.vin ? state : nil) ?? cachedSnapshots[vin] ?? VehicleStateStore(database: database).snapshot(for: vin)
        let brand: VehicleBrand = vehicleState?.model.brand ?? (vin.hasPrefix("YV") ? .volvo : .polestar)
        let brandIcon = brand == .polestar ? "bolt.car.fill" : "car.fill"
        let displayTitle = preferences.formattedVehicleTitle(
            vin: vin,
            modelName: vehicleState?.modelName,
            modelYear: vehicleState?.modelYear,
            registrationNo: vehicleState?.registrationNo,
            fallbackBrand: brand
        )

        VStack(alignment: .leading, spacing: 8) {
            // Clickable header area
            HStack(spacing: 8) {
                // Vehicle Thumbnail or Icon
                SettingsFleetThumbnailView(vin: vin, brandIcon: brandIcon, isActive: isActive, imageCache: imageCache)

                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 6) {
                        Text(displayTitle)
                            .font(.system(size: 11, weight: .semibold))
                        if isActive {
                            Text(L10n.text("ACTIVE"))
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(HisingenTheme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(HisingenTheme.accent)
                        }
                    }
                    HStack(spacing: 4) {
                        Text("VIN: \(vin)")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if let vehicleState {
                            Text("· " + vehicleState.freshnessDescription)
                                .font(.system(size: 9))
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
                            .font(.system(size: 10, weight: .medium))
                    }
                    .controlSize(.small)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !isActive {
                    onSettingsChanged(.selectVehicle(vin))
                }
            }

            if let vehicleState {
                HStack(spacing: 12) {
                    if let battery = vehicleState.batteryPercentage {
                        HStack(spacing: 4) {
                            Image(systemName: vehicleState.isCharging ? "bolt.fill" : "battery.100")
                                .font(.system(size: 9.5))
                                .foregroundStyle(vehicleState.isCharging ? Color.green : (battery <= 20 ? Color.orange : Color.secondary))
                            Text(String(format: "%.0f%%", battery))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                            if vehicleState.isCharging, let power = vehicleState.chargingPowerWatts, power > 0 {
                                Text(Format.kilowatts(watts: power))
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if let fuel = vehicleState.fuelLevelPercent {
                        HStack(spacing: 4) {
                            Image(systemName: "fuelpump.fill")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Color.secondary)
                            Text(String(format: "%.0f%%", fuel))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                        }
                    }

                    if let range = vehicleState.primaryRangeKm {
                        HStack(spacing: 3) {
                            Image(systemName: "gauge.with.needle.fill")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                            Text(Format.distance(km: range, unit: preferences.distanceUnit))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let isLocked = vehicleState.exteriorStatus?.isLocked {
                        HStack(spacing: 3) {
                            Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                                .font(.system(size: 9.5))
                                .foregroundStyle(isLocked ? Color.secondary : Color.orange)
                            Text(isLocked ? L10n.text("Locked") : L10n.text("Unlocked"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(isLocked ? Color.secondary : Color.orange)
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
            }

            // Nickname & Theme Controls
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text(L10n.text("Nickname:"))
                        .font(.system(size: 9.5))
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
                        .font(.system(size: 9.5))
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
        .onHover { hovering in
            if !isActive {
                isHovered = hovering
            }
        }
    }
}
