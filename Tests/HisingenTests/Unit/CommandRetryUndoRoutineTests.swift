import Foundation
import Testing
@testable import Hisingen

@MainActor
struct CommandRetryUndoRoutineTests {

    private let automaticClimate = RemoteCommand.startClimate(
        temperatureCelsius: 0, frontLeftSeat: .unspecified, frontRightSeat: .unspecified,
        rearLeftSeat: .unspecified, rearRightSeat: .unspecified, steeringWheel: .unspecified)

    // MARK: - Undo mapping

    @Test func lockingAndUnlockingReverseEachOther() {
        #expect(RemoteCommand.lock.inverse(previousChargeTarget: nil) == .unlock)
        #expect(RemoteCommand.unlock.inverse(previousChargeTarget: nil) == .lock)
    }

    @Test func windowsAndTailgatePairReverseEachOther() {
        #expect(RemoteCommand.openWindows.inverse(previousChargeTarget: nil) == .closeWindows)
        #expect(RemoteCommand.closeWindows.inverse(previousChargeTarget: nil) == .openWindows)
        #expect(RemoteCommand.openTailgate.inverse(previousChargeTarget: nil) == .closeTailgate)
        #expect(RemoteCommand.closeTailgate.inverse(previousChargeTarget: nil) == .openTailgate)
    }

    @Test func climateAndPreCleaningPairsReverseEachOther() {
        #expect(RemoteCommand.startClimate(temperatureCelsius: 21, frontLeftSeat: .level2,
                                           frontRightSeat: .level2, rearLeftSeat: .off,
                                           rearRightSeat: .off, steeringWheel: .off)
            .inverse(previousChargeTarget: nil) == .stopClimate)
        #expect(RemoteCommand.startPreCleaning.inverse(previousChargeTarget: nil) == .stopPreCleaning)
        #expect(RemoteCommand.stopPreCleaning.inverse(previousChargeTarget: nil) == .startPreCleaning)
    }

    @Test func stoppingClimateRestartsItOnTheAutomaticSetpoint() {
        // The settings it was running at are not recorded, so undo does not guess at them.
        #expect(RemoteCommand.stopClimate.inverse(previousChargeTarget: nil) == automaticClimate)
    }

    @Test func chargeTargetUndoRestoresOnlyAKnownDifferentTarget() {
        #expect(RemoteCommand.setChargeTarget(80).inverse(previousChargeTarget: 60) == .setChargeTarget(60))
        #expect(RemoteCommand.setChargeTarget(80).inverse(previousChargeTarget: nil) == nil)
        #expect(RemoteCommand.setChargeTarget(80).inverse(previousChargeTarget: 80) == nil)
    }

    @Test func commandsWithoutASafeReversalNeverOfferUndo() {
        let irreversible: [RemoteCommand] = [
            .honkHorn, .honkAndFlash, .flashLights, .lockReducedGuard, .unlockTrunk,
            .startEngine(runtimeMinutes: 15), .stopEngine,
            .scheduleOTA(delayMinutes: 5), .installOTANow, .cancelOTA,
            .deleteClimateTimer(id: "timer"), .deleteChargeLocation(id: "location"),
            .setAmpLimit(16), .startChargingOverride, .stopChargingOverride,
        ]
        for command in irreversible {
            #expect(command.inverse(previousChargeTarget: 60) == nil, "\(command.identifier) has no undo")
        }
    }

    // MARK: - Retry eligibility

    @Test func onlyTheProvidersOwnAnswerPermitsRetry() {
        #expect(RemoteCommandFollowUp.permitsRetry(after: RemoteCommandError.busy))
        #expect(RemoteCommandFollowUp.permitsRetry(after: RemoteCommandError.authorizationRequired))
        #expect(RemoteCommandFollowUp.permitsRetry(after: RemoteCommandError.rejected("The vehicle is offline.")))
        // A dropped connection or timeout can land after the vehicle already acted.
        #expect(!RemoteCommandFollowUp.permitsRetry(after: URLError(.timedOut)))
        #expect(!RemoteCommandFollowUp.permitsRetry(after: URLError(.networkConnectionLost)))
        #expect(!RemoteCommandFollowUp.permitsRetry(after: CancellationError()))
    }

    @Test func aFeedbackCarriesItsFollowUpForTheBanner() {
        let retry = RemoteCommandFollowUp(kind: .retry, command: .lock, targetVIN: "YV1TEST")
        let feedback = RemoteCommandFeedback(title: "Command failed", message: "failed", success: false,
                                             followUp: retry)
        #expect(feedback.followUp == retry)
        #expect(RemoteCommandFeedback(title: "t", message: "m", success: true).followUp == nil)
    }

    // MARK: - Routine model

    @Test func onlyStepsAboveRoutineRiskAskForStartConfirmation() {
        let leaveWork = CommandRoutine(name: "Leave work", steps: [
            automaticClimate, .setChargeTarget(80), .lock,
        ])
        #expect(leaveWork.stepsNeedingConfirmation.isEmpty)

        let morning = CommandRoutine(name: "Morning", steps: [
            .unlock, .startClimate(temperatureCelsius: 21, frontLeftSeat: .off, frontRightSeat: .off,
                                   rearLeftSeat: .off, rearRightSeat: .off, steeringWheel: .off),
            .startEngine(runtimeMinutes: 10),
        ])
        #expect(morning.stepsNeedingConfirmation == [.unlock, .startEngine(runtimeMinutes: 10)])
    }

    @Test func routinesRoundTripThroughPreferences() {
        let scoped = ScopedPreferences(label: "routines")
        let routine = CommandRoutine(name: "Leave work", steps: [automaticClimate, .setChargeTarget(80), .lock])
        #expect(scoped.store.commandRoutines.isEmpty)
        scoped.store.commandRoutines = [routine]
        #expect(scoped.store.commandRoutines == [routine])
    }

    // MARK: - Routine executor

    @MainActor
    private final class DispatchRecorder {
        private var outcomes: [RemoteCommandDispatchOutcome]
        private(set) var calls: [RemoteCommand] = []

        init(outcomes: [RemoteCommandDispatchOutcome] = []) {
            self.outcomes = outcomes
        }

        func dispatch(_ command: RemoteCommand) -> RemoteCommandDispatchOutcome {
            calls.append(command)
            return outcomes.isEmpty ? .sent(.completed) : outcomes.removeFirst()
        }
    }

    private let leaveWork = CommandRoutine(name: "Leave work", steps: [
        RemoteCommand.startClimate(temperatureCelsius: 0, frontLeftSeat: .unspecified,
                                   frontRightSeat: .unspecified, rearLeftSeat: .unspecified,
                                   rearRightSeat: .unspecified, steeringWheel: .unspecified),
        .setChargeTarget(80),
        .lock,
    ])

    @Test func aCompletedRoutineSendsEveryStepInOrder() async {
        let recorder = DispatchRecorder()
        let executor = CommandRoutineExecutor { recorder.dispatch($0) }

        let report = await executor.run(leaveWork, confirm: { _ in
            Issue.record("A routine of routine-risk steps must not ask for confirmation")
            return false
        })

        #expect(report.outcome == .completed)
        #expect(report.sentSteps == leaveWork.steps)
        #expect(report.totalSteps == 3)
        #expect(recorder.calls == leaveWork.steps)
    }

    @Test func aFailedStepStopsTheRunAndKeepsThePartialResult() async {
        let recorder = DispatchRecorder(outcomes: [
            .sent(.accepted),
            .refused(reason: "The vehicle is offline."),
            .sent(.accepted),
        ])
        let executor = CommandRoutineExecutor { recorder.dispatch($0) }

        let report = await executor.run(leaveWork, confirm: { _ in true })

        #expect(report.outcome == .stopped(stepIndex: 1, reason: "The vehicle is offline."))
        #expect(report.sentSteps == [leaveWork.steps[0]])
        // The step after the failure was never attempted.
        #expect(recorder.calls == [leaveWork.steps[0], leaveWork.steps[1]])
    }

    @Test func aDeferredStepStopsTheRunToo() async {
        let recorder = DispatchRecorder(outcomes: [.deferred(reason: "Vehicle data is still loading.")])
        let executor = CommandRoutineExecutor { recorder.dispatch($0) }

        let report = await executor.run(leaveWork, confirm: { _ in true })

        #expect(report.outcome == .stopped(stepIndex: 0, reason: "Vehicle data is still loading."))
        #expect(report.sentSteps.isEmpty)
        #expect(recorder.calls.count == 1)
    }

    @Test func aGateRefusalStopsBeforeAnyStepIsSent() async {
        let refusal = "Another remote command is still running."
        let recorder = DispatchRecorder(outcomes: [.refused(reason: refusal)])
        let executor = CommandRoutineExecutor { recorder.dispatch($0) }

        let report = await executor.run(leaveWork, confirm: { _ in true })

        #expect(report.outcome == .stopped(stepIndex: 0, reason: refusal))
        #expect(report.sentSteps.isEmpty)
        #expect(recorder.calls == [leaveWork.steps[0]])
    }

    @Test func aDeclinedConfirmationSendsNothing() async {
        let unlockRoutine = CommandRoutine(name: "Morning", steps: [.unlock, .lock])
        let recorder = DispatchRecorder()
        let executor = CommandRoutineExecutor { recorder.dispatch($0) }
        var asked: [String] = []

        let report = await executor.run(unlockRoutine, confirm: { routine in
            asked.append(routine.name)
            return false
        })

        #expect(report.outcome == .declined)
        #expect(asked == ["Morning"])
        #expect(recorder.calls.isEmpty)
        #expect(report.sentSteps.isEmpty)
    }
}
