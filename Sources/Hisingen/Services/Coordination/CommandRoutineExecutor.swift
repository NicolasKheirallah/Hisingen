import Foundation

/// How a routine run ended and how far it got.
struct CommandRoutineReport: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// The owner declined the start confirmation. Nothing was sent.
        case declined
        case completed
        /// A step did not send, so the steps after it were never attempted.
        case stopped(stepIndex: Int, reason: String)
    }

    let routineName: String
    let outcome: Outcome
    /// The steps the provider accepted, in the order they were sent.
    let sentSteps: [RemoteCommand]
    let totalSteps: Int
}

/// Runs a routine's steps one at a time through the dispatch every other entry point uses. Each
/// dispatch returns only once the provider has answered, which releases the in-flight lane, so
/// the next step is never refused as busy. Telemetry confirmation for a step runs on its own
/// receipt and does not hold up the sequence. A refusal, a deferral or a failure stops the run,
/// and the steps already sent stay sent.
@MainActor
struct CommandRoutineExecutor {
    typealias Dispatch = (RemoteCommand) async -> RemoteCommandDispatchOutcome

    let dispatch: Dispatch

    /// `confirm` is asked once, before anything is sent, and only when a step needs approval.
    func run(_ routine: CommandRoutine, confirm: (CommandRoutine) -> Bool) async -> CommandRoutineReport {
        if !routine.stepsNeedingConfirmation.isEmpty, !confirm(routine) {
            return report(routine, .declined, sent: [])
        }
        var sent: [RemoteCommand] = []
        for (index, step) in routine.steps.enumerated() {
            switch await dispatch(step) {
            case .sent:
                sent.append(step)
            case .deferred(let reason), .refused(let reason):
                return report(routine, .stopped(stepIndex: index, reason: reason), sent: sent)
            }
        }
        return report(routine, .completed, sent: sent)
    }

    private func report(_ routine: CommandRoutine, _ outcome: CommandRoutineReport.Outcome,
                        sent: [RemoteCommand]) -> CommandRoutineReport {
        CommandRoutineReport(routineName: routine.name, outcome: outcome,
                             sentSteps: sent, totalSteps: routine.steps.count)
    }
}
