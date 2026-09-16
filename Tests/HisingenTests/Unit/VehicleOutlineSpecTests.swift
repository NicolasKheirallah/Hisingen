import Foundation
import Testing
import SwiftUI
@testable import Hisingen

/// The side profile is only right if three separate things agree: which asset a model loads, that
/// asset's own coordinate system, and the hotspot fractions read off its artwork. A drift in any
/// one of them still renders — just a car with the highlights in the wrong place — so each is
/// pinned here.
struct VehicleOutlineSpecTests {
    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Unit/
            .deletingLastPathComponent()  // HisingenTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root
    }

    @Test
    func modelSelectsItsOwnSilhouette() {
        #expect(VehicleOutlineSpec.spec(for: .polestar3).assetName == "Polestar3silhouette")
        #expect(VehicleOutlineSpec.spec(for: .polestar4).assetName == "Polestar4silhouette")

        // Polestar 1/2/5/6, every Volvo, an unrecognised model, and "no model known yet" all keep
        // the outline that shipped first rather than leaving the card without a car.
        let fallbacks: [VehicleModel?] = [
            .polestar1, .polestar2, .polestar5, .polestar6,
            .volvoEX30, .volvoEX90, .volvoXC90, .unknown("Some EV"), nil
        ]
        for model in fallbacks {
            #expect(VehicleOutlineSpec.spec(for: model).assetName == "polestar_outline",
                    "\(String(describing: model)) should fall back to the original outline")
        }
    }

    /// The spec's aspect ratio is what every hotspot fraction is measured against, so a swapped or
    /// re-exported asset must fail here rather than silently stretch the car.
    @Test
    func declaredAssetSizesMatchTheBundledSVGs() throws {
        let resources = packageRoot().appendingPathComponent("Sources/Hisingen/Resources")
        for spec in [VehicleOutlineSpec.polestar2, .polestar3, .polestar4] {
            let url = resources.appendingPathComponent("\(spec.assetName).svg")
            let svg = try String(contentsOf: url, encoding: .utf8)
            let viewBox = try #require(Self.viewBox(of: svg),
                                       "\(spec.assetName).svg declares no viewBox")
            #expect(spec.naturalSize == viewBox,
                    "\(spec.assetName) is declared \(spec.naturalSize) but drawn in \(viewBox)")
        }
    }

    @Test
    func tracedZonesStayInsideTheSilhouetteFrame() {
        for spec in [VehicleOutlineSpec.polestar3, .polestar4] {
            for zone in VehicleOutlineZone.allCases {
                guard case .traced(let outline) = spec.zones[zone] else { continue }
                let bounds = outline.normalizedBounds
                #expect(bounds.width > 0.02 && bounds.height > 0.02,
                        "\(spec.assetName)/\(zone) traced to an empty outline")
                #expect(bounds.minX >= -0.001 && bounds.maxX <= 1.001
                            && bounds.minY >= -0.001 && bounds.maxY <= 1.001,
                        "\(spec.assetName)/\(zone) traced outside its own asset: \(bounds)")
            }
        }
    }

    /// A panel left on `.frame` would silently fall back to Polestar 2's contour and position, which
    /// is exactly the defect this feature exists to remove.
    @Test
    func polestarThreeAndFourTraceTheirOwnPanels() {
        for spec in [VehicleOutlineSpec.polestar3, .polestar4] {
            for zone in [VehicleOutlineZone.hood, .tailgate, .frontDoor, .rearDoor,
                         .frontWindow, .rearWindow, .sunroof] {
                guard case .traced = spec.zones[zone] else {
                    Issue.record("\(spec.assetName)/\(zone) is not traced from its own artwork")
                    continue
                }
            }
            guard case .frame = spec.zones[.chargeLid] else {
                Issue.record("\(spec.assetName)/chargeLid should use a rounded frame")
                continue
            }
        }
    }

    /// Spot checks taken straight from the interactive-parts overlays the geometry was read off:
    /// the Polestar 3 overlay lays its hotspots out in 1800×600 and the Polestar 4's in 1600×569.
    /// A mistyped digit fails here rather than looking subtly wrong on screen.
    @Test
    func tracedGeometryStartsWithItsSourceAnchor() {
        let p3 = VehicleOutlineSpec.polestar3
        Self.expectPoint(Self.firstMove(p3.zones[.rearDoor]), CGPoint(x: 458.0 / 1800, y: 185.0 / 600))
        Self.expectPoint(Self.firstMove(p3.zones[.frontDoor]), CGPoint(x: 858.0 / 1800, y: 185.0 / 600))
        Self.expectPoint(Self.firstMove(p3.zones[.hood]), CGPoint(x: 1279.0 / 1800, y: 184.0 / 600))
        Self.expectPoint(Self.firstMove(p3.zones[.tailgate]), CGPoint(x: 125.0 / 1800, y: 76.0 / 600))

        let p4 = VehicleOutlineSpec.polestar4
        Self.expectPoint(Self.firstMove(p4.zones[.rearDoor]), CGPoint(x: 405.0 / 1600, y: 157.0 / 569))
        Self.expectPoint(Self.firstMove(p4.zones[.frontDoor]), CGPoint(x: 781.0 / 1600, y: 184.0 / 569))
        Self.expectPoint(Self.firstMove(p4.zones[.hood]), CGPoint(x: 1148.0 / 1600, y: 179.0 / 569))
        Self.expectPoint(Self.firstMove(p4.zones[.tailgate]), CGPoint(x: 62.0 / 1600, y: 168.0 / 569))
    }

    /// Front and rear are easy to transpose and impossible to notice from a screenshot of a door.
    @Test
    func wheelsComeFromEachModelsOwnCircles() {
        let p3 = VehicleOutlineSpec.polestar3
        Self.expectPoint(p3.rearWheel.center, CGPoint(x: 376.0 / 1800, y: 430.0 / 600))
        Self.expectPoint(p3.frontWheel.center, CGPoint(x: 1472.0 / 1800, y: 430.0 / 600))
        #expect(abs(p3.frontWheel.radiusFraction - 145.0 / 600) < 0.0001)

        let p4 = VehicleOutlineSpec.polestar4
        Self.expectPoint(p4.rearWheel.center, CGPoint(x: 323.0 / 1600, y: 388.0 / 569))
        Self.expectPoint(p4.frontWheel.center, CGPoint(x: 1344.0 / 1600, y: 388.0 / 569))
        #expect(abs(p4.frontWheel.radiusFraction - 115.0 / 569) < 0.0001)

        // The drawing faces right on every asset, so the front wheel is always the right-hand one.
        for spec in [VehicleOutlineSpec.polestar2, .polestar3, .polestar4] {
            #expect(spec.rearWheel.center.x < spec.frontWheel.center.x)
            #expect(spec.rearWheel.radiusFraction > 0)
        }
    }

    /// The Polestar 2 asset carries much more empty margin than the 3 and 4 assets, so presenting
    /// each edge-to-edge drew a Polestar 3 half again larger than a Polestar 2 in the same card.
    @Test
    func everyModelPresentsItsCarAtAComparableSize() {
        // The reference asset is drawn unscaled, so the shipped Polestar 2 framing is untouched.
        #expect(VehicleOutlineSpec.polestar2.contentScale == 1)

        for spec in [VehicleOutlineSpec.polestar2, .polestar3, .polestar4] {
            #expect(spec.contentScale > 0.5 && spec.contentScale <= 1,
                    "\(spec.assetName) presents at \(spec.contentScale)")
            let presentedInkHeight = spec.contentBox.height * spec.contentScale
            #expect(abs(presentedInkHeight - VehicleOutlineSpec.referenceContentHeight) < 0.001,
                    "\(spec.assetName) draws its car at a different size from the others")
        }
    }

    @Test
    func outlinePathMapsNormalisedCoordinatesIntoItsRect() {
        let path = OutlinePath(commands: [
            .move(0, 0), .line(1, 0), .line(1, 1), .line(0, 1), .close
        ]).path(in: CGRect(x: 10, y: 20, width: 100, height: 50))

        let bounds = path.boundingRect
        #expect(abs(bounds.minX - 10) < 0.01)
        #expect(abs(bounds.minY - 20) < 0.01)
        #expect(abs(bounds.width - 100) < 0.01)
        #expect(abs(bounds.height - 50) < 0.01)
    }

    @Test
    func outlineGeometryKeepsEveryAssetUndistortedAndFramed() {
        for spec in [VehicleOutlineSpec.polestar2, .polestar3, .polestar4] {
            // A container wider than the asset: the height binds and the width follows the aspect.
            let og = OutlineGeometry(containerWidth: 420, containerHeight: 96, spec: spec)
            #expect(abs(og.imageWidth / og.imageHeight - spec.aspectRatio) < 0.001,
                    "\(spec.assetName) would be stretched")
            #expect(og.imageWidth <= 420.001 && og.imageHeight <= 96.001)
            #expect(abs(og.originX - (420 - og.imageWidth) / 2) < 0.001)
            #expect(abs(og.originY - (96 - og.imageHeight) / 2) < 0.001)
        }

        // A container narrower than the asset: the width binds instead.
        let tall = OutlineGeometry(containerWidth: 120, containerHeight: 96,
                                   spec: VehicleOutlineSpec.polestar3)
        #expect(abs(tall.imageWidth / tall.imageHeight - VehicleOutlineSpec.polestar3.aspectRatio) < 0.001)
        #expect(tall.imageWidth <= 120.001 && tall.imageHeight <= 96.001)
    }

    @Test
    func groundShadowHangsUnderTheCarOnEveryModel() {
        for spec in [VehicleOutlineSpec.polestar2, .polestar3, .polestar4] {
            let og = OutlineGeometry(containerWidth: 420, containerHeight: 96, spec: spec)
            let shadow = og.groundShadow(for: spec)
            let carBottom = og.point(u: spec.contentBox.midX, v: spec.contentBox.maxY).y
            #expect(shadow.center.y > carBottom,
                    "\(spec.assetName)'s shadow floats above its tires")
            #expect(abs(shadow.center.x - og.point(u: spec.contentBox.midX, v: 0).x) < 0.001)
            #expect(shadow.size.width > 0 && shadow.size.height > 0)
        }
    }

    /// Every zone — traced or framed — has to land on the silhouette. A path that resolves to
    /// nothing draws no highlight and takes no pointer, which is invisible until someone hovers.
    @Test
    func everyZoneResolvesInsideTheSilhouetteFrame() {
        for spec in [VehicleOutlineSpec.polestar2, .polestar3, .polestar4] {
            let og = OutlineGeometry(containerWidth: 420, containerHeight: 96, spec: spec)
            let frame = og.imageFrame

            for zone in VehicleOutlineZone.allCases {
                let path: Path
                switch spec.zones[zone] {
                case .frame(let center, let size):
                    let scaled = og.size(wFraction: size.width, hFraction: size.height)
                    let origin = og.point(u: center.x, v: center.y)
                    path = zone.contourShape.path(in: CGRect(origin: .zero, size: scaled))
                        .offsetBy(dx: origin.x - scaled.width / 2, dy: origin.y - scaled.height / 2)
                case .traced(let outline):
                    path = outline.path(in: frame)
                }

                let bounds = path.boundingRect
                #expect(bounds.width > 1 && bounds.height > 1,
                        "\(spec.assetName)/\(zone) resolves to nothing")
                #expect(bounds.minX >= frame.minX - 1 && bounds.maxX <= frame.maxX + 1
                            && bounds.minY >= frame.minY - 1 && bounds.maxY <= frame.maxY + 1,
                        "\(spec.assetName)/\(zone) draws outside the silhouette frame: \(bounds) vs \(frame)")
            }
        }
    }

    // MARK: - Helpers

    private static func firstMove(_ placement: OutlineZonePlacement) -> CGPoint? {
        guard case .traced(let outline) = placement else { return nil }
        guard case .move(let x, let y)? = outline.commands.first else { return nil }
        return CGPoint(x: x, y: y)
    }

    private static func expectPoint(_ actual: CGPoint?, _ expected: CGPoint,
                                    tolerance: CGFloat = 0.0001,
                                    sourceLocation: SourceLocation = #_sourceLocation) {
        guard let actual else {
            Issue.record("expected a traced anchor at \(expected)", sourceLocation: sourceLocation)
            return
        }
        #expect(abs(actual.x - expected.x) < tolerance && abs(actual.y - expected.y) < tolerance,
                "expected \(expected) but traced \(actual)", sourceLocation: sourceLocation)
    }

    private static func viewBox(of svg: String) -> CGSize? {
        guard let range = svg.range(of: #"viewBox\s*=\s*"[^"]*""#,
                                    options: .regularExpression) else { return nil }
        let numbers = svg[range]
            .split(whereSeparator: { !$0.isNumber && $0 != "." && $0 != "-" })
            .compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return CGSize(width: numbers[2], height: numbers[3])
    }
}
