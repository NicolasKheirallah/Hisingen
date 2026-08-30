import SwiftUI

struct OpeningChipView: View {
    let reading: OpeningReading
    var isHighlighted: Bool = false
    var onHoverChange: ((Bool) -> Void)? = nil

    @State private var isHovered = false

    private var isOpen: Bool { reading.state == .open || reading.state == .ajar }

    private var shortTitle: String {
        switch reading.opening {
        case .frontLeftDoor: return L10n.text("Front Left")
        case .frontRightDoor: return L10n.text("Front Right")
        case .rearLeftDoor: return L10n.text("Rear Left")
        case .rearRightDoor: return L10n.text("Rear Right")
        case .frontLeftWindow: return L10n.text("FL Window")
        case .frontRightWindow: return L10n.text("FR Window")
        case .rearLeftWindow: return L10n.text("RL Window")
        case .rearRightWindow: return L10n.text("RR Window")
        case .hood: return L10n.text("Hood")
        case .tailgate: return L10n.text("Tailgate")
        case .chargeLid: return L10n.text("Charge Lid")
        case .fuelFlap: return L10n.text("Fuel Flap")
        case .sunroof: return L10n.text("Sunroof")
        }
    }

    private var symbol: String {
        switch reading.opening {
        case .frontLeftDoor, .rearLeftDoor: return isOpen ? "door.left.hand.open" : "door.left.hand.closed"
        case .frontRightDoor, .rearRightDoor: return isOpen ? "door.right.hand.open" : "door.right.hand.closed"
        case .frontLeftWindow, .frontRightWindow, .rearLeftWindow, .rearRightWindow: return "window.vertical.closed"
        case .hood: return "car.front.waves.up"
        case .tailgate: return "car.rear.and.tire.marks"
        case .chargeLid: return "powerplug.fill"
        case .fuelFlap: return "fuelpump.fill"
        case .sunroof: return "sun.max.fill"
        }
    }

    var body: some View {
        let active = isHovered || isHighlighted
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9.5))
                .foregroundStyle(isOpen ? HisingenTheme.semanticWarning : .secondary)
                .frame(width: 12)
            Text(shortTitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isOpen ? HisingenTheme.semanticWarning : HisingenTheme.ink)
                .lineLimit(1)
            Spacer(minLength: 2)
            Circle()
                .fill(isOpen ? HisingenTheme.semanticWarning : HisingenTheme.semanticGood)
                .frame(width: 5, height: 5)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4.5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active ? (isOpen ? HisingenTheme.semanticWarning.opacity(0.12) : Color.primary.opacity(0.06)) : (isOpen ? HisingenTheme.semanticWarning.opacity(0.07) : Color.primary.opacity(0.03)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    active
                        ? (isOpen ? HisingenTheme.semanticWarning.opacity(0.6) : HisingenTheme.accent.opacity(0.5))
                        : (isOpen ? HisingenTheme.semanticWarning.opacity(0.3) : Color.primary.opacity(0.04)),
                    lineWidth: active ? 1.0 : 0.5
                )
        )
        .scaleEffect(active ? 1.02 : 1.0)
        .animation(Motion.selection, value: active)
        .onHover { hovered in
            isHovered = hovered
            onHoverChange?(hovered)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reading.opening.displayName): \(isOpen ? L10n.text("Open") : L10n.text("Closed"))")
    }
}

struct DoorsAndOpeningsCardView: View {
    let ext: ExteriorSnapshot
    let isLocked: Bool?

    @State private var hoveredOpening: VehicleOpening? = nil

    private var openItems: [VehicleOpening] {
        ext.itemsNeedingAttention
    }

    private var hasOpen: Bool {
        !openItems.isEmpty
    }

    private func reading(for op: VehicleOpening) -> OpeningReading? {
        ext.openings.first(where: { $0.opening == op })
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                // Header
                HStack {
                    CardHeader(symbol: "car.side.lock", title: L10n.text("Doors & Openings"), color: .indigo)
                    Spacer()
                    if hasOpen {
                        Pill(
                            text: L10n.format("%d Open", openItems.count),
                            color: HisingenTheme.semanticWarning,
                            symbol: "exclamationmark.triangle.fill"
                        )
                    } else if let isLocked {
                        Pill(
                            text: isLocked ? L10n.text("All Closed & Locked") : L10n.text("All Closed"),
                            color: isLocked ? HisingenTheme.semanticGood : .secondary,
                            symbol: isLocked ? "lock.fill" : "lock.open.fill"
                        )
                    }
                }

                VehicleSideProfileDoorsView(
                    openings: ext.openings,
                    isLocked: isLocked,
                    hoveredOpening: hoveredOpening
                )
                let readings = displayOrder.compactMap { reading(for: $0) }
                let pairs = stride(from: 0, to: readings.count, by: 2).map {
                    Array(readings[$0..<min($0 + 2, readings.count)])
                }
                VStack(spacing: 5) {
                    ForEach(0..<pairs.count, id: \.self) { idx in
                        let pair = pairs[idx]
                        HStack(spacing: 6) {
                            ForEach(pair, id: \.opening) { r in
                                openingChip(reading: r)
                            }
                            if pair.count == 1 {
                                Spacer().frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
    }

    private let displayOrder: [VehicleOpening] = [
        .hood, .tailgate,
        .frontLeftDoor, .frontRightDoor,
        .rearLeftDoor, .rearRightDoor,
        .frontLeftWindow, .frontRightWindow,
        .rearLeftWindow, .rearRightWindow,
        .sunroof, .chargeLid
    ]

    @ViewBuilder
    private func openingChip(reading: OpeningReading) -> some View {
        OpeningChipView(
            reading: reading,
            isHighlighted: hoveredOpening == reading.opening,
            onHoverChange: { hovered in
                if hovered {
                    hoveredOpening = reading.opening
                } else if hoveredOpening == reading.opening {
                    hoveredOpening = nil
                }
            }
        )
    }
}

struct TireStatusCardView: View {
    let tyres: [TyrePressure]

    @State private var hoveredPosition: TyrePosition? = nil

    /// Some vehicles only ever report a per-tyre warning level (OK/low/very low/high), never a
    /// numeric kPa reading — indirect TPMS (iTPMS), inferred from wheel-speed-sensor imbalance,
    /// as opposed to direct TPMS's physical per-wheel pressure sensor. This isn't brand-specific:
    /// it's true of Volvo's whole lineup *and* Polestar 2 (see `VehicleCapabilityProfile`'s
    /// `.tyrePressureValues` case for `.polestar2`, `.unavailable` for the same reason). Keyed on
    /// the data actually reported rather than the brand, so it stays correct for both today and
    /// doesn't need updating if a future model's sensor support changes.
    private var reportsWarningLevelOnly: Bool {
        !tyres.isEmpty && tyres.allSatisfy { $0.kilopascals == nil }
    }

    /// Header pill state: red/orange on any flagged tyre, green once every tyre explicitly
    /// reported (or measured), green-with-caveat for partial reports, muted only when the
    /// provider said nothing at all.
    private var summaryPill: (text: String, color: Color, symbol: String) {
        let reportedCount = tyres.filter { $0.kilopascals != nil || $0.warning != .unknown }.count
        let allReported = !tyres.isEmpty && reportedCount == tyres.count
        if tyres.contains(where: { $0.warning.needsAttention }) {
            return (L10n.text("Check Pressure"), HisingenTheme.semanticWarning, "exclamationmark.triangle.fill")
        }
        if allReported {
            return (L10n.text("Everything looks good"), HisingenTheme.semanticGood, "checkmark.circle.fill")
        }
        if reportedCount > 0 {
            return (L10n.text("No warnings reported"), HisingenTheme.semanticGood, "checkmark.circle.fill")
        }
        return (L10n.text("Data unavailable"), Color.secondary, "questionmark.circle")
    }

    var body: some View {
        let hasValues = tyres.contains { $0.kilopascals != nil }
        let summary = summaryPill
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(
                        symbol: "circle.grid.2x2",
                        title: L10n.text(hasValues ? "Tire Pressure" : "Tire Status (iTPMS)"),
                        color: .blue
                    )
                    Spacer()
                    Pill(text: summary.text, color: summary.color, symbol: summary.symbol)
                }

                if reportsWarningLevelOnly {
                    Text(L10n.text("This vehicle's indirect TPMS reports a warning level per tyre, not an exact pressure reading."))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VehicleSideProfileTiresView(tyres: tyres, hoveredPosition: hoveredPosition)
                    .padding(.horizontal, 4)

                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        tirePill(title: L10n.text("Front Left"), position: .frontLeft)
                        tirePill(title: L10n.text("Front Right"), position: .frontRight)
                    }
                    HStack(spacing: 6) {
                        tirePill(title: L10n.text("Rear Left"), position: .rearLeft)
                        tirePill(title: L10n.text("Rear Right"), position: .rearRight)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tirePill(title: String, position: TyrePosition) -> some View {
        TirePillView(
            title: title,
            tyre: tyres.first(where: { $0.position == position }),
            isHighlighted: hoveredPosition == position,
            onHoverChange: { hovered in
                hoveredPosition = hovered ? position : (hoveredPosition == position ? nil : hoveredPosition)
            }
        )
    }
}

struct TirePillView: View {
    let title: String
    let tyre: TyrePressure?
    var isHighlighted: Bool = false
    var onHoverChange: ((Bool) -> Void)? = nil

    @State private var isHovered = false
    @Environment(\.preferencesStore) private var preferences

    var body: some View {
        let warningState = tyre?.warning ?? TyrePressureWarning.unknown
        let attention = warningState.needsAttention
        let pressureText = tyre?.kilopascals.map { Format.pressure(kilopascals: $0, unit: preferences.pressureUnit) }
        let statusText: String = {
            switch (pressureText, attention) {
            case (let pressure?, true): return "\(pressure) · \(warningState.displayName)"
            case (let pressure?, false): return pressure
            default: return warningState.displayName
            }
        }()
        // Green dot means "measured fine or explicitly OK". A reading with no flag counts as
        // good even when the warning enum stayed unknown (e.g. a discovered pressure quadruple
        // without warning fields). Only truly unreported tyres fall back to muted/unknown.
        let knownGood = !attention && (warningState == .none || pressureText != nil)
        let statusColor: Color = attention
            ? HisingenTheme.tyreWarningColor(warningState)
            : (knownGood ? HisingenTheme.semanticGood : Color.secondary)
        let activeHover = isHovered || isHighlighted

        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6.5, height: 6.5)
                    .shadow(color: statusColor.opacity(activeHover ? 0.5 : 0), radius: 2)
                    .accessibilityHidden(true)
                Text(statusText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(attention ? statusColor : (knownGood ? HisingenTheme.ink : HisingenTheme.inkMuted))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(activeHover ? Color.primary.opacity(0.08) : Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    activeHover
                        ? (attention ? statusColor.opacity(0.5) : HisingenTheme.accent.opacity(0.45))
                        : Color.primary.opacity(0.06),
                    lineWidth: activeHover ? 1.0 : 0.5
                )
        )
        .scaleEffect(activeHover ? 1.02 : 1.0)
        .animation(Motion.selection, value: activeHover)
        .onHover { hovered in
            isHovered = hovered
            onHoverChange?(hovered)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(statusText)")
    }
}

struct LocationCardView: View {
    let lat: Double
    let lon: Double
    let speed: Double?
    let heading: Double?
    var timestamp: Date? = nil
    var altitude: Double? = nil
    var accuracy: Double? = nil
    var parkingBrake: Bool? = nil
    var gear: String? = nil
    var weather: VehicleWeather? = nil
    let isLive: Bool
    let freshnessText: String
    let reverseGeocoder: ReverseGeocoder

    @State private var streetAddress: String? = nil
    @State private var copiedCoordinates = false
    @Environment(\.preferencesStore) private var preferences

    private var isMoving: Bool { (speed ?? 0) > 3 }

    private var statusLine: String {
        if isMoving { return L10n.text("Moving now") }
        if let timestamp {
            return L10n.format("Parked at %@", Format.shortTime(date: timestamp))
        }
        if isLive { return L10n.text("Parked here") }
        return L10n.format("Last seen here · %@", freshnessText)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: "location.fill", title: L10n.text("Vehicle Location"), color: .red)
                    Spacer()
                    if let parkingBrake, parkingBrake {
                        Pill(
                            text: L10n.text("Brake Set"),
                            color: .orange,
                            symbol: "parkingsign.circle.fill"
                        )
                    }
                    if let gear, !gear.isEmpty {
                        Pill(
                            text: gear,
                            color: HisingenTheme.accent,
                            symbol: "gearshape.fill"
                        )
                    }
                    Pill(
                        text: isMoving ? L10n.text("Moving") : L10n.text("Parked"),
                        color: isMoving ? HisingenTheme.semanticActive : .secondary,
                        symbol: isMoving ? "arrow.up.right.circle.fill" : "parkingsign.circle"
                    )
                }

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusLine)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isLive ? .secondary : HisingenTheme.semanticWarning)

                        if let streetAddress, !streetAddress.isEmpty {
                            Text(streetAddress)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(HisingenTheme.ink)
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }

                        HStack(spacing: 5) {
                            Text(String(format: "GPS: %.4f°, %.4f°", lat, lon))
                                .font(.system(size: streetAddress != nil ? 10 : 11, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(streetAddress != nil ? .secondary : HisingenTheme.ink)

                            Button {
                                let coords = String(format: "%.6f, %.6f", lat, lon)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(coords, forType: .string)
                                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                                withAnimation(Motion.stateChange) {
                                    copiedCoordinates = true
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                                    withAnimation(Motion.interaction) {
                                        copiedCoordinates = false
                                    }
                                }
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: copiedCoordinates ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 9))
                                    if copiedCoordinates {
                                        Text(L10n.text("Copied"))
                                            .font(.system(size: 9, weight: .semibold))
                                    }
                                }
                                .foregroundStyle(copiedCoordinates ? HisingenTheme.semanticGood : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help(L10n.text("Copy Coordinates"))
                        }

                        if let weather, let temp = weather.temperatureCelsius {
                            HStack(spacing: 4) {
                                Image(systemName: "cloud.sun.fill")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.orange)
                                Text(Format.temperature(celsius: temp, unit: preferences.temperatureUnit))
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(HisingenTheme.ink)
                                if let cond = weather.condition {
                                    Text("· \(L10n.text(cond))")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(HisingenTheme.inkMuted)
                                }
                                if let hum = weather.relativeHumidity {
                                    Text("· \(hum)%")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.top, 2)
                        }

                        if let speed, speed > 0 {
                            HStack(spacing: 6) {
                                Text("\(L10n.text("Speed")): \(Format.speed(kmH: Int(speed.rounded()), unit: preferences.distanceUnit))")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                                if let heading {
                                    Text("· \(Int(heading))°")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }

                        if altitude != nil || accuracy != nil {
                            HStack(spacing: 6) {
                                if let altitude {
                                    Text(String(format: "%.0f m %@", altitude, L10n.text("elevation")))
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.secondary)
                                }
                                if let accuracy {
                                    Text(String(format: "±%.1f m", accuracy))
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 6) {
                        Button {
                            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                             if let label = preferences.activeBrand.displayName
                                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                               let url = URL(string: "maps://?q=\(label)&ll=\(lat),\(lon)") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "map.fill")
                                Text(L10n.text("Open in Maps"))
                            }
                            .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button {
                            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                            if let url = URL(string: "https://maps.google.com/?q=\(lat),\(lon)") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "safari")
                                Text(L10n.text("Google Maps"))
                            }
                            .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
        }
        .task {
            streetAddress = await reverseGeocoder.geocode(latitude: lat, longitude: lon)
        }
    }
}
