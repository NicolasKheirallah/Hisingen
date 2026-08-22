import SwiftUI

/// The hero card's render geometry, unchanged from the static implementation:
/// an 8 pt inset and a 205 pt content height inside a 220 pt container, with a
/// 1.33 zoom over the top that deliberately overflows and is clipped.
///
/// The view below lays the render out with exactly these modifiers, so the
/// resting state is not *reproduced* — it is the same layout it always was.
enum VehicleRenderLayout {
    static let horizontalInset: CGFloat = 8
    static let contentHeight: CGFloat = 205
    static let containerHeight: CGFloat = 220
    static let zoom: CGFloat = 1.33

    /// Points the render is actually drawn at, which is what the decode should
    /// be sized to. A studio render is far wider than it is tall, so it is the
    /// content height that limits the fit, and the drawn size follows from the
    /// source's aspect ratio without needing to wait for layout.
    static func drawnSize(sourcePixelSize: CGSize) -> CGSize {
        guard sourcePixelSize.width > 0, sourcePixelSize.height > 0 else { return .zero }
        let height = contentHeight * zoom
        let aspect = sourcePixelSize.width / sourcePixelSize.height
        // Clamped so a freak aspect ratio cannot ask for an enormous decode; the
        // card is far narrower than this in every theme.
        return CGSize(width: min(height * aspect, 900), height: height)
    }
}

/// One frame of the entrance, in the render's own coordinates.
struct VehicleEntranceFrame: Equatable {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var scale: CGFloat = 1
    var opacity: CGFloat = 1
    /// Points of ground the car has covered. Nothing consumes it yet — the
    /// renders are flattened — but it rides the same timeline as the body, so a
    /// wheel layer only has to apply
    /// `.rotationEffect(.radians(VehicleRollCurve.wheelRotation(travelled:radius:)))`
    /// to turn in step with it. See docs/architecture/vehicle-motion.md.
    var travelled: CGFloat = 0

    static let rest = VehicleEntranceFrame()
}

/// The vehicle render, and the two ways it can arrive: rolling in when it is
/// first shown, crossing over when the user changes angle.
///
/// Everything around it — the card, the glow behind the car, the angle strip and
/// every label — is drawn by the surrounding SwiftUI and holds still.
@MainActor
struct VehiclePresentationView: View {
    let identity: VehiclePresentationIdentity
    let imageData: Data?
    private let artworkStore = VehicleArtworkStore()
    private let entranceLedger = VehicleEntranceLedger.shared

    @Environment(\.displayScale) private var displayScale

    @State private var artwork: VehicleArtworkStore.Artwork?
    /// Identity of the artwork actually on screen, which is what drives the
    /// crossover. It lags ``identity`` while a decode is in flight.
    @State private var shown: VehiclePresentationIdentity?
    /// Non-nil only for the first picture on an empty view. A `nil` plan means
    /// "already here", which is also what every later picture uses.
    @State private var entrance: VehicleEntranceMotion?
    @State private var entranceTrigger = 0
    @State private var transition = VehicleTransitionMotion.resolve(direction: .none, reduceMotion: false)
    @State private var transitionDirection = VehicleTransitionDirection.none

    private var request: VehiclePresentationRequest? {
        imageData.map { VehiclePresentationRequest(identity: identity, data: $0) }
    }

    var body: some View {
        ZStack {
            if let artwork, let shown {
                arrival(artwork)
                    .id(shown)
                    .transition(crossover)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: VehicleRenderLayout.containerHeight)
        .animation(transition.animation, value: shown)
        // Keyed on the request, so the several telemetry refreshes a minute that
        // re-evaluate this body with the same picture do not restart anything.
        .task(id: request) { await load() }
    }

    // MARK: - Arrival

    @ViewBuilder
    private func arrival(_ artwork: VehicleArtworkStore.Artwork) -> some View {
        if let entrance {
            KeyframeAnimator(initialValue: entrance.startFrame, trigger: entranceTrigger) { frame in
                render(artwork)
                    .scaleEffect(frame.scale)
                    .offset(x: frame.x, y: frame.y)
                    .opacity(frame.opacity)
            } keyframes: { _ in
                entrance.tracks
            }
            // KeyframeAnimator holds its initial value until the trigger
            // *changes*, so the car waits offstage for exactly one update rather
            // than appearing at rest and then rolling in.
            .onAppear { entranceTrigger += 1 }
        } else {
            render(artwork)
        }
    }

    /// The resting render. This is the modifier chain the hero cards have always
    /// used, which is why the resting pixels are unchanged.
    private func render(_ artwork: VehicleArtworkStore.Artwork) -> some View {
        Image(decorative: artwork.image, scale: 1)
            .interpolation(.high)
            .resizable()
            // Taken from the source's true dimensions rather than the decoded
            // thumbnail's rounded ones, so the budget cannot shift the layout.
            .aspectRatio(artwork.sourcePixelSize, contentMode: .fit)
            .scaleEffect(VehicleRenderLayout.zoom, anchor: .center)
            .frame(maxWidth: .infinity)
            .frame(height: VehicleRenderLayout.contentHeight)
            .padding(.horizontal, VehicleRenderLayout.horizontalInset)
    }

    /// The old picture leaves in the direction of travel, the new one arrives
    /// from the other side, and the incoming fade is held back so the two are not
    /// both half-opaque over the same pixels.
    private var crossover: AnyTransition {
        let offset = transition.offset * transitionDirection.outgoingSign
        let fadeIn = Animation.easeOut(duration: transition.duration * transition.fadeInFraction)
            .delay(transition.duration * transition.fadeInDelayFraction)
        return .asymmetric(
            insertion: .offset(x: -offset)
                .combined(with: .scale(scale: transition.incomingScale))
                .combined(with: AnyTransition.opacity.animation(fadeIn)),
            removal: .offset(x: offset)
                .combined(with: .scale(scale: transition.outgoingScale))
                .combined(with: AnyTransition.opacity.animation(
                    .easeOut(duration: transition.duration * transition.fadeOutFraction)
                ))
        )
    }

    // MARK: - Loading

    private func load() async {
        guard let request else { return }
        guard let sourcePixelSize = VehicleArtworkStore.sourcePixelSize(of: request.data) else { return }

        let drawn = VehicleRenderLayout.drawnSize(sourcePixelSize: sourcePixelSize)
        let budget = VehicleArtworkStore.pixelBudget(pointSize: drawn, scale: displayScale)
        let source = VehicleArtworkStore.source(vin: identity.vin, angle: identity.angle)

        let decoded = await artworkStore.artwork(
            source: source,
            data: request.data,
            pixelBudget: budget
        )
        guard let decoded, !Task.isCancelled else { return }

        if let previous = shown {
            // A picture is already here, so this is the user moving around the
            // car. Settle the direction before the identity changes, because the
            // transition is built from it.
            transitionDirection = .between(previous, identity)
            transition = .resolve(
                direction: transitionDirection,
                reduceMotion: VehicleMotionPreference.prefersReducedMotion
            )
            entrance = nil
        } else {
            entrance = VehicleEntranceMotion.resolve(
                style: entranceLedger.style(for: identity),
                identity: identity,
                reduceMotion: VehicleMotionPreference.prefersReducedMotion
            )
            entranceLedger.markPresented(identity)
        }

        artwork = decoded
        shown = identity

        if !identity.isCabin {
            artworkStore.warmExteriorAngles(vin: identity.vin, pixelBudget: budget)
        }
    }
}

// MARK: - Motion to keyframes

extension VehicleEntranceMotion {
    var startFrame: VehicleEntranceFrame { frames().first ?? .rest }

    /// The entrance as SwiftUI sees it: the sampled curves, with the vertical
    /// axis flipped, because SwiftUI's y grows downwards while the curves are
    /// written with up positive, the way suspension travel is usually described.
    func frames() -> [VehicleEntranceFrame] {
        samples().map {
            VehicleEntranceFrame(
                x: $0.translation.x,
                y: -$0.translation.y,
                scale: $0.scale,
                opacity: $0.opacity,
                travelled: $0.travelled
            )
        }
    }

    /// The whole entrance, sampled onto a fixed grid and laid down as keyframes.
    ///
    /// Sampled rather than expressed as a handful of cubic keyframes because the
    /// travel is a braking profile — constant velocity, then a raised cosine to
    /// exactly zero — and no bezier says that. Each property still gets its own
    /// track, and the sampling is the same one that was measured on screen.
    @KeyframesBuilder<VehicleEntranceFrame>
    var tracks: some Keyframes<VehicleEntranceFrame> {
        let steps = frames().dropFirst()
        let step = duration / Double(max(steps.count, 1))

        KeyframeTrack(\VehicleEntranceFrame.x) {
            for value in steps { LinearKeyframe(value.x, duration: step) }
        }
        KeyframeTrack(\VehicleEntranceFrame.y) {
            for value in steps { LinearKeyframe(value.y, duration: step) }
        }
        KeyframeTrack(\VehicleEntranceFrame.scale) {
            for value in steps { LinearKeyframe(value.scale, duration: step) }
        }
        KeyframeTrack(\VehicleEntranceFrame.opacity) {
            for value in steps { LinearKeyframe(value.opacity, duration: step) }
        }
        KeyframeTrack(\VehicleEntranceFrame.travelled) {
            for value in steps { LinearKeyframe(value.travelled, duration: step) }
        }
    }
}

extension VehicleTransitionMotion {
    var animation: Animation {
        // Quick off the mark, long gentle tail: the same deceleration the
        // entrance ends on, so both read as the same vehicle.
        .timingCurve(0.16, 0.72, 0.20, 1.0, duration: duration)
    }
}
