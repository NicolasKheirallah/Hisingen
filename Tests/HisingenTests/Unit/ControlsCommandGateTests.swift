import Foundation
import Testing
@testable import Hisingen

/// The two availability questions the Controls tab asks, and why they are not the same question.
///
/// `CapabilityGate` refuses every command while another is in flight, so for the 15 to 30 seconds a
/// charge-limit write takes, every control on the tab is inert. Both the card's dimming and the
/// sentence explaining it used to ask a busy-blind question, which left the reason written for that
/// state unreachable and left the cards looking live while their controls were refused.
@MainActor
struct ControlsCommandGateTests {

    private func makeGate(
        state: VehicleState,
        inFlight: Bool,
        scoped: ScopedPreferences
    ) -> ControlsCommandGate {
        // Hidden by default, and availability refuses a command whose feature is off before it
        // looks at anything else, so the gates below would all answer `.disabledBySettings`.
        var selection = scoped.store.features
        selection.set(.remoteLocks, enabled: true)
        scoped.store.features = selection

        return ControlsCommandGate(
            state: state,
            brand: .polestar,
            preferences: scoped.store,
            remoteCommandInProgress: inFlight,
            inFlightCommandID: RemoteCommand.lock.identifier,
            onRemoteCommand: { _ in }
        )
    }

    @Test
    func anIdleVehicleCanLockAndUnlock() {
        let scoped = ScopedPreferences(label: "controls-gate")
        let gate = makeGate(state: vehicle(), inFlight: false, scoped: scoped)

        #expect(gate.liveAvailability([.lock, .unlock]) == .available)
        #expect(gate.liveOpacity([.lock, .unlock]) == 1.0)
        #expect(!gate.isDisabled(.lock))
    }

    @Test
    func aCommandInFlightIsTheReasonTheCardShows() {
        let scoped = ScopedPreferences(label: "controls-gate")
        let gate = makeGate(state: vehicle(), inFlight: true, scoped: scoped)

        #expect(gate.liveAvailability([.lock, .unlock]) == .unavailableWhileBusy)
        // The card dims while its controls are refused, so "dead control on a bright card" cannot
        // happen while the tab is busy.
        #expect(gate.liveOpacity([.lock, .unlock]) == 0.6)
        #expect(gate.isDisabled(.lock))
    }

    @Test
    func theBusyReasonIsReachable() {
        let scoped = ScopedPreferences(label: "controls-gate")
        let gate = makeGate(state: vehicle(), inFlight: true, scoped: scoped)

        // This is the sentence that existed in `CapabilityGate` with no caller able to render it.
        let reason = gate.liveAvailability([.lock, .unlock]).shortReason
        #expect(reason != nil)
        #expect(reason?.isEmpty == false)
    }

    @Test
    func theCapabilityQuestionStaysBlindToBusy() {
        let scoped = ScopedPreferences(label: "controls-gate")
        let gate = makeGate(state: vehicle(), inFlight: true, scoped: scoped)

        // The re-probe button appears when a card is restricted by the vehicle or by settings,
        // which is the condition a re-probe could change. A card dimmed only because a command is
        // running must not make that button appear and disappear on every tap.
        #expect(gate.capabilityAvailability([.lock, .unlock]) == .available)
    }

    @Test
    func aStaleReadingOutranksTheBusyState() {
        let scoped = ScopedPreferences(label: "controls-gate")
        let gate = makeGate(
            state: vehicle(fetchedAt: Date().addingTimeInterval(-20 * 60)),
            inFlight: true,
            scoped: scoped
        )

        // Refreshing is something the user can act on; waiting for a command is not. The busy flag
        // must not mask the more actionable reason.
        #expect(gate.liveAvailability([.lock, .unlock]) == .unavailableUntilRefresh)
    }
}

/// The second visual channel a chart gains when the reader has asked the system to differentiate
/// without colour. `accessibilityDifferentiateWithoutColor` appeared nowhere in the app, so the two
/// series that share axes were told apart by hue alone, which is what a colour-blind reader cannot
/// use.
@MainActor
struct ChartSeriesStrokeTests {

    @Test
    func theFirstSeriesNeverChanges() {
        // It does not need a second channel: the other series carries it.
        #expect(chartSeriesStroke(index: 0, differentiateWithoutColor: true, width: 1.2).dash.isEmpty)
        #expect(chartSeriesStroke(index: 0, differentiateWithoutColor: false, width: 1.2).dash.isEmpty)
    }

    @Test
    func theSecondSeriesIsDashedOnlyWhenTheSettingIsOn() {
        #expect(chartSeriesStroke(index: 1, differentiateWithoutColor: true, width: 1.2).dash.isEmpty == false)
        #expect(chartSeriesStroke(index: 1, differentiateWithoutColor: false, width: 1.2).dash.isEmpty)
    }

    @Test
    func seriesKeepTheirWidth() {
        // The dash is added, the stroke is not restyled: a second channel must not also be a
        // second weight, or the chart reads as two different measurements.
        #expect(chartSeriesStroke(index: 1, differentiateWithoutColor: true, width: 1.2).lineWidth == 1.2)
        #expect(chartSeriesStroke(index: 0, differentiateWithoutColor: true, width: 1.2).lineWidth == 1.2)
    }

    @Test
    func theLegendAgreesWithTheChart() {
        #expect(chartSeriesIsDashed(index: 1, differentiateWithoutColor: true))
        #expect(!chartSeriesIsDashed(index: 0, differentiateWithoutColor: true))
        #expect(!chartSeriesIsDashed(index: 1, differentiateWithoutColor: false))
    }
}
