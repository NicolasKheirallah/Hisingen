import SwiftUI

struct OpeningChipView: View {
    let reading: OpeningReading
    var isHighlighted: Bool = false
    var onHoverChange: ((Bool) -> Void)? = nil

    @State private var isHovered = false
    @State private var dotBreathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    /// The row's fill for its hover / highlight / open states. Named `stateFill`, not `chipFill`:
    /// it shadowed the real `HisingenTheme.chipFill` token, which is the inset surface, while this
    /// is a state tint over whatever surface the row already sits on.
    private var stateFill: Color {
        if isHovered || isHighlighted {
            return isOpen ? HisingenTheme.semanticWarning.opacity(0.12) : Color.primary.opacity(0.06)
        }
        return isOpen ? HisingenTheme.semanticWarning.opacity(0.07) : Color.primary.opacity(0.03)
    }

    private var chipStroke: Color {
        if isHovered || isHighlighted {
            return isOpen ? HisingenTheme.semanticWarning.opacity(0.6) : HisingenTheme.accent.opacity(0.5)
        }
        return isOpen ? HisingenTheme.semanticWarning.opacity(0.3) : Color.primary.opacity(0.04)
    }

    private var symbolView: some View {
        Image(systemName: symbol)
            .hisType(.micro)
            .foregroundStyle(isOpen ? HisingenTheme.semanticWarning : Color.secondary)
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .frame(width: 12)
    }

    private var titleView: some View {
        Text(shortTitle)
            .hisType(.caption, weight: .medium)
            .foregroundStyle(isOpen ? HisingenTheme.semanticWarning : HisingenTheme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.9)
    }

    private var statusDot: some View {
        Circle()
            .fill(isOpen ? HisingenTheme.semanticWarning : HisingenTheme.semanticGood)
            .frame(width: 5, height: 5)
            .opacity(dotBreathing ? 0.6 : 1)
            .animation(reduceMotion ? nil : (isOpen ? Motion.livePulse : Motion.interaction), value: dotBreathing)
    }

    private var chipContent: some View {
        HStack(spacing: 5) {
            symbolView
            titleView
            Spacer(minLength: 2)
            statusDot
        }
    }

    var body: some View {
        let active = isHovered || isHighlighted
        chipContent
        .padding(.horizontal, 6)
        .padding(.vertical, 4.5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(stateFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(chipStroke, lineWidth: active ? 1.0 : 0.5)
        )
        .scaleEffect(active ? 1.02 : 1.0)
        // Open/close recolors icon, label and dot; the hover animation below
        // only owns the highlight, so this needs its own key.
        .hisAnimation(Motion.stateChange, value: isOpen)
        .hisAnimation(Motion.selection, value: active)
        .onHover { hovered in
            isHovered = hovered
            onHoverChange?(hovered)
        }
        .onAppear {
            guard isOpen, !reduceMotion else { return }
            dotBreathing = true
        }
        .onChange(of: isOpen) { _, open in
            dotBreathing = open && !reduceMotion
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reading.opening.displayName): \(isOpen ? L10n.text("Open") : L10n.text("Closed"))")
    }
}

struct DoorsAndOpeningsCardView: View {
    let ext: ExteriorSnapshot
    let isLocked: Bool?
    var isTailgateLocked: Bool? = nil
    /// Drives which silhouette is drawn: a Polestar 3 or 4 owner gets their own car's panels
    /// rather than a Polestar 2 with the highlights in roughly the right place.
    var model: VehicleModel? = nil

    @State private var hoveredOpening: VehicleOpening? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cardChangeAnimation: Animation? { reduceMotion ? nil : Motion.cardChange }
    /// Reduce Motion keeps the fade and drops the movement.
    private var pillTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95))
    }

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
                HStack {
                    CardHeader(symbol: "car.side.lock", title: L10n.text("Doors & Openings"), color: .indigo)
                    Spacer()
                    if hasOpen {
                        Pill(
                            text: L10n.format("%d Open", openItems.count),
                            color: HisingenTheme.semanticWarning,
                            symbol: "exclamationmark.triangle.fill"
                        )
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .transition(pillTransition)
                    } else if let isLocked {
                        Pill(
                            text: isLocked ? L10n.text("All Closed & Locked") : L10n.text("All Closed"),
                            color: isLocked ? HisingenTheme.semanticGood : .secondary,
                            symbol: isLocked ? "lock.fill" : "lock.open.fill"
                        )
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .transition(pillTransition)
                    }
                    if let isTailgateLocked {
                        Pill(
                            text: isTailgateLocked ? L10n.text("Tailgate locked") : L10n.text("Tailgate unlocked"),
                            color: isTailgateLocked ? HisingenTheme.semanticGood : HisingenTheme.semanticWarning,
                            symbol: isTailgateLocked ? "lock.fill" : "lock.open.fill"
                        )
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .transition(pillTransition)
                    }
                }
                .animation(cardChangeAnimation, value: openItems.count)
                .animation(cardChangeAnimation, value: isTailgateLocked)

                VehicleSideProfileDoorsView(
                    openings: ext.openings,
                    model: model,
                    hoveredOpening: hoveredOpening,
                    // Two-way: hovering a chip lights the part, and hovering the part lights the
                    // chip. The chip grid is the legend now rather than the only interface.
                    onHoverOpening: { hoveredOpening = $0 },
                    // A chip does nothing on a tap either, so pointing at the car does what
                    // hovering a chip does: it holds the part and its chip lit together. Inventing
                    // a second behaviour for the drawing would be the same defect in reverse.
                    onSelectOpening: { hoveredOpening = $0 }
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

    /// Every opening the card can report, in the order it lists them.
    ///
    /// The fuel flap belongs here even though the side profile draws it in the same place as
    /// the charge lid: the header counts everything in `itemsNeedingAttention`, so an opening
    /// with no chip left the pill saying "1 Open" over a grid where every chip was closed.
    /// Ordered to agree with the drawing above it: the side profile faces right, so the rear of
    /// the car is on the left of the picture and the front is on the right. The grid used to run
    /// front-then-rear, which meant a reader following the car left to right met its parts in the
    /// reverse of the order they are listed in.
    private let displayOrder: [VehicleOpening] = [
        .tailgate, .hood,
        .rearLeftDoor, .rearRightDoor,
        .rearLeftWindow, .rearRightWindow,
        .frontLeftDoor, .frontRightDoor,
        .frontLeftWindow, .frontRightWindow,
        .sunroof, .chargeLid, .fuelFlap
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
    /// Drives which silhouette and which wheel circles are drawn.
    var model: VehicleModel? = nil

    @State private var hoveredPosition: TyrePosition? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Some vehicles only ever report a per-tyre warning level (OK/low/very low/high), never a
    /// numeric kPa reading – indirect TPMS (iTPMS), inferred from wheel-speed-sensor imbalance,
    /// as opposed to direct TPMS's physical per-wheel pressure sensor. This isn't brand-specific:
    /// it's true of Volvo's whole lineup *and* Polestar 2 (see `VehicleCapabilityProfile`'s
    /// `.tyrePressureValues` case for `.polestar2`, `.unavailable` for the same reason). Keyed on
    /// the data actually reported rather than the brand, so it stays correct for both today and
    /// doesn't need updating if a future model's sensor support changes.
    private var reportsWarningLevelOnly: Bool {
        !tyres.isEmpty && tyres.allSatisfy { $0.kilopascals == nil }
    }

    /// Header pill state: red/orange on any flagged tyre, green once every tyre is *measured*
    /// fine, green-with-caveat for partial reports, muted only when the provider said nothing
    /// at all on a pressure-reporting vehicle. In iTPMS mode (warning level without
    /// measurements) the owner decision for Polestar 2 is: an unflagged reading IS the
    /// all-clear the system can give – the system only speaks up when it detects an issue –
    /// so both the quiet and the flagged-free states render green and only a real flag
    /// turns the card warning-colored.
    private var summaryPill: (text: String, color: Color, symbol: String) {
        let reportedCount = tyres.filter { $0.kilopascals != nil || $0.warning != .unknown }.count
        let allReported = !tyres.isEmpty && reportedCount == tyres.count
        if tyres.contains(where: { $0.warning.needsAttention }) {
            return (L10n.text("Check Pressure"), HisingenTheme.semanticWarning, "exclamationmark.triangle.fill")
        }
        if tyres.contains(where: { $0.warning == .sensorFault }) {
            return (L10n.text("Sensor fault"), HisingenTheme.semanticWarning, "exclamationmark.triangle.fill")
        }
        if reportsWarningLevelOnly {
            return (L10n.text("No warnings reported"), HisingenTheme.semanticGood, "checkmark.circle.fill")
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
                        color: HisingenTheme.semanticActive
                    )
                    Spacer()
                    Pill(text: summary.text, color: summary.color, symbol: summary.symbol)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .hisAnimation(Motion.stateChange, value: summary.text)
                }

                if reportsWarningLevelOnly {
                    Text(L10n.text("This vehicle's indirect TPMS reports a warning level per tyre, not an exact pressure reading."))
                        .hisType(.micro)
                        .foregroundStyle(.secondary)
                        .hisCaptionLeading()
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("The status comes from the vehicle's API and only changes when an issue is reported. An unflagged tyre means the system has not detected an issue at its last check."))
                        .hisType(.micro)
                        .foregroundStyle(.secondary)
                        .hisCaptionLeading()
                        .fixedSize(horizontal: false, vertical: true)
                }

                VehicleSideProfileTiresView(tyres: tyres, model: model, hoveredPosition: hoveredPosition)
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
            treatsUnreportedAsHealthy: reportsWarningLevelOnly,
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
    /// iTPMS presentation: with no pressure sensor, an unflagged tyre is the all-clear the
    /// system can give, so an unreported warning renders green "OK" instead of "Unknown".
    var treatsUnreportedAsHealthy: Bool = false
    var isHighlighted: Bool = false
    var onHoverChange: ((Bool) -> Void)? = nil

    @State private var isHovered = false
    @Environment(\.preferencesStore) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var warningState: TyrePressureWarning { tyre?.warning ?? .unknown }
    private var attention: Bool { warningState.needsAttention }
    private var pressureText: String? {
        tyre?.kilopascals.map { Format.pressure(kilopascals: $0, unit: preferences.pressureUnit) }
    }
    private var unreportedAllClear: Bool {
        treatsUnreportedAsHealthy && pressureText == nil && !attention
            && (warningState == .unknown || warningState == .none)
    }

    private var measuredText: String? { pressureText }
    private var inferredText: String? {
        // A measured kPa reading and an inferred warning level are different kinds of fact, and
        // they were concatenated into one semibold string that then animated through a proportional
        // font, so the digits reflowed on every update and the two could not be told apart. The
        // measurement is the reading; the level is the qualifier beneath it.
        switch (pressureText, attention) {
        case (_?, true): return warningState.displayName
        case (_?, false): return nil
        case (nil, false) where unreportedAllClear: return TyrePressureWarning.none.displayName
        default: return warningState.displayName
        }
    }

    private var statusText: String { measuredText ?? inferredText ?? warningState.displayName }

    private var knownGood: Bool {
        // Green dot means "measured fine". A reading with no flag counts as good even when
        // the warning enum stayed unknown (e.g. a discovered pressure quadruple without
        // warning fields). On an iTPMS vehicle an unflagged tyre is presented as the
        // all-clear per the owner decision above. Only genuinely unreported tyres on a
        // pressure-reporting vehicle, or a reported sensor fault, stay muted.
        !attention && (pressureText != nil || unreportedAllClear)
    }

    private var statusColor: Color {
        attention
            ? HisingenTheme.tyreWarningColor(warningState)
            : (knownGood ? HisingenTheme.semanticGood : Color.secondary)
    }

    private var activeHover: Bool { isHovered || isHighlighted }

    private var tireFill: Color {
        Color.primary.opacity(activeHover ? 0.08 : 0.035)
    }

    private var tireStroke: Color {
        if activeHover {
            return attention ? statusColor.opacity(0.5) : HisingenTheme.accent.opacity(0.45)
        }
        return Color.primary.opacity(0.06)
    }

    private var measuredColor: Color {
        if attention { return statusColor }
        return knownGood ? HisingenTheme.ink : HisingenTheme.inkMuted
    }

    private var readingView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let measuredText {
                Text(measuredText)
                    .hisType(.label, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(measuredColor)
                    .hisTelemetryValue(measuredText, reduceMotion: reduceMotion)
            }
            if let inferredText {
                Text(inferredText)
                    .hisType(.micro, weight: .medium)
                    .foregroundStyle(attention ? statusColor : Color.secondary)
            }
        }
    }

    private var tireContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .hisType(.caption, weight: .medium)
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6.5, height: 6.5)
                    .shadow(color: statusColor.opacity(activeHover ? 0.5 : 0), radius: 2)
                    .accessibilityHidden(true)
                readingView
            }
        }
    }

    var body: some View {
        tireContent
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tireFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tireStroke, lineWidth: activeHover ? 1.0 : 0.5)
        )
        .scaleEffect(activeHover ? 1.02 : 1.0)
        // Severity changes recolor the dot and rewrite the status line; the
        // hover animation below only owns the highlight.
        .hisAnimation(Motion.stateChange, value: warningState)
        .hisAnimation(Motion.selection, value: activeHover)
        .onHover { hovered in
            isHovered = hovered
            onHoverChange?(hovered)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(statusText)")
        .accessibilityValue(measuredText.map { "\($0), \(inferredText ?? "")" } ?? (inferredText ?? ""))
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
    /// True while the reverse geocode is in flight, so the card can say it is looking rather than
    /// looking empty.
    @State private var isResolvingAddress = false
    @State private var copiedCoordinates = false
    @Environment(\.preferencesStore) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    CardHeader(symbol: "location.fill", title: L10n.text("Vehicle Location"), color: HisingenTheme.semanticCritical)
                    Spacer()
                    if let parkingBrake, parkingBrake {
                        Pill(
                            text: L10n.text("Brake Set"),
                            color: HisingenTheme.semanticWarning,
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
                            .hisType(.caption, weight: .semibold)
                            .foregroundStyle(isLive ? .secondary : HisingenTheme.semanticWarning)
                            .hisTelemetryValue(statusLine, reduceMotion: reduceMotion)

                        if let streetAddress, !streetAddress.isEmpty {
                            Text(streetAddress)
                                .hisType(.body, weight: .semibold)
                                .foregroundStyle(HisingenTheme.ink)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .transition(.opacity)
                        } else if isResolvingAddress {
                            // The geocoder resolves asynchronously and the card showed nothing at
                            // all while it did, so the address simply appeared from nowhere with no
                            // sign that anything was being looked up.
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text(L10n.text("Finding the address…"))
                                    .hisType(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .transition(.opacity)
                        }

                        HStack(spacing: 5) {
                            // One size whichever way the lookup went. It used to step from 11pt to
                            // 10pt when the address arrived, so the line moved as a layout response
                            // to a network result.
                            Text(String(format: "GPS: %.4f°, %.4f°", lat, lon))
                                .hisType(.caption, weight: .medium)
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
                                Task {
                                    try? await Task.sleep(for: .seconds(1.8))
                                    withAnimation(Motion.interaction) {
                                        copiedCoordinates = false
                                    }
                                }
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: copiedCoordinates ? "checkmark" : "doc.on.doc")
                                        .hisType(.micro)
                                    if copiedCoordinates {
                                        Text(L10n.text("Copied"))
                                            .hisType(.micro, weight: .semibold)
                                    }
                                }
                                .foregroundStyle(copiedCoordinates ? HisingenTheme.semanticGood : .secondary)
                            }
                            .buttonStyle(.pressable)
                            .help(L10n.text("Copy Coordinates"))
                        }

                        if let weather, let temp = weather.temperatureCelsius {
                            HStack(spacing: 4) {
                                Image(systemName: "cloud.sun.fill")
                                    .hisType(.micro)
                                    .foregroundStyle(HisingenTheme.semanticWarning)
                                Text(Format.temperature(celsius: temp, unit: preferences.temperatureUnit))
                                    .hisType(.micro, weight: .semibold)
                                    .foregroundStyle(HisingenTheme.ink)
                                if let cond = weather.condition {
                                    Text("· \(L10n.text(cond))")
                                        .hisType(.micro)
                                        .foregroundStyle(HisingenTheme.inkMuted)
                                }
                                if let hum = weather.relativeHumidity {
                                    Text("· \(hum)%")
                                        .hisType(.micro)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.top, 2)
                        }

                        if let speed, speed > 0 {
                            HStack(spacing: 6) {
                                Text("\(L10n.text("Speed")): \(Format.speed(kmH: Int(speed.rounded()), unit: preferences.distanceUnit))")
                                    .hisType(.micro)
                                    .foregroundStyle(.secondary)
                                if let heading {
                                    Text("· \(Int(heading))°")
                                        .hisType(.micro)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }

                        if altitude != nil || accuracy != nil {
                            HStack(spacing: 6) {
                                if let altitude {
                                    Text(String(format: "%.0f m %@", altitude, L10n.text("elevation")))
                                        .hisType(.micro)
                                        .foregroundStyle(.secondary)
                                }
                                if let accuracy {
                                    Text(String(format: "±%.1f m", accuracy))
                                        .hisType(.micro)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    // The geocoder resolves async, so the address must fade in
                    // from an ancestor key, not its own insertion.
                    .animation(reduceMotion ? nil : Motion.entrance, value: streetAddress)

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
                            .hisType(.label, weight: .medium)
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
                            .hisType(.caption, weight: .medium)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
        }
        // Keyed on the coordinates so live-telemetry moves re-geocode; the geocoder's
        // cache keeps repeats at the same spot cheap.
        .task(id: "\(lat),\(lon)") {
            isResolvingAddress = true
            defer { isResolvingAddress = false }
            streetAddress = await reverseGeocoder.geocode(latitude: lat, longitude: lon)
        }
    }
}
