import AppKit
import Foundation
import Testing
import SwiftUI
@testable import Hisingen

/// `VehicleOutlineSpecTests` proves the hotspot numbers are self-consistent. This proves they land
/// on the car each asset actually draws, which is the failure that matters: a zone traced a few
/// percent off still renders, still animates and still takes a click — just over the wrong panel.
///
/// The artwork is a line drawing whose panel interiors are white, so "on the car" is decided by
/// flood-filling the background and treating everything the fill cannot reach as car.
struct VehicleOutlinePlacementTests {
    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Unit/
            .deletingLastPathComponent()  // HisingenTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root
    }

    private struct CarMask {
        let width: Int
        let height: Int
        private let car: [Bool]

        init(width: Int, height: Int, car: [Bool]) {
            self.width = width
            self.height = height
            self.car = car
        }

        func contains(x: Int, y: Int) -> Bool {
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            return car[y * width + x]
        }

        /// Samples at normalised asset coordinates, which is how the view positions everything.
        /// `margin` is the allowance, in the same normalised units, for the stroke that straddles a
        /// panel line and the shadow cast below it — both of which paint outside the body by design.
        func contains(u: CGFloat, v: CGFloat, margin: CGFloat = 0) -> Bool {
            let x = Int(u * CGFloat(width))
            let y = Int(v * CGFloat(height))
            guard margin > 0 else { return contains(x: x, y: y) }
            let dx = Int(margin * CGFloat(width)) + 1
            let dy = Int(margin * CGFloat(height)) + 1
            for offsetY in -dy...dy {
                for offsetX in -dx...dx where contains(x: x + offsetX, y: y + offsetY) { return true }
            }
            return false
        }
    }

    /// An RGBA copy of a rendered image, top row first.
    private struct Bitmap {
        let width: Int
        let height: Int
        private let pixels: [UInt8]

        private init(width: Int, height: Int, pixels: [UInt8]) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        static func read(_ image: CGImage) -> Bitmap? {
            let width = image.width, height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(
                data: &bytes, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return Bitmap(width: width, height: height, pixels: bytes)
        }

        /// Every pixel where the two renders disagree, in bitmap coordinates.
        func changedPoints(comparedTo other: Bitmap) -> [CGPoint] {
            guard width == other.width, height == other.height else { return [] }
            var points: [CGPoint] = []
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    if pixels[i] != other.pixels[i]
                        || pixels[i + 1] != other.pixels[i + 1]
                        || pixels[i + 2] != other.pixels[i + 2] {
                        points.append(CGPoint(x: x, y: y))
                    }
                }
            }
            return points
        }
    }

    /// The shipping view at a card's size, drawn through the real renderer so the test covers the
    /// whole chain: model → spec → geometry → pixels.
    @MainActor
    private func renderSideProfile(model: VehicleModel,
                                   openings: [OpeningReading]) throws -> Bitmap {
        let renderer = ImageRenderer(content:
            VehicleSideProfileDoorsView(openings: openings, model: model)
                .frame(width: 420, height: 96)
        )
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "the side profile rendered no image")
        return try #require(Bitmap.read(image), "could not read the rendered pixels back")
    }

    @MainActor
    private func rasterize(_ spec: VehicleOutlineSpec, width: Int) throws -> CarMask {
        let url = packageRoot().appendingPathComponent("Sources/Hisingen/Resources/\(spec.assetName).svg")
        let image = try #require(NSImage(contentsOf: url), "\(spec.assetName) failed to load")
        let height = Int((Double(width) * spec.naturalSize.height / spec.naturalSize.width).rounded())

        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.isTemplate = false
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        var ink = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                ink[y * width + x] = colour.brightnessComponent < 0.85 && colour.alphaComponent > 0.4
            }
        }

        // Any antialiased one-pixel gap in a stroke would let the background flood straight through
        // the car and make every panel look like empty space. Dilating the ink seals those.
        var sealed = ink
        for y in 0..<height {
            for x in 0..<width where ink[y * width + x] {
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                        sealed[ny * width + nx] = true
                    }
                }
            }
        }

        var reachable = [Bool](repeating: false, count: width * height)
        var pending: [Int] = []
        func push(_ x: Int, _ y: Int) {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            let index = y * width + x
            guard !reachable[index], !sealed[index] else { return }
            reachable[index] = true
            pending.append(index)
        }
        for x in 0..<width { push(x, 0); push(x, height - 1) }
        for y in 0..<height { push(0, y); push(width - 1, y) }
        while let index = pending.popLast() {
            let x = index % width, y = index / width
            push(x - 1, y); push(x + 1, y); push(x, y - 1); push(x, y + 1)
        }

        // Car = ink plus everything the background never reached: the body interior, the glazing and
        // the gaps between panels.
        var car = [Bool](repeating: false, count: width * height)
        for index in 0..<(width * height) { car[index] = sealed[index] || !reachable[index] }
        return CarMask(width: width, height: height, car: car)
    }

    @Test
    @MainActor
    func everyHotspotSitsOnTheCarItsAssetDraws() throws {
        for spec in [VehicleOutlineSpec.polestar2, .polestar3, .polestar4] {
            let mask = try rasterize(spec, width: 1200)
            // Scale 1: the raster is the whole asset, and so is the frame the zones resolve into.
            let og = OutlineGeometry(containerWidth: CGFloat(mask.width),
                                     containerHeight: CGFloat(mask.height),
                                     aspectRatio: spec.aspectRatio, contentScale: 1)

            for zone in VehicleOutlineZone.allCases {
                let resolved = spec.zones[zone].resolved(zone: zone, in: og)
                let path = resolved.path.offsetBy(dx: resolved.frame.minX, dy: resolved.frame.minY)
                let bounds = path.boundingRect
                let steps = 48
                var sampled = 0
                var onCar = 0
                for iy in 0..<steps {
                    for ix in 0..<steps {
                        let point = CGPoint(
                            x: bounds.minX + (CGFloat(ix) + 0.5) / CGFloat(steps) * bounds.width,
                            y: bounds.minY + (CGFloat(iy) + 0.5) / CGFloat(steps) * bounds.height)
                        guard path.contains(point) else { continue }
                        sampled += 1
                        if mask.contains(x: Int(point.x), y: Int(point.y)) { onCar += 1 }
                    }
                }

                let ratio = sampled == 0 ? 0 : Double(onCar) / Double(sampled)
                #expect(sampled > 0, "\(spec.assetName)/\(zone) resolves to an empty shape")

                // Traced zones follow drawn panel edges, so they should sit almost entirely on the
                // car. The hand-drawn Polestar 2 contours are approximations, and its sunroof is a
                // rounded rectangle laid over a curved roof — that one always overhangs a little.
                var traced = false
                if case .traced = spec.zones[zone] { traced = true }
                #expect(ratio > (traced ? 0.90 : 0.75),
                        "\(spec.assetName)/\(zone) is only \(ratio) on the car")
            }

            for (name, wheel) in [("front", spec.frontWheel), ("rear", spec.rearWheel)] {
                #expect(mask.contains(u: wheel.center.x, v: wheel.center.y, margin: 0.01),
                        "\(spec.assetName)'s \(name) wheel ring is off the car")
            }

            for (name, glow) in [("headlight", spec.headlight), ("taillight", spec.taillight)] {
                #expect(mask.contains(u: glow.x, v: glow.y, margin: 0.01),
                        "\(spec.assetName)'s \(name) glow is off the car")
            }
        }
    }

    /// Renders the shipping view rather than only its geometry.
    ///
    /// The fractions can all be correct while the chosen model never reaches the drawing — a
    /// dropped `model:` argument at one of the call sites looks exactly like that, and nothing in
    /// the geometry would notice. Opening one door against a closed baseline isolates the drawn
    /// highlight, so the test can check both that each model paints a different car and that what
    /// it paints lands on that car.
    @Test
    @MainActor
    func theDrawnCarAndItsHighlightsBelongToTheModelItWasGiven() throws {
        let models: [(spec: VehicleOutlineSpec, model: VehicleModel)] = [
            (.polestar2, VehicleModel(modelName: "Polestar 2")),
            (.polestar3, VehicleModel(modelName: "Polestar 3")),
            (.polestar4, VehicleModel(modelName: "Polestar 4")),
        ]
        // One door from each half of the car: between them they light both lamp glows.
        let doors: [VehicleOpening] = [.frontLeftDoor, .rearLeftDoor]

        var closed: [String: Bitmap] = [:]
        var opened: [String: [VehicleOpening: Bitmap]] = [:]

        for (spec, model) in models {
            // Without its asset the view draws the vector fallback, and the render would then prove
            // nothing about the outline. This also covers the bundled resource lookup itself.
            #expect(VehicleOutlineImageProvider.shared.image(for: spec) != nil,
                    "\(spec.assetName) did not load, so this render would only test the fallback")

            closed[spec.assetName] = try renderSideProfile(model: model, openings: [])
            for door in doors {
                opened[spec.assetName, default: [:]][door] =
                    try renderSideProfile(model: model,
                                          openings: [OpeningReading(opening: door, state: .open)])
            }
        }

        // Three identical renders would mean the model never arrived and every car drew the same
        // silhouette — the defect this whole change exists to remove, in its most likely form.
        for (index, entry) in models.enumerated() {
            let baseline = try #require(closed[entry.spec.assetName])
            for other in models[(index + 1)...] {
                let otherBaseline = try #require(closed[other.spec.assetName])
                #expect(baseline.changedPoints(comparedTo: otherBaseline).count > 500,
                        "\(entry.spec.assetName) and \(other.spec.assetName) drew the same car")
            }
        }

        for (spec, _) in models {
            let baseline = try #require(closed[spec.assetName])
            let mask = try rasterize(spec, width: 1200)
            let og = OutlineGeometry(containerWidth: CGFloat(baseline.width),
                                     containerHeight: CGFloat(baseline.height), spec: spec)
            // In render points, so it means the same thing at any card size: the stroke that
            // straddles a panel line and the shadow cast below it paint outside the body by design,
            // and a traced zone's edge sits exactly on the drawn panel line.
            let margin = 6 / min(og.imageWidth, og.imageHeight)

            for door in doors {
                let highlighted = try #require(opened[spec.assetName]?[door])
                let changed = baseline.changedPoints(comparedTo: highlighted)
                #expect(changed.count > 200, "\(spec.assetName)'s \(door) highlight drew nothing")

                var onCar = 0
                for point in changed {
                    // The highlight is positioned in the letterboxed silhouette frame, not the card.
                    let u = (point.x + 0.5 - og.originX) / og.imageWidth
                    let v = (point.y + 0.5 - og.originY) / og.imageHeight
                    if mask.contains(u: u, v: v, margin: margin) { onCar += 1 }
                }

                let ratio = Double(onCar) / Double(changed.count)
                #expect(ratio > 0.95,
                        "\(spec.assetName)'s \(door) highlight is only \(ratio) on the car it was drawn for")
            }
        }
    }

    /// The declared content boxes drive both the presented scale and the ground shadow, so they
    /// have to describe the ink the asset actually draws.
    @Test
    @MainActor
    func declaredContentBoxesMatchTheRenderedInk() throws {
        for spec in [VehicleOutlineSpec.polestar2, .polestar3, .polestar4] {
            let image = try #require(
                NSImage(contentsOf: packageRoot()
                    .appendingPathComponent("Sources/Hisingen/Resources/\(spec.assetName).svg")))
            let width = 900
            let height = Int((Double(width) * spec.naturalSize.height / spec.naturalSize.width).rounded())
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            image.isTemplate = false
            image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                       from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()

            var minX = width, maxX = -1, minY = height, maxY = -1
            for y in 0..<height {
                for x in 0..<width {
                    guard let colour = rep.colorAt(x: x, y: y),
                          colour.brightnessComponent < 0.85, colour.alphaComponent > 0.4 else { continue }
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            let ink = CGRect(x: CGFloat(minX) / CGFloat(width), y: CGFloat(minY) / CGFloat(height),
                             width: CGFloat(maxX - minX) / CGFloat(width),
                             height: CGFloat(maxY - minY) / CGFloat(height))

            // Antialiasing and one pixel of bleed either side; anything larger is a stale number.
            let tolerance: CGFloat = 0.01
            #expect(abs(ink.minX - spec.contentBox.minX) < tolerance
                        && abs(ink.maxX - spec.contentBox.maxX) < tolerance
                        && abs(ink.minY - spec.contentBox.minY) < tolerance
                        && abs(ink.maxY - spec.contentBox.maxY) < tolerance,
                    "\(spec.assetName) declares content box \(spec.contentBox) but draws \(ink)")
        }
    }
}
