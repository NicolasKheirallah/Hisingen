import SwiftUI

/// The living layer over the hero render: the car's actual state drawn on the car.
///
/// Every effect here is a *report*, not decoration, and each has exactly one trigger:
///
/// - An open or ajar opening (door, window, hood, tailgate, sunroof, charge lid) places an
///   amber marker at its position along the body, so ajar reads at a glance instead of only
///   in the openings card's rows.
/// - An active climate session breathes warmth up from the vent line, using the theme accent
///   at its documented tinted-fill ceiling — the same "warm where things act" the chips use.
/// - An active charging session runs the energy particle rail beneath the body, the same
///   GPU flow the battery gauge uses, so "energy arriving" reads as one system everywhere.
///
/// With none of those signals the layer draws nothing at all: an empty overlay is the honest
/// resting state, and a healthy car does not glow. Ambient effects stop under
/// `ambientMotionAllowed` (panel not visible) and collapse to their static resting state
/// under Reduce Motion; the opening markers are static information and stay.
///
/// VoiceOver reads the openings card, which carries the same facts as rows it can walk, so
/// this layer is hidden from accessibility rather than duplicating it as one unexplainable
/// blob of markers.
@MainActor
struct LivingVehicleView: View {
    let state: VehicleState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ambientMotionAllowed) private var ambientMotionAllowed

    /// Markers for the openings the car itself reported as not closed. `unknown` draws
    /// nothing: an unrecognised provider token is not a state the layer can vouch for.
    /// A pure function over the snapshot so the state-to-marker contract is testable.
    static func openingMarkers(from exterior: ExteriorSnapshot?) -> [VehicleOpening] {
        guard let exterior else { return [] }
        let open: Set<VehicleOpening> = Set(
            exterior.openings
                .filter { $0.state == .open || $0.state == .ajar }
                .map(\.opening)
        )
        // Both front doors read as one marker at the front-door position, and both rear doors
        // as one at the rear-door position: the silhouette is a side profile, where a pair
        // occupies one place.
        var markers: [VehicleOpening] = []
        if open.contains(.frontLeftDoor) || open.contains(.frontRightDoor) { markers.append(.frontLeftDoor) }
        if open.contains(.rearLeftDoor) || open.contains(.rearRightDoor) { markers.append(.rearLeftDoor) }
        for remaining in [VehicleOpening.hood, .tailgate, .sunroof, .chargeLid] where open.contains(remaining) {
            markers.append(remaining)
        }
        return markers
    }

    private var openOpenings: [VehicleOpening] {
        Self.openingMarkers(from: state.exteriorStatus)
    }

    private var climateRunning: Bool {
        state.climateStatus?.activity.isActiveSession == true
    }

    private var isCharging: Bool { state.isCharging }

    var body: some View {
        ZStack {
            if climateRunning, ambientMotionAllowed, !reduceMotion {
                ClimateBreath()
                    .allowsHitTesting(false)
            }
            if !openOpenings.isEmpty {
                OpeningMarkers(openings: openOpenings)
                    .allowsHitTesting(false)
            }
            if isCharging, ambientMotionAllowed, !reduceMotion {
                ChargeRail()
                    .allowsHitTesting(false)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Warmth rising from the vent line. One breath, tiny deltas, the accent doing the only
/// colour work — never a new hue, never a glow strong enough to outline the car.
@MainActor
private struct ClimateBreath: View {
    @State private var breathing = false

    var body: some View {
        RadialGradient(
            colors: [HisingenTheme.accent.opacity(0.10), Color.clear],
            center: UnitPoint(x: 0.5, y: 0.82),
            startRadius: 10,
            endRadius: 120
        )
        .opacity(breathing ? 0.6 : 1.0)
        .onAppear { breathing = true }
        .onDisappear { breathing = false }
        .animation(Motion.breath, value: breathing)
    }
}

/// A marker per open opening, placed by body position. The fractions are positions along a
/// side-profile body — hood toward the leading edge, tailgate toward the trailing edge — and
/// deliberately approximate: the marker's job is "here is what is open", and the openings
/// card carries the precise list.
@MainActor
private struct OpeningMarkers: View {
    let openings: [VehicleOpening]

    /// (body position along x, height along y) for a side profile, in unit points.
    private func position(for opening: VehicleOpening) -> UnitPoint {
        switch opening {
        case .hood: return UnitPoint(x: 0.16, y: 0.52)
        case .frontLeftDoor, .frontRightDoor: return UnitPoint(x: 0.38, y: 0.60)
        case .rearLeftDoor, .rearRightDoor: return UnitPoint(x: 0.62, y: 0.60)
        case .sunroof: return UnitPoint(x: 0.50, y: 0.24)
        case .chargeLid: return UnitPoint(x: 0.82, y: 0.58)
        case .tailgate: return UnitPoint(x: 0.88, y: 0.55)
        default: return UnitPoint(x: 0.5, y: 0.60)
        }
    }

    var body: some View {
        GeometryReader { geo in
            ForEach(openings, id: \.self) { opening in
                let point = position(for: opening)
                OpeningMarker()
                    .position(x: point.x * geo.size.width, y: point.y * geo.size.height)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .hisAnimation(Motion.stateChange, value: openings)
    }
}

/// One amber marker: a small filled dot with a ring, sized to read at hero scale without
/// competing with the render. Warning-tinted on purpose: an open body panel is a state to
/// attend to, and semantics — not accent — mark state.
@MainActor
private struct OpeningMarker: View {
    var body: some View {
        Circle()
            .fill(HisingenTheme.semanticWarning)
            .frame(width: 7, height: 7)
            .overlay {
                Circle()
                    .stroke(HisingenTheme.semanticWarning.opacity(0.35), lineWidth: 3)
            }
    }
}

/// The energy rail: the charging particle flow running in a slim track beneath the body, plus
/// the connector chip at the trailing edge. Reuses the gauge's CAEmitterLayer flow so the
/// charging bar, the mini panel and the hero read as one system.
@MainActor
private struct ChargeRail: View {
    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            ZStack(alignment: .trailing) {
                Capsule()
                    .fill(Color.clear)
                    .frame(height: 6)
                    .overlay {
                        ChargingParticleFlow(
                            tint: HisingenTheme.accent,
                            isActive: true
                        )
                        .clipShape(Capsule())
                    }
                Image(systemName: "bolt.fill")
                    .hisType(.micro)
                    .foregroundStyle(HisingenTheme.accent)
            }
            .padding(.horizontal, 4)
        }
    }
}
