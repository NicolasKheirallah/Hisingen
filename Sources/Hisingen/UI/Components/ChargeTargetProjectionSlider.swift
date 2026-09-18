import SwiftUI

/// The projection row that sits under the charge-target slider: while the reader drags, it
/// shows what the car itself implies the draft target costs in time and range, and when the
/// drag ends it goes with the draft.
///
/// The projection is `InstrumentMath.chargeProjection`'s output and nothing else: time from
/// power and capacity, range from the car's own average consumption. When an input is
/// missing the corresponding figure is simply absent — a row with no figures is the honest
/// state, and an invented number is never shown. When capacity had to be derived from
/// available-energy ÷ percentage rather than a reported figure, a quiet marker says so.
///
/// The slider itself stays where it was: `ChargingControlsCard` owns the draft, the bounds
/// and the dispatch, and a second slider bound to the same draft would be two controls for
/// one value.
@MainActor
struct ChargeTargetProjection: View {
    let state: VehicleState
    /// The value the reader is dragging (or has settled on), before dispatch.
    let draftPercent: Int
    let distanceUnit: DistanceUnit

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var projection: InstrumentMath.ChargeProjection? {
        InstrumentMath.chargeProjection(
            currentPercent: state.energy.batteryPercentage,
            targetPercent: draftPercent,
            availableEnergyKwh: state.energy.diagnostics?.energyAvailableKwh,
            reportedCapacityKwh: nil,
            averageConsumptionKwhPer100Km: state.energy.diagnostics?.averageConsumption,
            powerKw: state.energy.powerWatts.map { Double($0) / 1_000 }
        )
    }

    var body: some View {
        if let projection {
            HStack(spacing: 10) {
                if let minutes = projection.minutesToTarget {
                    Label {
                        Text(L10n.format("%d min to target", minutes))
                            .hisType(.micro, weight: .medium)
                    } icon: {
                        Image(systemName: "timer")
                            .hisType(.micro)
                    }
                }
                if let range = projection.addedRangeKm {
                    Label {
                        Text(L10n.format("+%@ range", Format.distance(km: range, unit: distanceUnit)))
                            .hisType(.micro, weight: .medium)
                    } icon: {
                        Image(systemName: "gauge.with.needle")
                            .hisType(.micro)
                    }
                }
                if projection.capacityIsDerived {
                    Image(systemName: "circle.questionmark")
                        .hisType(.nano)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel(L10n.text("Capacity derived from the car's available-energy reading"))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(HisingenTheme.inkMuted)
            .monospacedDigit()
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .hisAnimation(reduceMotion ? nil : Motion.interaction, value: draftPercent)
        }
    }
}
