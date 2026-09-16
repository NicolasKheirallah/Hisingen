import SwiftUI
import AppKit

/// Loads the bundled silhouette assets, one per model, on demand.
///
/// Keyed by asset name rather than held as a single image, so a Polestar 3 or 4 owner gets their
/// own car and switching between models does not reload or, worse, keep drawing the first one.
@MainActor
final class VehicleOutlineImageProvider {
    static let shared = VehicleOutlineImageProvider()

    private var cache: [String: NSImage?] = [:]

    func image(for spec: VehicleOutlineSpec) -> NSImage? {
        if let cached = cache[spec.assetName] { return cached }
        let loaded = Self.load(assetName: spec.assetName)
        cache[spec.assetName] = loaded
        return loaded
    }

    private static func load(assetName: String) -> NSImage? {
        var loaded: NSImage? = nil

        let rootBundlePath = Bundle.main.bundleURL.appendingPathComponent("Hisingen_Hisingen.bundle").path
        if FileManager.default.fileExists(atPath: rootBundlePath),
           let resBundle = Bundle(path: rootBundlePath),
           let url = resBundle.url(forResource: assetName, withExtension: "svg") {
            loaded = NSImage(contentsOf: url)
        }

        if loaded == nil,
           let resourceBundlePath = Bundle.main.path(forResource: "Hisingen_Hisingen", ofType: "bundle"),
           let resBundle = Bundle(path: resourceBundlePath),
           let url = resBundle.url(forResource: assetName, withExtension: "svg") {
            loaded = NSImage(contentsOf: url)
        }

        if loaded == nil, let url = Bundle.main.url(forResource: assetName, withExtension: "svg") {
            loaded = NSImage(contentsOf: url)
        }

        if loaded == nil {
            let possiblePaths = [
                ".build/arm64-apple-macosx/debug/Hisingen_Hisingen.bundle/\(assetName).svg",
                ".build/arm64-apple-macosx/release/Hisingen_Hisingen.bundle/\(assetName).svg",
                "Sources/Hisingen/Resources/\(assetName).svg",
                "assets/\(assetName).svg"
            ]
            for path in possiblePaths {
                if FileManager.default.fileExists(atPath: path), let img = NSImage(contentsOfFile: path) {
                    loaded = img
                    break
                }
            }
        }

        if let loaded {
            loaded.isTemplate = true
            return loaded
        }
        return nil
    }
}

/// The silhouette itself: the model's own asset when it is available, and the vector fallback
/// when it is not.
@MainActor
private struct VehicleOutlineBaseImage: View {
    let spec: VehicleOutlineSpec
    let og: OutlineGeometry
    let container: CGSize
    var model: VehicleModel? = nil
    var brand: VehicleBrand? = nil

    var body: some View {
        if let svgImage = VehicleOutlineImageProvider.shared.image(for: spec) {
            Image(nsImage: svgImage)
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(HisingenTheme.ink.opacity(0.85))
                .frame(width: og.imageWidth, height: og.imageHeight)
                .position(x: og.originX + og.imageWidth / 2,
                          y: og.originY + og.imageHeight / 2)
        } else {
            FallbackCarSilhouetteView(model: model, brand: brand)
                .frame(width: container.width, height: container.height)
        }
    }
}

/// The soft ellipse under the tires. Placed against the spec's content box so it sits on the
/// ground for every model, however much empty margin its asset carries.
@MainActor
private struct VehicleGroundShadow: View {
    let spec: VehicleOutlineSpec
    let og: OutlineGeometry

    var body: some View {
        let shadow = og.groundShadow(for: spec)
        Ellipse()
            .fill(Color.black.opacity(0.12))
            .frame(width: shadow.size.width, height: shadow.size.height)
            .position(shadow.center)
            .blur(radius: 3)
    }
}

@MainActor
struct VehicleSideProfileDoorsView: View {
    let openings: [OpeningReading]
    var model: VehicleModel? = nil
    var brand: VehicleBrand? = nil
    var hoveredOpening: VehicleOpening? = nil
    /// Reports which part the pointer is over, so the card's chip grid can follow the car rather
    /// than the other way round. Nil when the pointer leaves every zone.
    var onHoverOpening: ((VehicleOpening?) -> Void)? = nil
    /// The natural gesture on a drawn car: point at the door and it does the door's thing.
    var onSelectOpening: ((VehicleOpening) -> Void)? = nil

    private var spec: VehicleOutlineSpec { .spec(for: model) }

    private func reading(for op: VehicleOpening) -> OpeningReading? {
        openings.first(where: { $0.opening == op })
    }

    private func isOpen(_ op: VehicleOpening) -> Bool {
        let state = reading(for: op)?.state
        return state == .open || state == .ajar
    }

    private var frontDoorOpen: Bool { isOpen(.frontLeftDoor) || isOpen(.frontRightDoor) }
    private var rearDoorOpen: Bool { isOpen(.rearLeftDoor) || isOpen(.rearRightDoor) }
    private var frontWindowOpen: Bool { isOpen(.frontLeftWindow) || isOpen(.frontRightWindow) }
    private var rearWindowOpen: Bool { isOpen(.rearLeftWindow) || isOpen(.rearRightWindow) }
    private var hoodOpen: Bool { isOpen(.hood) }
    private var tailgateOpen: Bool { isOpen(.tailgate) }
    private var sunroofOpen: Bool { isOpen(.sunroof) }
    private var chargeLidOpen: Bool { isOpen(.chargeLid) }
    private var fuelFlapOpen: Bool { isOpen(.fuelFlap) }

    private var frontDoorHovered: Bool { hoveredOpening == .frontLeftDoor || hoveredOpening == .frontRightDoor }
    private var rearDoorHovered: Bool { hoveredOpening == .rearLeftDoor || hoveredOpening == .rearRightDoor }
    private var frontWindowHovered: Bool { hoveredOpening == .frontLeftWindow || hoveredOpening == .frontRightWindow }
    private var rearWindowHovered: Bool { hoveredOpening == .rearLeftWindow || hoveredOpening == .rearRightWindow }
    private var hoodHovered: Bool { hoveredOpening == .hood }
    private var tailgateHovered: Bool { hoveredOpening == .tailgate }
    private var sunroofHovered: Bool { hoveredOpening == .sunroof }
    private var chargeLidHovered: Bool { hoveredOpening == .chargeLid }
    private var fuelFlapHovered: Bool { hoveredOpening == .fuelFlap }

    /// This schematic depicts the left side. Opposite-side readings use a neutral tint and
    /// an abbreviation so hovering left and right can never produce identical feedback.
    private var hoveredOpeningIsOppositeSide: Bool {
        switch hoveredOpening {
        case .frontRightDoor, .rearRightDoor, .frontRightWindow, .rearRightWindow: return true
        default: return false
        }
    }

    private var hoverTint: Color {
        hoveredOpeningIsOppositeSide ? Color.gray : HisingenTheme.accent
    }

    private var hoverAbbreviation: String? {
        switch hoveredOpening {
        case .frontLeftDoor, .frontLeftWindow: return "FL"
        case .frontRightDoor, .frontRightWindow: return "FR"
        case .rearLeftDoor, .rearLeftWindow: return "RL"
        case .rearRightDoor, .rearRightWindow: return "RR"
        default: return nil
        }
    }

    var body: some View {
        GeometryReader { geo in
            let og = OutlineGeometry(containerWidth: geo.size.width,
                                     containerHeight: geo.size.height,
                                     spec: spec)

            ZStack {
                VehicleGroundShadow(spec: spec, og: og)

                // The model's own SVG base outline (facing right).
                VehicleOutlineBaseImage(spec: spec, og: og, container: geo.size,
                                        model: model, brand: brand)

                // Lamp glows sit at the clusters the model's own artwork draws, so a Polestar 3's
                // headlamp lights up where a Polestar 3's headlamp is.
                headlightsGlow(
                    og: og,
                    shown: hoodOpen || frontDoorOpen || frontWindowOpen || hoodHovered || frontDoorHovered || frontWindowHovered,
                    active: hoodOpen || frontDoorOpen || frontWindowOpen
                )

                taillightsGlow(
                    og: og,
                    shown: tailgateOpen || rearDoorOpen || rearWindowOpen || chargeLidOpen || fuelFlapOpen || tailgateHovered || rearDoorHovered || rearWindowHovered || chargeLidHovered || fuelFlapHovered,
                    active: tailgateOpen || rearDoorOpen || rearWindowOpen || chargeLidOpen || fuelFlapOpen
                )

                openingZone(
                    zone: .hood, placement: spec.zones.hood,
                    open: hoodOpen, hovered: hoodHovered, og: og
                )

                openingZone(
                    zone: .tailgate, placement: spec.zones.tailgate,
                    open: tailgateOpen, hovered: tailgateHovered, og: og
                )

                openingZone(
                    zone: .frontDoor, placement: spec.zones.frontDoor,
                    open: frontDoorOpen, hovered: frontDoorHovered,
                    hoverColor: hoverTint, hoverBadge: hoverAbbreviation, og: og
                )

                openingZone(
                    zone: .rearDoor, placement: spec.zones.rearDoor,
                    open: rearDoorOpen, hovered: rearDoorHovered,
                    hoverColor: hoverTint, hoverBadge: hoverAbbreviation, og: og
                )

                openingZone(
                    zone: .frontWindow, placement: spec.zones.frontWindow,
                    open: frontWindowOpen, hovered: frontWindowHovered,
                    hoverColor: hoverTint, hoverBadge: hoverAbbreviation, og: og
                )

                openingZone(
                    zone: .rearWindow, placement: spec.zones.rearWindow,
                    open: rearWindowOpen, hovered: rearWindowHovered,
                    hoverColor: hoverTint, hoverBadge: hoverAbbreviation, og: og
                )

                openingZone(
                    zone: .sunroof, placement: spec.zones.sunroof,
                    open: sunroofOpen, hovered: sunroofHovered, og: og
                )

                chargeLidIndicator(
                    placement: spec.zones.chargeLid,
                    open: chargeLidOpen || fuelFlapOpen,
                    hovered: chargeLidHovered || fuelFlapHovered,
                    og: og
                )
            }
        }
        .frame(height: 96)
        // Was `accessibilityHidden(true)`, so a VoiceOver reader got twelve chips and no car. The
        // zones now carry their own names, states and button trait.
        .accessibilityElement(children: .contain)
    }

    /// The openings a zone stands for. The charge lid and the fuel flap are drawn in the same
    /// place, so one zone has to answer for both.
    private func zoneOpenings(_ zone: VehicleOutlineZone) -> [VehicleOpening] {
        switch zone {
        case .hood: return [.hood]
        case .tailgate: return [.tailgate]
        case .frontDoor: return [.frontLeftDoor, .frontRightDoor]
        case .rearDoor: return [.rearLeftDoor, .rearRightDoor]
        case .frontWindow: return [.frontLeftWindow, .frontRightWindow]
        case .rearWindow: return [.rearLeftWindow, .rearRightWindow]
        case .sunroof: return [.sunroof]
        case .chargeLid: return [.chargeLid, .fuelFlap]
        }
    }

    private func openingZone(
        zone: VehicleOutlineZone,
        placement: OutlineZonePlacement,
        open: Bool, hovered: Bool,
        hoverColor: Color? = nil,
        hoverBadge: String? = nil, og: OutlineGeometry
    ) -> some View {
        // The zone stays in the hierarchy and fades/scales on the flag (like
        // tireWheelGlow); animating a view that only exists while `open || hovered`
        // cannot animate its own insertion or removal.
        let visible = open || hovered
        let activeColor = open ? HisingenTheme.semanticWarning : (hoverColor ?? HisingenTheme.accent)
        let resolved = placement.resolved(zone: zone, in: og)
        let shape = OutlineFixedShape(path: resolved.path)
        let zoneOpenings = zoneOpenings(zone)

        return ZStack {
            shape
                .fill(
                    RadialGradient(
                        colors: [activeColor.opacity(open ? 0.30 : 0.20), activeColor.opacity(0.02)],
                        center: resolved.anchor,
                        startRadius: 2,
                        endRadius: resolved.gradientRadius
                    )
                )
                .overlay(
                    shape.stroke(activeColor.opacity(open ? 0.95 : 0.75), lineWidth: open ? 1.5 : 1.0)
                )
            if hovered, let hoverBadge {
                Text(hoverBadge)
                    .hisType(.nano, weight: .bold, design: .rounded)
                    .monospacedDigit()
                    .foregroundStyle(activeColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(HisingenTheme.chipFill, in: Capsule())
                    .offset(x: (resolved.anchor.x - 0.5) * resolved.frame.width,
                            y: (resolved.anchor.y - 0.5) * resolved.frame.height)
            }
        }
        .frame(width: resolved.frame.width, height: resolved.frame.height)
        .shadow(color: activeColor.opacity(open ? 0.40 : 0.20), radius: open ? 3 : 2)
        // Scaling about the part's own centre: a traced zone's frame is the whole car, so a
        // frame-centred pop would slide the hood and the tailgate sideways instead of lifting them.
        .scaleEffect(visible ? 1.02 : 1.0, anchor: resolved.anchor)
        // The zone keeps its own hit area even at rest: `visible` drives the drawing's opacity, and
        // an invisible zone you can still point at is the whole point of this view.
        .contentShape(shape)
        .onHover { inside in
            guard let onHoverOpening else { return }
            if inside {
                onHoverOpening(zoneOpenings.first)
            } else if zoneOpenings.contains(hoveredOpening ?? .hood) {
                onHoverOpening(nil)
            }
        }
        .onTapGesture {
            guard let onSelectOpening, let opening = zoneOpenings.first else { return }
            onSelectOpening(opening)
        }
        .accessibilityElement()
        .accessibilityLabel(zoneOpenings.map(\.displayName).joined(separator: ", "))
        .accessibilityValue(L10n.text(open ? "Open" : "Closed"))
        .accessibilityAddTraits(onSelectOpening == nil ? [] : .isButton)
        .opacity(visible ? 1 : 0)
        .position(x: resolved.frame.midX, y: resolved.frame.midY)
        // Accent→warning recolor and stroke width ride the open flag; the
        // visibility animation below only owns hover in/out.
        .hisAnimation(Motion.stateChange, value: open)
        .hisAnimation(Motion.selection, value: visible)
    }

    private func headlightsGlow(og: OutlineGeometry, shown: Bool, active: Bool) -> some View {
        let color = active ? HisingenTheme.semanticWarning : HisingenTheme.accent
        // Traced lamp cluster centroid, per model — see `VehicleOutlineSpec.headlight`.
        let pos = og.point(u: spec.headlight.x, v: spec.headlight.y)
        let size = og.size(wFraction: 0.13, hFraction: 0.11)

        // Kept in the hierarchy and faded on the flag – a glow that only exists
        // while shown cannot animate its own removal (same rule as openingZone).
        return Ellipse()
            .fill(
                LinearGradient(
                    colors: [color.opacity(0.55), color.opacity(0.0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: size.width, height: size.height)
            .position(pos)
            .blur(radius: 2)
            .opacity(shown ? 1 : 0)
            .hisAnimation(Motion.stateChange, value: shown)
            .hisAnimation(Motion.stateChange, value: active)
    }

    private func taillightsGlow(og: OutlineGeometry, shown: Bool, active: Bool) -> some View {
        let color = active ? HisingenTheme.semanticWarning : HisingenTheme.semanticCritical
        // Traced lamp cluster centroid, per model — see `VehicleOutlineSpec.taillight`.
        let pos = og.point(u: spec.taillight.x, v: spec.taillight.y)
        let size = og.size(wFraction: 0.11, hFraction: 0.12)

        return Ellipse()
            .fill(
                LinearGradient(
                    colors: [color.opacity(0.65), color.opacity(0.0)],
                    startPoint: .trailing,
                    endPoint: .leading
                )
            )
            .frame(width: size.width, height: size.height)
            .position(pos)
            .blur(radius: 2)
            .opacity(shown ? 1 : 0)
            .hisAnimation(Motion.stateChange, value: shown)
            .hisAnimation(Motion.stateChange, value: active)
    }

    private func chargeLidIndicator(
        placement: OutlineZonePlacement,
        open: Bool, hovered: Bool,
        og: OutlineGeometry
    ) -> some View {
        let visible = open || hovered
        let color = open ? HisingenTheme.semanticWarning : HisingenTheme.accent
        let resolved = placement.resolved(zone: .chargeLid, in: og)
        let shape = OutlineFixedShape(path: resolved.path)

        return ZStack {
            shape.fill(color.opacity(open ? 0.60 : 0.40))
            shape.stroke(color, lineWidth: open ? 1.5 : 1.0)
            Circle()
                .fill(Color.white)
                .frame(width: 4, height: 4)
        }
        .frame(width: resolved.frame.width, height: resolved.frame.height)
        .shadow(color: color.opacity(0.6), radius: 3)
        .scaleEffect(visible ? 1.18 : 1.0)
        .opacity(visible ? 1 : 0)
        .position(x: resolved.frame.midX, y: resolved.frame.midY)
        .hisAnimation(Motion.stateChange, value: open)
        .hisAnimation(Motion.selection, value: visible)
    }
}

@MainActor
struct VehicleSideProfileTiresView: View {
    let tyres: [TyrePressure]
    var model: VehicleModel? = nil
    var brand: VehicleBrand? = nil
    var hoveredPosition: TyrePosition? = nil

    private var spec: VehicleOutlineSpec { .spec(for: model) }

    private func tyre(for pos: TyrePosition) -> TyrePressure? {
        tyres.first(where: { $0.position == pos })
    }

    /// Rolls two tyres of an axle up into one level: any attention-needing tyre wins (very low
    /// outranks low/high), explicit OK only when *both* tyres reported OK – an unreported axle
    /// renders muted rather than falsely healthy.
    private func axleState(_ a: TyrePosition, _ b: TyrePosition) -> TyrePressureWarning {
        let pair = [tyre(for: a), tyre(for: b)].compactMap { $0 }.map(\.warning)
        if pair.contains(.veryLow) { return .veryLow }
        if let flagged = pair.first(where: \.needsAttention) { return flagged }
        if pair.contains(.sensorFault) { return .sensorFault }
        if !pair.isEmpty && pair.allSatisfy({ $0 == .none }) { return .none }
        return .unknown
    }

    /// Whether the axle carries at least one numeric pressure reading. An iTPMS axle's
    /// explicit OK carries no measurement, so its ring stays neutral (see `tireWheelGlow`).
    private func axleMeasured(_ a: TyrePosition, _ b: TyrePosition) -> Bool {
        [tyre(for: a), tyre(for: b)].compactMap { $0 }.contains { $0.kilopascals != nil }
    }

    private var frontHovered: Bool { hoveredPosition == .frontLeft || hoveredPosition == .frontRight }
    private var rearHovered: Bool { hoveredPosition == .rearLeft || hoveredPosition == .rearRight }

    var body: some View {
        GeometryReader { geo in
            let og = OutlineGeometry(containerWidth: geo.size.width,
                                     containerHeight: geo.size.height,
                                     spec: spec)

            ZStack {
                VehicleGroundShadow(spec: spec, og: og)

                VehicleOutlineBaseImage(spec: spec, og: og, container: geo.size,
                                        model: model, brand: brand)

                // The model's own wheel circles, so the ring lands on the drawn tire rather than
                // on where a Polestar 2's tire happens to be.
                tireWheelGlow(
                    wheel: spec.rearWheel,
                    state: axleState(.rearLeft, .rearRight), hovered: rearHovered,
                    measured: axleMeasured(.rearLeft, .rearRight),
                    og: og
                )

                tireWheelGlow(
                    wheel: spec.frontWheel,
                    state: axleState(.frontLeft, .frontRight), hovered: frontHovered,
                    measured: axleMeasured(.frontLeft, .frontRight),
                    og: og
                )
            }
        }
        .frame(height: 96)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func tireWheelGlow(
        wheel: OutlineWheel,
        state: TyrePressureWarning, hovered: Bool,
        measured: Bool,
        og: OutlineGeometry
    ) -> some View {
        let alerting = state.needsAttention
        let activeColor: Color = {
            switch state {
            case .none:
                // Green requires an actual measurement. An iTPMS axle reports a warning
                // level only and flags a tyre just once an issue is detected, so its
                // explicit OK stays neutral instead of reading as a verified all-clear.
                return hovered ? HisingenTheme.accent
                    : (measured ? HisingenTheme.semanticGood : HisingenTheme.inkMuted.opacity(0.55))
            case .veryLow, .low, .high, .sensorFault:
                return HisingenTheme.tyreWarningColor(state)
            case .unknown:
                return hovered ? HisingenTheme.accent : HisingenTheme.inkMuted.opacity(0.55)
            }
        }()
        // Ring diameter from the wheel the model's own artwork draws, so a Polestar 3's bigger
        // wheels get a bigger ring instead of a Polestar 2-sized one.
        let ringSize: CGFloat = max(22, og.imageHeight * wheel.radiusFraction * 2)
        let pos = og.point(u: wheel.center.x, v: wheel.center.y)

        ZStack {
            // Pulse halo while hovered or warning. Kept in the hierarchy and
            // faded on the flag so an escalation back to healthy eases out
            // instead of popping (same rule as openingZone).
            Circle()
                .fill(activeColor.opacity(alerting ? 0.35 : 0.22))
                .frame(width: ringSize + 10, height: ringSize + 10)
                .scaleEffect(hovered ? 1.15 : 1.0)
                .blur(radius: 2)
                .opacity(hovered || alerting ? 1 : 0)

            // Outer tire ring border
            Circle()
                .stroke(activeColor.opacity(alerting ? 0.95 : 0.75), lineWidth: alerting ? 2.0 : 1.5)
                .frame(width: ringSize, height: ringSize)
                .shadow(color: activeColor.opacity(alerting ? 0.6 : 0.3), radius: alerting ? 4 : 2)

            // Inner hubcap dot
            Circle()
                .fill(activeColor)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1))
        }
        .position(pos)
        // Severity escalation (low→veryLow) recolors and thickens; keyed on the
        // warning level so it crossfades instead of snapping.
        .hisAnimation(Motion.stateChange, value: state)
        .hisAnimation(Motion.selection, value: hovered || alerting)
    }
}

@MainActor
private struct FallbackCarSilhouetteView: View {
    var model: VehicleModel? = nil
    var brand: VehicleBrand? = nil

    var body: some View {
        let profile = CarProfile.profile(for: model, brand: brand)
        GeometryReader { _ in
            ZStack {
                CarSilhouetteShape(profile: profile)
                    .fill(LinearGradient(colors: [HisingenTheme.ink.opacity(0.14), HisingenTheme.ink.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                    .overlay(CarSilhouetteShape(profile: profile).stroke(HisingenTheme.hairline, lineWidth: 0.8))

                CarGlassShape(profile: profile)
                    .fill(HisingenTheme.ink.opacity(0.22))
            }
        }
    }
}

struct CarProfile: Sendable, Equatable {
    let roofFront: CGPoint
    let roofRear: CGPoint
    let windshieldBase: CGPoint
    let rearGlassBase: CGPoint
    let hoodFront: CGPoint
    let nose: CGPoint
    let frontBumperBase: CGPoint
    let rearBumperTop: CGPoint
    let rearBumperBase: CGPoint
    let frontWheelX: CGFloat
    let rearWheelX: CGFloat
    let wheelRadius: CGFloat
    let wheelCenterY: CGFloat
    let bellyDip: CGFloat

    static let polestar = CarProfile(
        roofFront: CGPoint(x: 0.58, y: 0.12), roofRear: CGPoint(x: 0.36, y: 0.15),
        windshieldBase: CGPoint(x: 0.68, y: 0.44), rearGlassBase: CGPoint(x: 0.14, y: 0.48),
        hoodFront: CGPoint(x: 0.93, y: 0.54), nose: CGPoint(x: 0.985, y: 0.60),
        frontBumperBase: CGPoint(x: 0.94, y: 0.80),
        rearBumperTop: CGPoint(x: 0.05, y: 0.58), rearBumperBase: CGPoint(x: 0.06, y: 0.80),
        frontWheelX: 0.78, rearWheelX: 0.23, wheelRadius: 0.19, wheelCenterY: 0.80, bellyDip: 0.02
    )

    static let volvo = CarProfile(
        roofFront: CGPoint(x: 0.60, y: 0.10), roofRear: CGPoint(x: 0.24, y: 0.10),
        windshieldBase: CGPoint(x: 0.70, y: 0.42), rearGlassBase: CGPoint(x: 0.16, y: 0.24),
        hoodFront: CGPoint(x: 0.92, y: 0.52), nose: CGPoint(x: 0.985, y: 0.58),
        frontBumperBase: CGPoint(x: 0.95, y: 0.80),
        rearBumperTop: CGPoint(x: 0.05, y: 0.26), rearBumperBase: CGPoint(x: 0.06, y: 0.80),
        frontWheelX: 0.79, rearWheelX: 0.22, wheelRadius: 0.205, wheelCenterY: 0.80, bellyDip: 0.015
    )

    static let neutral = CarProfile(
        roofFront: CGPoint(x: 0.58, y: 0.12), roofRear: CGPoint(x: 0.30, y: 0.13),
        windshieldBase: CGPoint(x: 0.68, y: 0.43), rearGlassBase: CGPoint(x: 0.15, y: 0.38),
        hoodFront: CGPoint(x: 0.93, y: 0.53), nose: CGPoint(x: 0.985, y: 0.59),
        frontBumperBase: CGPoint(x: 0.945, y: 0.80),
        rearBumperTop: CGPoint(x: 0.05, y: 0.44), rearBumperBase: CGPoint(x: 0.06, y: 0.80),
        frontWheelX: 0.785, rearWheelX: 0.225, wheelRadius: 0.195, wheelCenterY: 0.80, bellyDip: 0.02
    )

    @MainActor
    static func profile(for model: VehicleModel? = nil, brand: VehicleBrand? = nil) -> CarProfile {
        if let model {
            switch model.brand {
            case .polestar: return .polestar
            case .volvo: return .volvo
            }
        }
        if let brand {
            switch brand {
            case .polestar: return .polestar
            case .volvo: return .volvo
            }
        }
        switch PreferencesStore.shared.activeBrand {
        case .polestar: return .polestar
        case .volvo: return .volvo
        }
    }
}

private struct CarSilhouetteShape: Shape {
    let profile: CarProfile

    private func pt(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let rearBumperBase = pt(profile.rearBumperBase, in: rect)
        let rearBumperTop = pt(profile.rearBumperTop, in: rect)
        let rearGlassBase = pt(profile.rearGlassBase, in: rect)
        let roofRear = pt(profile.roofRear, in: rect)
        let roofFront = pt(profile.roofFront, in: rect)
        let windshieldBase = pt(profile.windshieldBase, in: rect)
        let hoodFront = pt(profile.hoodFront, in: rect)
        let nose = pt(profile.nose, in: rect)
        let frontBumperBase = pt(profile.frontBumperBase, in: rect)

        p.move(to: rearBumperBase)
        p.addQuadCurve(to: rearBumperTop, control: CGPoint(x: rearBumperBase.x - rect.width * 0.02, y: (rearBumperBase.y + rearBumperTop.y) / 2))
        p.addQuadCurve(to: rearGlassBase, control: CGPoint(x: (rearBumperTop.x + rearGlassBase.x) / 2, y: max(rearBumperTop.y, rearGlassBase.y)))
        p.addQuadCurve(to: roofRear, control: CGPoint(x: rearGlassBase.x, y: roofRear.y))
        p.addQuadCurve(to: roofFront, control: CGPoint(x: (roofRear.x + roofFront.x) / 2, y: min(roofRear.y, roofFront.y) - rect.height * 0.02))
        p.addQuadCurve(to: windshieldBase, control: CGPoint(x: windshieldBase.x, y: roofFront.y))
        p.addQuadCurve(to: hoodFront, control: CGPoint(x: (windshieldBase.x + hoodFront.x) / 2, y: hoodFront.y + rect.height * 0.02))
        p.addQuadCurve(to: nose, control: CGPoint(x: nose.x, y: hoodFront.y))
        p.addQuadCurve(to: frontBumperBase, control: CGPoint(x: nose.x, y: frontBumperBase.y))
        p.addQuadCurve(to: rearBumperBase, control: CGPoint(x: rect.midX, y: frontBumperBase.y + rect.height * profile.bellyDip))
        p.closeSubpath()
        return p
    }
}

private struct CarGlassShape: Shape {
    let profile: CarProfile

    func path(in rect: CGRect) -> Path {
        func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height) }
        var p = Path()
        let inset: CGFloat = 0.015
        p.move(to: pt(CGPoint(x: profile.windshieldBase.x - inset, y: profile.windshieldBase.y)))
        p.addQuadCurve(to: pt(profile.roofFront), control: pt(CGPoint(x: profile.windshieldBase.x, y: profile.roofFront.y)))
        p.addLine(to: pt(profile.roofRear))
        p.addQuadCurve(to: pt(CGPoint(x: profile.rearGlassBase.x + inset, y: profile.rearGlassBase.y)), control: pt(CGPoint(x: profile.rearGlassBase.x, y: profile.roofRear.y)))
        p.addLine(to: pt(CGPoint(x: profile.windshieldBase.x - inset, y: profile.windshieldBase.y)))
        p.closeSubpath()
        return p
    }
}
