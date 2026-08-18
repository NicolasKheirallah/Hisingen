import SwiftUI
import AppKit

@MainActor
final class VehicleOutlineImageProvider {
    static let shared = VehicleOutlineImageProvider()

    let image: NSImage?

    init() {
        var loaded: NSImage? = nil

        let rootBundlePath = Bundle.main.bundleURL.appendingPathComponent("Hisingen_Hisingen.bundle").path
        if FileManager.default.fileExists(atPath: rootBundlePath),
           let resBundle = Bundle(path: rootBundlePath),
           let url = resBundle.url(forResource: "polestar_outline", withExtension: "svg") {
            loaded = NSImage(contentsOf: url)
        }

        if loaded == nil,
           let resourceBundlePath = Bundle.main.path(forResource: "Hisingen_Hisingen", ofType: "bundle"),
           let resBundle = Bundle(path: resourceBundlePath),
           let url = resBundle.url(forResource: "polestar_outline", withExtension: "svg") {
            loaded = NSImage(contentsOf: url)
        }

        if loaded == nil, let url = Bundle.main.url(forResource: "polestar_outline", withExtension: "svg") {
            loaded = NSImage(contentsOf: url)
        }

        if loaded == nil {
            let possiblePaths = [
                ".build/arm64-apple-macosx/debug/Hisingen_Hisingen.bundle/polestar_outline.svg",
                ".build/arm64-apple-macosx/release/Hisingen_Hisingen.bundle/polestar_outline.svg",
                "Sources/Hisingen/Resources/polestar_outline.svg",
                "assets/polestar_outline.svg"
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
            self.image = loaded
        } else {
            self.image = nil
        }
    }
}

struct OutlineGeometry {
    static let svgWidth: CGFloat = 1645.0
    static let svgHeight: CGFloat = 769.0
    static let aspectRatio: CGFloat = 1645.0 / 769.0

    let containerWidth: CGFloat
    let containerHeight: CGFloat

    var imageWidth: CGFloat {
        if containerWidth / containerHeight > Self.aspectRatio {
            return containerHeight * Self.aspectRatio
        } else {
            return containerWidth
        }
    }

    var imageHeight: CGFloat {
        if containerWidth / containerHeight > Self.aspectRatio {
            return containerHeight
        } else {
            return containerWidth / Self.aspectRatio
        }
    }

    var originX: CGFloat { (containerWidth - imageWidth) / 2 }
    var originY: CGFloat { (containerHeight - imageHeight) / 2 }

    func point(u: CGFloat, v: CGFloat) -> CGPoint {
        CGPoint(x: originX + u * imageWidth, y: originY + v * imageHeight)
    }

    func size(wFraction: CGFloat, hFraction: CGFloat) -> CGSize {
        CGSize(width: wFraction * imageWidth, height: hFraction * imageHeight)
    }
}

@MainActor
struct VehicleSideProfileDoorsView: View {
    let openings: [OpeningReading]
    let isLocked: Bool?
    var hoveredOpening: VehicleOpening? = nil

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

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let og = OutlineGeometry(containerWidth: w, containerHeight: h)

            ZStack {
                // Ground shadow
                Ellipse()
                    .fill(Color.black.opacity(0.12))
                    .frame(width: og.imageWidth * 0.90, height: og.imageHeight * 0.10)
                    .position(x: og.originX + og.imageWidth * 0.50, y: og.originY + og.imageHeight * 0.90)
                    .blur(radius: 3)

                // Vehicle SVG base outline (facing right)
                if let svgImage = VehicleOutlineImageProvider.shared.image {
                    Image(nsImage: svgImage)
                        .resizable()
                        .renderingMode(.template)
                        .foregroundStyle(HisingenTheme.ink.opacity(0.85))
                        .aspectRatio(1645 / 769, contentMode: .fit)
                        .frame(width: w, height: h)
                } else {
                    FallbackCarSilhouetteView()
                        .frame(width: w, height: h)
                }

                // --- INTERACTIVE ANIMATED GLOW ZONES ---

                // 1. Front Headlights Beam (traced lamp cluster: SVG X=[1419..1583], Y=[347..407])
                if hoodOpen || frontDoorOpen || frontWindowOpen || hoodHovered || frontDoorHovered || frontWindowHovered {
                    headlightsGlow(og: og, active: hoodOpen || frontDoorOpen || frontWindowOpen, hovered: hoodHovered || frontDoorHovered || frontWindowHovered)
                }

                // 2. Rear Taillights Glow (traced lamp cluster: SVG X=[72..211], Y=[278..343])
                if tailgateOpen || rearDoorOpen || rearWindowOpen || chargeLidOpen || fuelFlapOpen || tailgateHovered || rearDoorHovered || rearWindowHovered || chargeLidHovered || fuelFlapHovered {
                    taillightsGlow(og: og, active: tailgateOpen || rearDoorOpen || rearWindowOpen || chargeLidOpen || fuelFlapOpen, hovered: tailgateHovered || rearDoorHovered || rearWindowHovered || chargeLidHovered || fuelFlapHovered)
                }

                // 3. Hood Zone (traced bonnet sliver: SVG X=[1122..1541], Y=[275..361])
                openingZone(
                    kind: .hood,
                    u: 0.8094, v: 0.4135,
                    wFraction: 0.2369, hFraction: 0.1040,
                    open: hoodOpen, hovered: hoodHovered,
                    label: "Hood", og: og
                )

                // 4. Tailgate Zone (traced rear hatch cluster: SVG X=[45..410], Y=[156..479])
                openingZone(
                    kind: .tailgate,
                    u: 0.1383, v: 0.4129,
                    wFraction: 0.2064, hFraction: 0.3906,
                    open: tailgateOpen, hovered: tailgateHovered,
                    label: "Tailgate", og: og
                )

                // 5. Front Door Zone (traced door skin + rocker sill: SVG X=[766..1152], Y=[288..545])
                openingZone(
                    kind: .frontDoor,
                    u: 0.5830, v: 0.5416,
                    wFraction: 0.2183, hFraction: 0.3108,
                    open: frontDoorOpen, hovered: frontDoorHovered,
                    label: "Front Door", og: og
                )

                // 6. Rear Door Zone (traced door skin + rocker sill: SVG X=[414..781], Y=[276..539])
                openingZone(
                    kind: .rearDoor,
                    u: 0.3632, v: 0.5299,
                    wFraction: 0.2075, hFraction: 0.3181,
                    open: rearDoorOpen, hovered: rearDoorHovered,
                    label: "Rear Door", og: og
                )

                // 7. Front Window Zone (SVG X=[730..1125], Y=[153..293])
                openingZone(
                    kind: .frontWindow,
                    u: 0.5638, v: 0.2900,
                    wFraction: 0.2401, hFraction: 0.1820,
                    open: frontWindowOpen, hovered: frontWindowHovered,
                    label: "Front Window", og: og
                )

                // 8. Rear Window Zone (SVG X=[414..759], Y=[152..275])
                openingZone(
                    kind: .rearWindow,
                    u: 0.3565, v: 0.2776,
                    wFraction: 0.2097, hFraction: 0.1599,
                    open: rearWindowOpen, hovered: rearWindowHovered,
                    label: "Rear Window", og: og
                )

                // 9. Sunroof Zone (Roofline: SVG X=[432..965], Y=[124..160])
                openingZone(
                    kind: .sunroof,
                    u: 0.4246, v: 0.1850,
                    wFraction: 0.3240, hFraction: 0.0600,
                    open: sunroofOpen, hovered: sunroofHovered,
                    label: "Sunroof", og: og
                )

                // 10. Charge Lid / Fuel Flap Indicator (SVG X=[290..381], Y=[281..331])
                chargeLidIndicator(
                    u: 0.2040, v: 0.3979,
                    wFraction: 0.0553, hFraction: 0.0650,
                    open: chargeLidOpen || fuelFlapOpen,
                    hovered: chargeLidHovered || fuelFlapHovered,
                    og: og
                )
            }
        }
        .frame(height: 96)
        .accessibilityHidden(true)
    }

    enum OpeningZoneKind {
        case hood, tailgate, frontDoor, rearDoor, frontWindow, rearWindow, sunroof, chargeLid
    }

    @ViewBuilder
    private func openingZone(
        kind: OpeningZoneKind,
        u: CGFloat, v: CGFloat,
        wFraction: CGFloat, hFraction: CGFloat,
        open: Bool, hovered: Bool,
        label: String, og: OutlineGeometry
    ) -> some View {
        if open || hovered {
            let activeColor = open ? HisingenTheme.semanticWarning : HisingenTheme.accent
            let pos = og.point(u: u, v: v)
            let size = og.size(wFraction: wFraction, hFraction: hFraction)

            zoneShape(kind: kind)
                .fill(
                    RadialGradient(
                        colors: [activeColor.opacity(open ? 0.30 : 0.20), activeColor.opacity(0.02)],
                        center: .center,
                        startRadius: 2,
                        endRadius: max(size.width, size.height) * 0.55
                    )
                )
                .overlay(
                    zoneShape(kind: kind)
                        .stroke(activeColor.opacity(open ? 0.95 : 0.75), lineWidth: open ? 1.5 : 1.0)
                )
                .frame(width: size.width, height: size.height)
                .shadow(color: activeColor.opacity(open ? 0.40 : 0.20), radius: open ? 3 : 2)
                .scaleEffect(hovered || open ? 1.02 : 1.0)
                .position(pos)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: open || hovered)
        }
    }

    private func zoneShape(kind: OpeningZoneKind) -> OutlineAnyShape {
        switch kind {
        case .frontWindow: return OutlineAnyShape(FrontWindowContourShape())
        case .rearWindow: return OutlineAnyShape(RearWindowContourShape())
        case .frontDoor: return OutlineAnyShape(FrontDoorContourShape())
        case .rearDoor: return OutlineAnyShape(RearDoorContourShape())
        case .hood: return OutlineAnyShape(HoodContourShape())
        case .tailgate: return OutlineAnyShape(TailgateContourShape())
        case .sunroof: return OutlineAnyShape(SunroofContourShape())
        case .chargeLid: return OutlineAnyShape(ChargeLidContourShape())
        }
    }

    @ViewBuilder
    private func headlightsGlow(og: OutlineGeometry, active: Bool, hovered: Bool) -> some View {
        let color = active ? HisingenTheme.semanticWarning : HisingenTheme.accent
        // Traced lamp cluster centroid: SVG X=[1419..1583], Y=[347..407]
        let pos = og.point(u: 0.9125, v: 0.4902)
        let size = og.size(wFraction: 0.13, hFraction: 0.11)

        Ellipse()
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
            .animation(.easeInOut(duration: 0.2), value: active || hovered)
    }

    @ViewBuilder
    private func taillightsGlow(og: OutlineGeometry, active: Bool, hovered: Bool) -> some View {
        let color = active ? HisingenTheme.semanticWarning : Color.red
        // Traced lamp cluster centroid: SVG X=[72..211], Y=[278..343]
        let pos = og.point(u: 0.0860, v: 0.4038)
        let size = og.size(wFraction: 0.11, hFraction: 0.12)

        Ellipse()
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
            .animation(.easeInOut(duration: 0.2), value: active || hovered)
    }

    @ViewBuilder
    private func chargeLidIndicator(
        u: CGFloat, v: CGFloat,
        wFraction: CGFloat, hFraction: CGFloat,
        open: Bool, hovered: Bool,
        og: OutlineGeometry
    ) -> some View {
        if open || hovered {
            let color = open ? HisingenTheme.semanticWarning : HisingenTheme.accent
            let pos = og.point(u: u, v: v)
            let size = og.size(wFraction: wFraction, hFraction: hFraction)

            ZStack {
                ChargeLidContourShape()
                    .fill(color.opacity(open ? 0.60 : 0.40))
                    .frame(width: size.width, height: size.height)
                ChargeLidContourShape()
                    .stroke(color, lineWidth: open ? 1.5 : 1.0)
                    .frame(width: size.width, height: size.height)
                Circle()
                    .fill(Color.white)
                    .frame(width: 4, height: 4)
            }
            .shadow(color: color.opacity(0.6), radius: 3)
            .scaleEffect(hovered || open ? 1.18 : 1.0)
            .position(pos)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: open || hovered)
        }
    }
}

struct OutlineAnyShape: Shape, @unchecked Sendable {
    private let _path: @Sendable (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        self._path = { shape.path(in: $0) }
    }

    func path(in rect: CGRect) -> Path {
        _path(rect)
    }
}

// MARK: - Exact SVG Contour Shapes

struct FrontWindowContourShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.58, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.minX + rect.width * 0.88, y: rect.minY + rect.height * 0.45)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct RearWindowContourShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.72))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.minY + rect.height * 0.04),
            control: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.28)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct FrontDoorContourShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.12))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.10),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}

struct RearDoorContourShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.10))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - rect.width * 0.10, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.35),
            control: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.maxY - rect.height * 0.15)
        )
        path.closeSubpath()
        return path
    }
}

struct HoodContourShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.58),
            control: CGPoint(x: rect.minX + rect.width * 0.65, y: rect.minY + rect.height * 0.15)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct TailgateContourShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.20, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55),
            control: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.20)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - rect.width * 0.25, y: rect.minY),
            control: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.minY + rect.height * 0.15)
        )
        path.closeSubpath()
        return path
    }
}

struct SunroofContourShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: 4, height: 4))
        return path
    }
}

struct ChargeLidContourShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: 3, height: 3))
        return path
    }
}

@MainActor
struct VehicleSideProfileTiresView: View {
    let tyres: [TyrePressure]
    var hoveredPosition: TyrePosition? = nil

    private func tyre(for pos: TyrePosition) -> TyrePressure? {
        tyres.first(where: { $0.position == pos })
    }

    private var frontWarning: Bool { tyre(for: .frontLeft)?.warning.needsAttention == true || tyre(for: .frontRight)?.warning.needsAttention == true }
    private var rearWarning: Bool { tyre(for: .rearLeft)?.warning.needsAttention == true || tyre(for: .rearRight)?.warning.needsAttention == true }
    private var frontHovered: Bool { hoveredPosition == .frontLeft || hoveredPosition == .frontRight }
    private var rearHovered: Bool { hoveredPosition == .rearLeft || hoveredPosition == .rearRight }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let og = OutlineGeometry(containerWidth: w, containerHeight: h)

            ZStack {
                // Ground shadow
                Ellipse()
                    .fill(Color.black.opacity(0.12))
                    .frame(width: og.imageWidth * 0.90, height: og.imageHeight * 0.10)
                    .position(x: og.originX + og.imageWidth * 0.50, y: og.originY + og.imageHeight * 0.90)
                    .blur(radius: 3)

                // Vehicle SVG base outline
                if let svgImage = VehicleOutlineImageProvider.shared.image {
                    Image(nsImage: svgImage)
                        .resizable()
                        .renderingMode(.template)
                        .foregroundStyle(HisingenTheme.ink.opacity(0.85))
                        .aspectRatio(1645 / 769, contentMode: .fit)
                        .frame(width: w, height: h)
                } else {
                    FallbackCarSilhouetteView()
                        .frame(width: w, height: h)
                }

                // Rear Wheel (SVG X=379, Y=516 -> u=0.2304, v=0.6710)
                tireWheelGlow(
                    u: 0.2304, v: 0.6710,
                    warning: rearWarning, hovered: rearHovered,
                    positionName: hoveredPosition == .rearRight ? "RR" : "RL",
                    og: og
                )

                // Front Wheel (SVG X=1322, Y=516 -> u=0.8036, v=0.6710)
                tireWheelGlow(
                    u: 0.8036, v: 0.6710,
                    warning: frontWarning, hovered: frontHovered,
                    positionName: hoveredPosition == .frontRight ? "FR" : "FL",
                    og: og
                )
            }
        }
        .frame(height: 96)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func tireWheelGlow(
        u: CGFloat, v: CGFloat,
        warning: Bool, hovered: Bool,
        positionName: String,
        og: OutlineGeometry
    ) -> some View {
        let activeColor = warning ? HisingenTheme.semanticWarning : (hovered ? HisingenTheme.accent : HisingenTheme.semanticGood)
        // Scaled wheel rim ring proportional to the vehicle height (202px in 769px SVG = 0.2627 * imageHeight)
        let ringSize: CGFloat = max(22, og.imageHeight * 0.2627)
        let pos = og.point(u: u, v: v)

        ZStack {
            // Animated pulse halo when hovered or warning
            if hovered || warning {
                Circle()
                    .fill(activeColor.opacity(warning ? 0.35 : 0.22))
                    .frame(width: ringSize + 10, height: ringSize + 10)
                    .scaleEffect(hovered ? 1.15 : 1.0)
                    .blur(radius: 2)
            }

            // Outer tire ring border
            Circle()
                .stroke(activeColor.opacity(warning ? 0.95 : 0.75), lineWidth: warning ? 2.0 : 1.5)
                .frame(width: ringSize, height: ringSize)
                .shadow(color: activeColor.opacity(warning ? 0.6 : 0.3), radius: warning ? 4 : 2)

            // Inner hubcap dot
            Circle()
                .fill(activeColor)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1))
        }
        .position(pos)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovered || warning)
    }
}

@MainActor
private struct FallbackCarSilhouetteView: View {
    var body: some View {
        let profile = CarProfile.current
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

private struct CarProfile {
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
    static var current: CarProfile {
        switch PreferencesStore().appTheme {
        case .polestar, .cyanRacing: return .polestar
        case .volvo, .swedishGold, .sandDune: return .volvo
        case .hisingen, .nordicNight, .aurora, .forest: return .neutral
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
