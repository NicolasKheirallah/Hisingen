import SwiftUI

// MARK: - Which silhouette, and where its parts are

/// One highlighted part of the side profile.
///
/// The cases match `VehicleOpening` groups rather than individual readings: the drawing shows one
/// side, so a zone answers for both sides of the car (see `VehicleSideProfileDoorsView`).
enum VehicleOutlineZone: CaseIterable, Hashable, Sendable {
    case hood
    case tailgate
    case frontDoor
    case rearDoor
    case frontWindow
    case rearWindow
    case sunroof
    case chargeLid
}

/// A single outline traced from a model's own artwork, in 0…1 silhouette space.
///
/// The coordinates are plain numbers because they cannot be computed: they were read off the SVG
/// assets by hand. Keeping the path as data rather than as a `Shape` per part means one renderer
/// draws every model's hotspots, and a new model is only ever a new table of numbers.
struct OutlinePath: Sendable {
    enum Command: Sendable {
        case move(CGFloat, CGFloat)
        case line(CGFloat, CGFloat)
        case quad(CGFloat, CGFloat, cx: CGFloat, cy: CGFloat)
        case curve(CGFloat, CGFloat, c1x: CGFloat, c1y: CGFloat, c2x: CGFloat, c2y: CGFloat)
        case close
    }

    let commands: [Command]

    /// Builds the path inside `rect`, mapping 0…1 to that rect on both axes.
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }

        var path = Path()
        for command in commands {
            switch command {
            case .move(let x, let y):
                path.move(to: point(x, y))
            case .line(let x, let y):
                path.addLine(to: point(x, y))
            case .quad(let x, let y, let cx, let cy):
                path.addQuadCurve(to: point(x, y), control: point(cx, cy))
            case .curve(let x, let y, let c1x, let c1y, let c2x, let c2y):
                path.addCurve(to: point(x, y), control1: point(c1x, c1y), control2: point(c2x, c2y))
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }

    /// The drawn anchors' bounds in 0…1 space. Curves are bounded by their control points, which
    /// overestimates slightly — enough to place a hover badge, and never used for hit testing.
    var normalizedBounds: CGRect {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        func include(_ x: CGFloat, _ y: CGFloat) {
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }

        for command in commands {
            switch command {
            case .move(let x, let y), .line(let x, let y):
                include(x, y)
            case .quad(let x, let y, let cx, let cy):
                include(x, y); include(cx, cy)
            case .curve(let x, let y, let c1x, let c1y, let c2x, let c2y):
                include(x, y); include(c1x, c1y); include(c2x, c2y)
            case .close:
                break
            }
        }

        guard minX <= maxX, minY <= maxY else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Where one zone sits on one model.
enum OutlineZonePlacement: Sendable {
    /// A hand-traced contour drawn into a frame centred on the silhouette. The Polestar 2 asset is
    /// a wireframe whose panels were traced into `*ContourShape` before the per-model artwork
    /// existed, so it keeps that representation; the shape is chosen by the zone itself.
    case frame(center: CGPoint, size: CGSize)
    /// The exact outline traced from this model's own artwork. Absolute in the silhouette frame,
    /// so it needs no centre or size of its own.
    case traced(OutlinePath)
}

/// A wheel to ring on the silhouette.
struct OutlineWheel: Sendable {
    /// Centre in 0…1 silhouette space.
    let center: CGPoint
    /// Tire radius as a fraction of the silhouette frame's *height*, so the ring stays circular
    /// however wide the card is (the frame is always fitted to the asset's aspect ratio).
    let radiusFraction: CGFloat
}

/// Every zone a spec must place, named rather than keyed so a model cannot ship with a hole in it.
struct VehicleOutlineZones: Sendable {
    let hood: OutlineZonePlacement
    let tailgate: OutlineZonePlacement
    let frontDoor: OutlineZonePlacement
    let rearDoor: OutlineZonePlacement
    let frontWindow: OutlineZonePlacement
    let rearWindow: OutlineZonePlacement
    let sunroof: OutlineZonePlacement
    let chargeLid: OutlineZonePlacement

    subscript(zone: VehicleOutlineZone) -> OutlineZonePlacement {
        switch zone {
        case .hood: return hood
        case .tailgate: return tailgate
        case .frontDoor: return frontDoor
        case .rearDoor: return rearDoor
        case .frontWindow: return frontWindow
        case .rearWindow: return rearWindow
        case .sunroof: return sunroof
        case .chargeLid: return chargeLid
        }
    }
}

/// Everything the side profile needs to draw one vehicle: which asset, how much of it is car, and
/// where that car's parts are.
///
/// One spec per model rather than one per brand, because the three silhouettes are different cars
/// with different panels in different places — a Polestar 3 owner should not be shown a Polestar 2
/// with the doors roughly in the right spot.
struct VehicleOutlineSpec: Sendable {
    /// Bundled SVG asset name, without extension.
    let assetName: String
    /// The asset's own user-unit size — its SVG viewBox.
    let naturalSize: CGSize
    /// The slice of the asset the vehicle's ink actually occupies, in 0…1 asset space, measured
    /// from the rendered SVG. The Polestar 2 asset carries generous empty margins while the 3 and
    /// 4 assets are drawn tight to their viewBoxes, so presenting each asset edge-to-edge would
    /// draw a Polestar 3 half again larger than a Polestar 2 in the same card.
    let contentBox: CGRect
    let zones: VehicleOutlineZones
    let frontWheel: OutlineWheel
    let rearWheel: OutlineWheel
    /// Soft lamp glows, in 0…1 silhouette space.
    let headlight: CGPoint
    let taillight: CGPoint

    var aspectRatio: CGFloat { naturalSize.width / naturalSize.height }

    /// Scale applied to the fitted asset so every model's ink lands at the same on-screen height
    /// as the Polestar 2's. Never above 1: an asset already tighter than the reference is drawn
    /// as-is rather than cropped by the frame.
    var contentScale: CGFloat {
        guard contentBox.height > 0 else { return 1 }
        return min(1, Self.referenceContentHeight / contentBox.height)
    }

    /// The Polestar 2 asset's ink height, which every other silhouette is matched against. Pinned
    /// to that asset rather than picked as a round number so the original profile's framing — the
    /// one the card was designed around — is unchanged.
    static let referenceContentHeight: CGFloat = 0.6738

    static func spec(for model: VehicleModelFamily?) -> VehicleOutlineSpec {
        switch model {
        case .polestar3: return .polestar3
        case .polestar4: return .polestar4
        // Everything else — Polestar 1, 2, 5, 6, every Volvo, and an unrecognised model — keeps
        // the outline that shipped first rather than showing no car at all.
        default: return .polestar2
        }
    }
}

// MARK: - Polestar 2

extension VehicleOutlineSpec {
    /// The original outline. Its zones are the hand-traced contours described on
    /// `OutlineZonePlacement.frame`, positioned by the fractions they have always used.
    static let polestar2 = VehicleOutlineSpec(
        assetName: "polestar_outline",
        naturalSize: CGSize(width: 1645, height: 769),
        contentBox: CGRect(x: 0.0267, y: 0.1619, width: 0.9411, height: 0.6738),
        zones: VehicleOutlineZones(
            hood: .frame(center: CGPoint(x: 0.8094, y: 0.4135),
                         size: CGSize(width: 0.2369, height: 0.1040)),
            tailgate: .frame(center: CGPoint(x: 0.1383, y: 0.4129),
                             size: CGSize(width: 0.2064, height: 0.3906)),
            frontDoor: .frame(center: CGPoint(x: 0.5830, y: 0.5416),
                              size: CGSize(width: 0.2183, height: 0.3108)),
            rearDoor: .frame(center: CGPoint(x: 0.3632, y: 0.5299),
                             size: CGSize(width: 0.2075, height: 0.3181)),
            frontWindow: .frame(center: CGPoint(x: 0.5638, y: 0.2900),
                                size: CGSize(width: 0.2401, height: 0.1820)),
            rearWindow: .frame(center: CGPoint(x: 0.3565, y: 0.2776),
                               size: CGSize(width: 0.2097, height: 0.1599)),
            sunroof: .frame(center: CGPoint(x: 0.4246, y: 0.1850),
                            size: CGSize(width: 0.3240, height: 0.0600)),
            chargeLid: .frame(center: CGPoint(x: 0.2040, y: 0.3979),
                              size: CGSize(width: 0.0553, height: 0.0650))
        ),
        frontWheel: OutlineWheel(center: CGPoint(x: 0.8036, y: 0.6710), radiusFraction: 0.13135),
        rearWheel: OutlineWheel(center: CGPoint(x: 0.2304, y: 0.6710), radiusFraction: 0.13135),
        headlight: CGPoint(x: 0.9125, y: 0.4902),
        taillight: CGPoint(x: 0.0860, y: 0.4038)
    )
}

// MARK: - Polestar 3

extension VehicleOutlineSpec {
    /// Traced from `Polestar3silhouette.svg` via the interactive-parts overlay that accompanies it,
    /// which lays its hotspots out in a 1800×600 space scaled onto the 2172×724 viewBox. Every
    /// fraction below is that overlay's own coordinate divided by 1800 (across) or 600 (down).
    static let polestar3 = VehicleOutlineSpec(
        assetName: "Polestar3silhouette",
        naturalSize: CGSize(width: 2172, height: 724),
        contentBox: CGRect(x: 0.0344, y: 0.0267, width: 0.9245, height: 0.9266),
        zones: VehicleOutlineZones(
            hood: .traced(OutlinePath(commands: [
                .move(0.7106, 0.3067),
                .curve(0.8522, 0.3517, c1x: 0.7617, c1y: 0.315, c2x: 0.81, c2y: 0.3283),
                .curve(0.9461, 0.4467, c1x: 0.8889, c1y: 0.3717, c2x: 0.9206, c2y: 0.405),
                .line(0.9506, 0.46),
                .line(0.9467, 0.4733),
                .curve(0.85, 0.385, c1x: 0.9189, c1y: 0.435, c2x: 0.8878, c2y: 0.405),
                .curve(0.7139, 0.34, c1x: 0.8094, c1y: 0.3633, c2x: 0.7617, c2y: 0.3483),
                .line(0.6933, 0.335),
                .line(0.6822, 0.3183),
                .close
            ])),
            tailgate: .traced(OutlinePath(commands: [
                .move(0.0694, 0.1267),
                .quad(0.1506, 0.1033, cx: 0.1167, cy: 0.095),
                .line(0.1211, 0.17),
                .line(0.0989, 0.2317),
                .line(0.0806, 0.3),
                .line(0.1061, 0.3183),
                .line(0.1217, 0.3767),
                .line(0.1072, 0.43),
                .line(0.0806, 0.4617),
                .line(0.04, 0.3983),
                .line(0.0389, 0.31),
                .line(0.0794, 0.2983),
                .line(0.0861, 0.1917),
                .quad(0.0694, 0.1267, cx: 0.0828, cy: 0.1583),
                .close
            ])),
            frontDoor: .traced(OutlinePath(commands: [
                .move(0.4767, 0.3083),
                .curve(0.6656, 0.3267, c1x: 0.5367, c1y: 0.3133, c2x: 0.6, c2y: 0.3183),
                .curve(0.6911, 0.3967, c1x: 0.6783, c1y: 0.3367, c2x: 0.6872, c2y: 0.3617),
                .curve(0.695, 0.5983, c1x: 0.695, c1y: 0.445, c2x: 0.6956, c2y: 0.5217),
                .curve(0.6917, 0.6917, c1x: 0.6944, c1y: 0.6367, c2x: 0.6933, c2y: 0.6717),
                .line(0.4794, 0.6917),
                .curve(0.4778, 0.4983, c1x: 0.48, c1y: 0.63, c2x: 0.4789, c2y: 0.5633),
                .curve(0.4722, 0.315, c1x: 0.4767, c1y: 0.4283, c2x: 0.4744, c2y: 0.3633),
                .close
            ])),
            rearDoor: .traced(OutlinePath(commands: [
                .move(0.2544, 0.3083),
                .curve(0.455, 0.3033, c1x: 0.3133, c1y: 0.29, c2x: 0.3833, c2y: 0.2917),
                .curve(0.465, 0.53, c1x: 0.4589, c1y: 0.37, c2x: 0.4628, c2y: 0.4483),
                .curve(0.4672, 0.6917, c1x: 0.4667, c1y: 0.59, c2x: 0.4678, c2y: 0.645),
                .line(0.3078, 0.6917),
                .curve(0.2922, 0.5383, c1x: 0.305, c1y: 0.6383, c2x: 0.3, c2y: 0.5833),
                .curve(0.2606, 0.4467, c1x: 0.2844, c1y: 0.4933, c2x: 0.2739, c2y: 0.4633),
                .curve(0.2533, 0.33, c1x: 0.255, c1y: 0.405, c2x: 0.2528, c2y: 0.3633),
                .curve(0.2544, 0.3083, c1x: 0.2533, c1y: 0.3183, c2x: 0.2539, c2y: 0.3133),
                .close
            ])),
            // The front door's glass.
            frontWindow: .traced(OutlinePath(commands: [
                .move(0.4544, 0.08),
                .quad(0.5472, 0.1, cx: 0.5044, cy: 0.0817),
                .line(0.6294, 0.2267),
                .line(0.6211, 0.2967),
                .line(0.4778, 0.2933),
                .close
            ])),
            // The rear door's glass plus the quarter light behind it: the API reports one state for
            // the rear windows, so both panes light together.
            rearWindow: .traced(OutlinePath(commands: [
                .move(0.1972, 0.1333),
                .line(0.3, 0.0733),
                .line(0.2817, 0.2467),
                .line(0.245, 0.2667),
                .quad(0.2022, 0.225, cx: 0.2244, cy: 0.255),
                .line(0.1833, 0.185),
                .close,
                .move(0.3106, 0.0867),
                .quad(0.4322, 0.0783, cx: 0.3711, cy: 0.075),
                .line(0.4417, 0.2933),
                .line(0.3189, 0.28),
                .quad(0.2817, 0.2467, cx: 0.2978, cy: 0.2733),
                .close
            ])),
            // No sunroof hotspot ships with the Polestar 3 artwork. Traced instead along the
            // roofline measured from the asset (its topmost ink, sampled across the middle),
            // which is where a glass roof sits on this car.
            sunroof: .traced(OutlinePath(commands: [
                .move(0.26, 0.0607),
                .line(0.3, 0.0507),
                .line(0.34, 0.044),
                .line(0.38, 0.0407),
                .line(0.42, 0.0407),
                .line(0.46, 0.044),
                .line(0.5, 0.0507),
                .line(0.54, 0.0673),
                .line(0.575, 0.094),
                .line(0.575, 0.126),
                .line(0.54, 0.0993),
                .line(0.5, 0.0827),
                .line(0.46, 0.076),
                .line(0.42, 0.0727),
                .line(0.38, 0.0727),
                .line(0.34, 0.076),
                .line(0.3, 0.0827),
                .line(0.26, 0.0927),
                .close
            ])),
            // Also absent from the overlay. Traced from the charge-flap outline drawn in the asset
            // itself (its second path element), whose viewBox bounds are x 335.7…442.3, y 234.2…286.
            chargeLid: .frame(center: CGPoint(x: 0.1791, y: 0.3593),
                              size: CGSize(width: 0.0491, height: 0.0715))
        ),
        frontWheel: OutlineWheel(center: CGPoint(x: 0.8178, y: 0.7167), radiusFraction: 0.24167),
        rearWheel: OutlineWheel(center: CGPoint(x: 0.2089, y: 0.7167), radiusFraction: 0.24167),
        // The lamp clusters drawn in the asset: the headlamp at viewBox x 1943…2081, y 295…362 and
        // the full-width tail bar at x 89…264, y 230…274.
        headlight: CGPoint(x: 0.9220, y: 0.4520),
        taillight: CGPoint(x: 0.0814, y: 0.3481)
    )
}

// MARK: - Polestar 4

extension VehicleOutlineSpec {
    /// Traced from `Polestar4silhouette.svg` via its interactive-parts overlay, which lays the
    /// hotspots out in a 1600×569 space scaled onto the 2103×748 viewBox. Fractions are the
    /// overlay's coordinates divided by 1600 (across) or 569 (down).
    static let polestar4 = VehicleOutlineSpec(
        assetName: "Polestar4silhouette",
        naturalSize: CGSize(width: 2103, height: 748),
        contentBox: CGRect(x: 0.0289, y: 0.0719, width: 0.9533, height: 0.8250),
        zones: VehicleOutlineZones(
            hood: .traced(OutlinePath(commands: [
                .move(0.7175, 0.3146),
                .quad(0.8337, 0.3339, cx: 0.7806, cy: 0.3111),
                .quad(0.9237, 0.4077, cx: 0.8825, cy: 0.355),
                .line(0.9025, 0.42),
                .quad(0.8037, 0.3726, cx: 0.8544, cy: 0.3814),
                .quad(0.73, 0.3726, cx: 0.7631, cy: 0.3656),
                .quad(0.7175, 0.3146, cx: 0.7262, cy: 0.3339),
                .close
            ])),
            tailgate: .traced(OutlinePath(commands: [
                .move(0.0387, 0.2953),
                .quad(0.1206, 0.3234, cx: 0.0781, cy: 0.3005),
                .line(0.0981, 0.3814),
                .line(0.1319, 0.4833),
                .line(0.0881, 0.5202),
                .quad(0.0663, 0.4341, cx: 0.0788, cy: 0.471),
                .line(0.0338, 0.4165),
                .line(0.0338, 0.3339),
                .quad(0.0387, 0.2953, cx: 0.0356, cy: 0.3128),
                .close
            ])),
            frontDoor: .traced(OutlinePath(commands: [
                .move(0.4881, 0.3234),
                .line(0.7013, 0.3163),
                .quad(0.7238, 0.4077, cx: 0.7212, cy: 0.3357),
                .line(0.7212, 0.7575),
                .line(0.4981, 0.7575),
                .quad(0.4975, 0.5167, cx: 0.4988, cy: 0.6257),
                .quad(0.4881, 0.3234, cx: 0.4963, cy: 0.3919),
                .close
            ])),
            rearDoor: .traced(OutlinePath(commands: [
                .move(0.2531, 0.2759),
                .line(0.2863, 0.2689),
                .quad(0.4619, 0.3111, cx: 0.3756, cy: 0.3005),
                .line(0.4831, 0.3199),
                .quad(0.4919, 0.5026, cx: 0.49, cy: 0.3796),
                .line(0.4925, 0.7575),
                .line(0.2919, 0.7575),
                .quad(0.2881, 0.6573, cx: 0.2919, cy: 0.6995),
                .quad(0.2694, 0.5641, cx: 0.2819, cy: 0.5923),
                .quad(0.2531, 0.536, cx: 0.2625, cy: 0.5483),
                .close
            ])),
            frontWindow: .traced(OutlinePath(commands: [
                .move(0.4894, 0.1142),
                .quad(0.6031, 0.1582, cx: 0.5519, cy: 0.1142),
                .quad(0.6994, 0.3023, cx: 0.6512, cy: 0.2004),
                .line(0.5069, 0.3023),
                .line(0.4913, 0.1142),
                .close
            ])),
            // The rear door's glass plus the quarter light, matching the Polestar 3 treatment.
            rearWindow: .traced(OutlinePath(commands: [
                .move(0.2169, 0.2267),
                .quad(0.2694, 0.1424, cx: 0.2338, cy: 0.1757),
                .quad(0.3094, 0.1178, cx: 0.2888, cy: 0.1248),
                .line(0.2831, 0.2566),
                .quad(0.2169, 0.2267, cx: 0.2506, cy: 0.2443),
                .close,
                .move(0.3144, 0.1178),
                .quad(0.455, 0.1142, cx: 0.3775, cy: 0.1002),
                .line(0.4612, 0.3005),
                .quad(0.2881, 0.2601, cx: 0.3719, cy: 0.2917),
                .close
            ])),
            // Traced along this silhouette's own roofline, the same way as the Polestar 3 band.
            sunroof: .traced(OutlinePath(commands: [
                .move(0.25, 0.1344),
                .line(0.3, 0.1126),
                .line(0.35, 0.1001),
                .line(0.4, 0.0908),
                .line(0.45, 0.0877),
                .line(0.5, 0.0908),
                .line(0.55, 0.1063),
                .line(0.6, 0.1437),
                .line(0.6, 0.1797),
                .line(0.55, 0.1423),
                .line(0.5, 0.1268),
                .line(0.45, 0.1237),
                .line(0.4, 0.1268),
                .line(0.35, 0.1361),
                .line(0.3, 0.1486),
                .line(0.25, 0.1704),
                .close
            ])),
            // Traced from the charge-flap outline drawn in the asset itself (its second path
            // element), viewBox bounds x 305.9…415.0, y 243.8…305.3.
            chargeLid: .frame(center: CGPoint(x: 0.1714, y: 0.3670),
                              size: CGSize(width: 0.0519, height: 0.0822))
        ),
        frontWheel: OutlineWheel(center: CGPoint(x: 0.8400, y: 0.6819), radiusFraction: 0.20211),
        rearWheel: OutlineWheel(center: CGPoint(x: 0.2019, y: 0.6819), radiusFraction: 0.20211),
        // The headlamp cluster at viewBox x 1919…2052, y 318…363 and the tail bar at
        // x 69…260, y 235…286.
        headlight: CGPoint(x: 0.9442, y: 0.4553),
        taillight: CGPoint(x: 0.0782, y: 0.3481)
    )
}

/// A zone resolved against a concrete container.
///
/// The path is expressed in `frame`'s own coordinates, so the drawing code can hand it to a shape
/// and position that shape once, whatever the placement was. `anchor` and `gradientRadius` come
/// from the path's own bounds rather than the frame's, because a traced zone's frame is the whole
/// silhouette and a gradient sized to that would wash the part out.
struct ResolvedOutlineZone {
    let path: Path
    let frame: CGRect
    let anchor: UnitPoint
    let gradientRadius: CGFloat
}

extension OutlineZonePlacement {
    /// Resolves this placement against the container, so the renderer never has to know which
    /// model — or which representation — it is drawing.
    func resolved(zone: VehicleOutlineZone, in og: OutlineGeometry) -> ResolvedOutlineZone {
        switch self {
        case .frame(let center, let size):
            let scaled = og.size(wFraction: size.width, hFraction: size.height)
            let origin = og.point(u: center.x, v: center.y)
            let frame = CGRect(x: origin.x - scaled.width / 2,
                               y: origin.y - scaled.height / 2,
                               width: scaled.width,
                               height: scaled.height)
            // A contour is drawn to fill the rect it is handed, so the frame is already the part's
            // own extent — which keeps the original Polestar 2 zones exactly as they were drawn.
            return ResolvedOutlineZone(
                path: zone.contourShape.path(in: CGRect(origin: .zero, size: scaled)),
                frame: frame,
                anchor: .center,
                gradientRadius: max(scaled.width, scaled.height) * 0.55
            )

        case .traced(let outline):
            // Traced geometry is expressed against the whole silhouette, so the frame is the image
            // and the part's own bounds are what the anchor and the gradient have to be measured
            // against: a gradient sized to the image would wash the panel out.
            let frame = og.imageFrame
            let path = outline.path(in: frame).offsetBy(dx: -frame.minX, dy: -frame.minY)
            let bounds = path.boundingRect
            return ResolvedOutlineZone(
                path: path,
                frame: frame,
                anchor: UnitPoint(x: frame.width > 0 ? bounds.midX / frame.width : 0.5,
                                  y: frame.height > 0 ? bounds.midY / frame.height : 0.5),
                gradientRadius: max(bounds.width, bounds.height) * 0.55
            )
        }
    }
}

// MARK: - Frame geometry

/// Maps a container onto the silhouette's coordinate space.
///
/// Everything drawn on the profile — hotspots, wheels, lamp glows, the ground shadow — is placed
/// through this, so a zone's fractions mean the same thing at any card size.
struct OutlineGeometry {
    /// Kept as the default so callers written against the original single-asset profile (and its
    /// unit test) keep the framing they were written for.
    static let polestar2AspectRatio: CGFloat = 1645.0 / 769.0

    let containerWidth: CGFloat
    let containerHeight: CGFloat
    let aspectRatio: CGFloat
    /// Shrinks the fitted asset so each model's car presents at a comparable size. See
    /// `VehicleOutlineSpec.contentScale`.
    let contentScale: CGFloat

    init(containerWidth: CGFloat, containerHeight: CGFloat,
         aspectRatio: CGFloat = OutlineGeometry.polestar2AspectRatio,
         contentScale: CGFloat = 1) {
        self.containerWidth = containerWidth
        self.containerHeight = containerHeight
        self.aspectRatio = aspectRatio
        self.contentScale = contentScale
    }

    init(containerWidth: CGFloat, containerHeight: CGFloat, spec: VehicleOutlineSpec) {
        self.init(containerWidth: containerWidth, containerHeight: containerHeight,
                  aspectRatio: spec.aspectRatio, contentScale: spec.contentScale)
    }

    private var fittedWidth: CGFloat {
        containerWidth / containerHeight > aspectRatio ? containerHeight * aspectRatio : containerWidth
    }

    private var fittedHeight: CGFloat {
        containerWidth / containerHeight > aspectRatio ? containerHeight : containerWidth / aspectRatio
    }

    var imageWidth: CGFloat { fittedWidth * contentScale }
    var imageHeight: CGFloat { fittedHeight * contentScale }

    var originX: CGFloat { (containerWidth - imageWidth) / 2 }
    var originY: CGFloat { (containerHeight - imageHeight) / 2 }

    var imageFrame: CGRect {
        CGRect(x: originX, y: originY, width: imageWidth, height: imageHeight)
    }

    func point(u: CGFloat, v: CGFloat) -> CGPoint {
        CGPoint(x: originX + u * imageWidth, y: originY + v * imageHeight)
    }

    func size(wFraction: CGFloat, hFraction: CGFloat) -> CGSize {
        CGSize(width: wFraction * imageWidth, height: hFraction * imageHeight)
    }

    /// The ground shadow, expressed against the spec's content box so every model's sits right
    /// under its tires. The offsets are the original Polestar 2 shadow's proportions, re-expressed
    /// against the car's own bounds rather than the whole asset.
    func groundShadow(for spec: VehicleOutlineSpec) -> (center: CGPoint, size: CGSize) {
        let box = spec.contentBox
        return (
            center: point(u: box.midX, v: box.maxY + 0.10 * box.height),
            size: size(wFraction: 0.90, hFraction: 0.15 * box.height)
        )
    }
}

/// Erases a `Shape` so one renderer can draw every zone.
struct OutlineAnyShape: Shape, @unchecked Sendable {
    private let _path: @Sendable (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        self._path = { shape.path(in: $0) }
    }

    func path(in rect: CGRect) -> Path {
        _path(rect)
    }
}

/// A shape around a path that has already been placed in its final coordinate space — used for
/// outlines traced from an asset, whose numbers are absolute in the silhouette frame.
struct OutlineFixedShape: Shape, @unchecked Sendable {
    let path: Path

    func path(in _: CGRect) -> Path { path }
}

// MARK: - Exact Polestar 2 contours

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

extension VehicleOutlineZone {
    /// The Polestar 2 contour this zone is drawn with when its placement is a `.frame`. Traced
    /// zones and the two rounded-rect parts never reach here.
    var contourShape: OutlineAnyShape {
        switch self {
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
}
