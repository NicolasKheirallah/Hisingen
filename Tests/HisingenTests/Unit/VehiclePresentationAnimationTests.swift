import AppKit
import Foundation
import Testing
@testable import Hisingen

/// Covers the control logic around the vehicle roll-in: what counts as a change
/// worth animating, which way a transition travels, and what state the layers are
/// left in. The animation itself is judged on screen, not here.
@Suite(.serialized)
@MainActor
struct VehiclePresentationAnimationTests {

    // MARK: - Telemetry must not replay the entrance

    @Test
    func telemetryRefreshIsNotAPictureChange() {
        let identity = VehiclePresentationIdentity(vin: "YSMVSEDE6PL147228", angle: 1)
        let bytes = Data(repeating: 0xAB, count: 3_037_436)

        // Every refresh hands back the same picture from the image cache, and the
        // stage only animates when the request changes.
        let first = VehiclePresentationRequest(identity: identity, data: bytes)
        let refresh = VehiclePresentationRequest(identity: identity, data: bytes)
        XCTAssertEqual(first, refresh)

        // A newly downloaded render for the same angle is a real change.
        let redownloaded = VehiclePresentationRequest(
            identity: identity,
            data: Data(repeating: 0xAB, count: 3_037_500)
        )
        XCTAssertNotEqual(first, redownloaded)

        // So is a different angle, and a different car.
        XCTAssertNotEqual(first, VehiclePresentationRequest(
            identity: VehiclePresentationIdentity(vin: identity.vin, angle: 4),
            data: bytes
        ))
        XCTAssertNotEqual(first, VehiclePresentationRequest(
            identity: VehiclePresentationIdentity(vin: "YV1XZEHR2R2371256", angle: 1),
            data: bytes
        ))
    }

    @Test
    func ledgerRollsInOnFirstSightAndHoldsBackAfterwards() {
        let ledger = VehicleEntranceLedger()
        let identity = VehiclePresentationIdentity(vin: "YSMVSEDE6PL147228", angle: 1)
        let opened = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(ledger.style(for: identity, now: opened), .full)

        // Only presenting the car counts. Telemetry never reaches the ledger, so
        // asking again without presenting still says "full".
        XCTAssertEqual(ledger.style(for: identity, now: opened + 1), .full)

        ledger.markPresented(identity, at: opened)

        // Popover toggled shut and straight back open: no animation at all.
        XCTAssertEqual(ledger.style(for: identity, now: opened + 1), .instant)
        // Later in the same sitting, or the other tab: shorter entrance.
        XCTAssertEqual(ledger.style(for: identity, now: opened + 30), .abbreviated)
        // A fresh visit earns the full roll-in again.
        XCTAssertEqual(ledger.style(for: identity, now: opened + 11 * 60), .full)
        // Another car has never been seen, whatever this one did.
        XCTAssertEqual(
            ledger.style(for: VehiclePresentationIdentity(vin: "YV1XZEHR2R2371256", angle: 1), now: opened + 30),
            .full
        )
    }

    // MARK: - Direction

    @Test
    func angleChangeTravelsTheWayTheSelectionMoved() {
        func direction(_ from: Int, _ to: Int) -> VehicleTransitionDirection {
            .between(
                VehiclePresentationIdentity(vin: "YSMVSEDE6PL147228", angle: from),
                VehiclePresentationIdentity(vin: "YSMVSEDE6PL147228", angle: to)
            )
        }

        // Strip order is 3/4 front (1), front (2), side (0), 3/4 rear (3), rear (4), top (5).
        XCTAssertEqual(direction(1, 2), .towardRear)
        XCTAssertEqual(direction(1, 0), .towardRear)
        XCTAssertEqual(direction(0, 4), .towardRear)
        XCTAssertEqual(direction(4, 2), .towardFront)
        XCTAssertEqual(direction(3, 1), .towardFront)
        XCTAssertEqual(direction(5, 0), .towardFront)

        // The old picture leaves in the direction of travel; the new one arrives
        // from the other side.
        XCTAssertEqual(VehicleTransitionDirection.towardRear.outgoingSign, -1)
        XCTAssertEqual(VehicleTransitionDirection.towardFront.outgoingSign, 1)

        // No spatial relationship to express.
        XCTAssertEqual(direction(0, 0), .none)
        XCTAssertEqual(direction(0, VehiclePresentationIdentity.cabinAngle), .none)
        XCTAssertEqual(direction(VehiclePresentationIdentity.cabinAngle, 0), .none)
        XCTAssertEqual(direction(0, 99), .none)
        XCTAssertEqual(
            VehicleTransitionDirection.between(
                VehiclePresentationIdentity(vin: "YSMVSEDE6PL147228", angle: 0),
                VehiclePresentationIdentity(vin: "YV1XZEHR2R2371256", angle: 4)
            ),
            .none
        )
        XCTAssertEqual(VehicleTransitionDirection.none.outgoingSign, 0)
    }

    // MARK: - Curves

    @Test
    func brakingCurveCoversTheDistanceAndStopsDead() {
        XCTAssertEqual(VehicleRollCurve.distance(at: 0), 0)
        XCTAssertEqual(VehicleRollCurve.distance(at: 1), 1)

        // Monotonic: the car never backs up mid-arrival.
        var previous = 0.0
        for step in 1...400 {
            let value = VehicleRollCurve.distance(at: Double(step) / 400)
            XCTAssertTrue(value >= previous)
            previous = value
        }

        // Half the distance is behind it in the first third of the time.
        XCTAssertTrue(VehicleRollCurve.distance(at: VehicleRollCurve.speedHoldFraction) > 0.49)

        // And it arrives at a crawl rather than a stop: the last slice of travel
        // is a fraction of a mid-flight slice.
        let tail = VehicleRollCurve.distance(at: 1) - VehicleRollCurve.distance(at: 0.98)
        let middle = VehicleRollCurve.distance(at: 0.5) - VehicleRollCurve.distance(at: 0.48)
        XCTAssertTrue(tail < middle / 10)
    }

    @Test
    func suspensionSettleDipsOnceAndReturnsToRest() {
        XCTAssertEqual(VehicleRollCurve.settle(at: 0), 0)
        XCTAssertEqual(VehicleRollCurve.settle(at: 1), 0)

        // Compression first — negative is downwards — then a much smaller rebound.
        let compression = VehicleRollCurve.settle(at: 0.18)
        let rebound = VehicleRollCurve.settle(at: 0.68)
        XCTAssertTrue(compression < -0.99)
        XCTAssertTrue(rebound > 0)
        XCTAssertTrue(rebound < abs(compression) / 3)

        // Normalised, so the amplitude in the motion is the compression in points.
        for step in 0...1000 {
            XCTAssertTrue(abs(VehicleRollCurve.settle(at: Double(step) / 1000)) <= 1.0001)
        }
    }

    @Test
    func entranceStartsOffstageAndLandsOnCanonicalValues() {
        for motion in [VehicleEntranceMotion.full, .abbreviated, .cabin, .reduced] {
            let samples = motion.samples()
            XCTAssertTrue(samples.count > 1)

            guard let first = samples.first, let last = samples.last else { return }
            XCTAssertEqual(first.translation.x, motion.travel)
            XCTAssertEqual(first.scale, motion.startScale)
            XCTAssertEqual(first.opacity, 0)

            // Whatever the tuning, the last frame is the resting state exactly.
            XCTAssertEqual(last.translation, .zero)
            XCTAssertTrue(isClose(last.scale, 1))
            XCTAssertTrue(isClose(last.opacity, 1))
        }
    }

    @Test
    func entranceNeverOvershootsItsPlace() {
        for entrySide in [CGFloat(1), -1] {
            var motion = VehicleEntranceMotion.full
            motion.travel *= entrySide
            for sample in motion.samples() {
                // Restrained, not bouncy: it approaches from one side and stops,
                // never crossing its resting place.
                XCTAssertTrue(abs(sample.translation.x) <= abs(motion.travel) + 0.0001)
                XCTAssertTrue(sample.translation.x * entrySide >= -0.0001)
                XCTAssertTrue(sample.scale <= 1.0001)
                XCTAssertTrue(sample.scale >= motion.startScale - 0.0001)
                // Vertical movement stays in the "barely noticeable" range.
                XCTAssertTrue(abs(sample.translation.y) <= max(motion.sway, motion.settle) + 0.0001)
            }
        }
    }

    // MARK: - Which side it drives in from

    @Test
    func carDrivesInNoseFirst() {
        func entrance(_ angle: Int) -> VehicleEntranceMotion? {
            VehicleEntranceMotion.resolve(
                style: .full,
                identity: VehiclePresentationIdentity(vin: "YSMVSEDE6PL147228", angle: angle),
                reduceMotion: false
            )
        }

        // The renders are nose-right in the side profile, the front three-quarter
        // and the overhead frame, so the car has to come from the left to be
        // driving forwards rather than reversing into place.
        for angle in [0, 1, 5] {
            XCTAssertEqual(VehiclePresentationIdentity(vin: "V", angle: angle).facing, .right)
            XCTAssertTrue((entrance(angle)?.travel ?? 0) < 0)
        }

        // The rear three-quarter points away to the left, so it comes from the right.
        XCTAssertEqual(VehiclePresentationIdentity(vin: "V", angle: 3).facing, .left)
        XCTAssertTrue((entrance(3)?.travel ?? 0) > 0)

        // Dead-on front and rear have no forward axis on screen; they keep the
        // conventional trailing-edge entry.
        for angle in [2, 4] {
            XCTAssertEqual(VehiclePresentationIdentity(vin: "V", angle: angle).facing, .square)
            XCTAssertTrue((entrance(angle)?.travel ?? 0) > 0)
        }

        // Whichever side it starts on, it travels the same distance and lands in
        // exactly the same place.
        XCTAssertEqual(abs(entrance(0)?.travel ?? 0), abs(entrance(3)?.travel ?? 0))
        for angle in [0, 1, 2, 3, 4, 5] {
            guard let last = entrance(angle)?.samples().last else { return }
            XCTAssertEqual(last.translation, .zero)
        }

        // An unknown angle has nothing to reason about and stays conventional.
        XCTAssertEqual(VehiclePresentationIdentity(vin: "V", angle: 99).facing, .square)
    }

    @Test
    func wheelRotationTracksTravelAndStopsWithTheCar() {
        let radius: CGFloat = 26

        // Rolling without slipping: one circumference of travel is one turn.
        XCTAssertTrue(isClose(
            VehicleRollCurve.wheelRotation(travelled: 2 * .pi * radius, radius: radius),
            2 * .pi
        ))
        XCTAssertEqual(VehicleRollCurve.wheelRotation(travelled: 100, radius: 0), 0)

        // Driven off the body's own travel samples, so it can only ever turn
        // forwards, and it is already still before the suspension finishes.
        let samples = VehicleEntranceMotion.full.samples()
        var previous: CGFloat = -1
        for sample in samples {
            let angle = VehicleRollCurve.wheelRotation(travelled: sample.travelled, radius: radius)
            XCTAssertTrue(angle >= previous)
            previous = angle
        }
        let last = VehicleRollCurve.wheelRotation(travelled: samples[samples.count - 1].travelled, radius: radius)
        let penultimate = VehicleRollCurve.wheelRotation(travelled: samples[samples.count - 2].travelled, radius: radius)
        XCTAssertTrue(abs(last - penultimate) < 0.001)
    }

    // MARK: - Reduce Motion

    @Test
    func reduceMotionRemovesTheTravel() {
        let exterior = VehiclePresentationIdentity(vin: "YSMVSEDE6PL147228", angle: 1)
        let cabin = VehiclePresentationIdentity(vin: "YSMVSEDE6PL147228", angle: VehiclePresentationIdentity.cabinAngle)
        let reduced = VehicleEntranceMotion.resolve(style: .full, identity: exterior, reduceMotion: true)
        XCTAssertEqual(reduced?.travel, 0)
        XCTAssertEqual(reduced?.startScale, 1)
        XCTAssertEqual(reduced?.sway, 0)
        XCTAssertEqual(reduced?.settle, 0)
        XCTAssertTrue((reduced?.duration ?? 1) <= 0.2)

        let rolling = VehicleEntranceMotion.resolve(style: .full, identity: exterior, reduceMotion: false)
        XCTAssertTrue(abs(rolling?.travel ?? 0) >= 100)

        let transition = VehicleTransitionMotion.resolve(direction: .towardRear, reduceMotion: true)
        XCTAssertEqual(transition.offset, 0)
        XCTAssertEqual(transition.outgoingScale, 1)
        XCTAssertEqual(transition.incomingScale, 1)
        XCTAssertTrue(transition.duration <= 0.2)

        // Instant stays instant either way, and the cabin photo never rolls.
        XCTAssertNil(VehicleEntranceMotion.resolve(style: .instant, identity: exterior, reduceMotion: false))
        XCTAssertNil(VehicleEntranceMotion.resolve(style: .instant, identity: cabin, reduceMotion: true))
        XCTAssertEqual(VehicleEntranceMotion.resolve(style: .full, identity: cabin, reduceMotion: false)?.travel, 0)
    }

    @Test
    func reduceMotionIsReadFromOnePlace() {
        let original = VehicleMotionPreference.reduceMotionOverride
        defer { VehicleMotionPreference.reduceMotionOverride = original }

        VehicleMotionPreference.reduceMotionOverride = true
        XCTAssertTrue(VehicleMotionPreference.prefersReducedMotion)
        VehicleMotionPreference.reduceMotionOverride = false
        XCTAssertFalse(VehicleMotionPreference.prefersReducedMotion)
    }

    // MARK: - Final state

    @Test
    func everyEntranceEndsExactlyAtRest() {
        // The last keyframe of every track is the resting frame, so however an
        // entrance is interrupted or retargeted, there is no other value for it
        // to land on. In SwiftUI this is structural rather than something the
        // animation has to be careful about.
        for motion in [VehicleEntranceMotion.full, .abbreviated, .cabin, .reduced] {
            guard let last = motion.frames().last else { return }
            XCTAssertEqual(last.x, VehicleEntranceFrame.rest.x)
            XCTAssertEqual(last.y, VehicleEntranceFrame.rest.y)
            XCTAssertTrue(isClose(last.scale, VehicleEntranceFrame.rest.scale))
            XCTAssertTrue(isClose(last.opacity, VehicleEntranceFrame.rest.opacity))
            // Ground covered is the one thing that does not return to zero: a
            // wheel that has rolled stays rolled, so wheel layers added later
            // hold their final angle instead of snapping back.
            XCTAssertEqual(last.travelled, motion.travel)
        }
    }

    @Test
    func entranceFramesFlipTheVerticalAxisForSwiftUI() {
        // The curves are written with up positive, the way suspension travel is
        // described; SwiftUI's y grows downwards. A ride-height rise has to come
        // out as a negative offset, or the car would sink while rolling and jump
        // while settling.
        let motion = VehicleEntranceMotion.full
        let samples = motion.samples()
        let frames = motion.frames()
        XCTAssertEqual(samples.count, frames.count)

        guard let riseIndex = samples.indices.max(by: { samples[$0].translation.y < samples[$1].translation.y })
        else { return }
        XCTAssertTrue(samples[riseIndex].translation.y > 0)
        XCTAssertTrue(frames[riseIndex].y < 0)
        XCTAssertEqual(frames[riseIndex].y, -samples[riseIndex].translation.y)
    }

    @Test
    func rapidAngleChangesEndOnTheLastOneAsked() {
        // 3/4 front, side, rear, front, as fast as the user can click. Each step
        // picks its own direction, and there is no accumulated state to unwind:
        // the view renders whichever identity arrived last.
        let clicks = [1, 0, 4, 2]
        var current = VehiclePresentationIdentity(vin: "YSMVSEDE6PL147228", angle: 1)
        var directions: [VehicleTransitionDirection] = []

        for angle in clicks {
            let next = VehiclePresentationIdentity(vin: current.vin, angle: angle)
            directions.append(.between(current, next))
            current = next
        }

        XCTAssertEqual(directions, [.none, .towardRear, .towardRear, .towardFront])
        XCTAssertEqual(current.angle, 2)
        // And whichever way each step went, the entrance plan is untouched: only
        // the first picture on an empty view rolls in.
        XCTAssertEqual(VehicleTransitionMotion.resolve(direction: .none, reduceMotion: false).offset, 0)
    }

    // MARK: - Resting geometry

    @Test
    func restingLayoutIsTheOneTheStaticImplementationUsed() {
        // These are the modifiers the hero cards have always laid the render out
        // with: an 8 pt inset and a 205 pt content height inside a 220 pt
        // container, zoomed 1.33 so it overflows and is clipped. The view applies
        // them directly, so the resting state is not reproduced — it is the same
        // layout — and these constants are the only thing that could drift.
        XCTAssertEqual(VehicleRenderLayout.horizontalInset, 8)
        XCTAssertEqual(VehicleRenderLayout.contentHeight, 205)
        XCTAssertEqual(VehicleRenderLayout.containerHeight, 220)
        XCTAssertEqual(VehicleRenderLayout.zoom, 1.33)

        // The decode is sized from the drawn size, which follows from the source
        // aspect and the content height without waiting for layout: a 16:9 render
        // is height-limited at 205 pt, so 272.65 pt tall and 484.5 pt wide.
        let drawn = VehicleRenderLayout.drawnSize(sourcePixelSize: CGSize(width: 4898, height: 2756))
        XCTAssertTrue(isClose(drawn.height, 205 * 1.33, tolerance: 0.01))
        XCTAssertTrue(isClose(drawn.width, 205 * 1.33 * (4898.0 / 2756.0), tolerance: 0.01))

        // A picture with no dimensions has nothing to size a decode from.
        XCTAssertEqual(VehicleRenderLayout.drawnSize(sourcePixelSize: .zero), .zero)
        // And a freak aspect ratio cannot ask for an enormous decode.
        let absurd = VehicleRenderLayout.drawnSize(sourcePixelSize: CGSize(width: 40000, height: 100))
        XCTAssertTrue(absurd.width <= 900)
    }

    // MARK: - Artwork

    @Test
    func artworkIsDecodedOnceAtDisplaySize() async {
        let store = VehicleArtworkStore()
        let png = Self.pngData(width: 2000, height: 1125)
        // Just enough for the drawn size at this backing scale, rounded up to a
        // coarse step. Decoding much larger than this would soften fine detail
        // for nothing, because the compositor would downscale it a second time.
        let drawnDevicePixels = 519.0 * 2
        let budget = VehicleArtworkStore.pixelBudget(pointSize: CGSize(width: 519, height: 273), scale: 2)
        XCTAssertTrue(Double(budget) >= drawnDevicePixels)
        XCTAssertTrue(Double(budget) < drawnDevicePixels + 64)

        XCTAssertNil(store.cached(source: "artwork#1", data: png, pixelBudget: budget))

        let artwork: VehicleArtworkStore.Artwork? = await withCheckedContinuation { continuation in
            store.load(source: "artwork#1", data: png, pixelBudget: budget) { continuation.resume(returning: $0) }
        }
        XCTAssertNotNil(artwork)
        // Kept at what the screen needs rather than at source resolution.
        XCTAssertTrue((artwork?.image.width ?? 0) <= budget)
        XCTAssertTrue((artwork?.image.width ?? 0) > budget / 2)
        // Aspect ratio comes from the true source dimensions, not the rounded
        // thumbnail, so the resting frame is unaffected by the budget.
        XCTAssertEqual(artwork?.sourcePixelSize, CGSize(width: 2000, height: 1125))
        // Asking again is a cache hit, not a second 65 ms decode.
        XCTAssertNotNil(store.cached(source: "artwork#1", data: png, pixelBudget: budget))
    }

    // MARK: - Helpers

    private func isClose(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 1e-6) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private static func solidImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.25, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private static func pngData(width: Int, height: Int) -> Data {
        let representation = NSBitmapImageRep(cgImage: solidImage(width: width, height: height))
        return representation.representation(using: .png, properties: [:]) ?? Data()
    }
}
