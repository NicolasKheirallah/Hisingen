import Foundation
import OSLog

/// Always-running scheduler for the reader's saved actions.
///
/// Instead of polling, it looks at the saved schedules, arms one one-shot tick for the next
/// moment an action is due, and re-arms after it fires. `AsyncTimerLoop` runs on the continuous
/// clock, so the tick still lands after a wake from sleep; the schedule's own catch-up window
/// then decides whether that late tick is the same occurrence or a skipped one.
///
/// The command goes through `AutomationCommandDispatcher`, so a schedule shares the queue and the
/// per-command cooldown with every other unattended path. Nothing here holds a provider session
/// or reaches macOS for a permission: it only decides *when*.
@MainActor
final class ScheduledCommandController {
    private let logger = AppLog.logger("automation")
    private let preferences: PreferencesStore
    private let send: @MainActor (RemoteCommand) async -> AutomationSendResult
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let scheduler: AsyncTimerLoop
    private var evaluationInProgress = false
    /// Failed sends of the occurrence in flight, by occurrence key. Cleared on success or when
    /// the limit ends the retries.
    private var failedSends: [String: Int] = [:]

    /// How long to wait before trying a deferred or failed occurrence again.
    static let retryInterval: TimeInterval = 60

    /// How many failed sends of one occurrence end its retries.
    static let maxFailedSends = 3

    /// Never sleep longer than this, so a missed wake notification still gets caught up within
    /// a few hours.
    static let maxIdleInterval: TimeInterval = 6 * 3_600

    init(preferences: PreferencesStore,
         send: @escaping @MainActor (RemoteCommand) async -> AutomationSendResult,
         now: @escaping @Sendable () -> Date = { Date() },
         calendar: Calendar = .current,
         wait: @escaping AsyncTimerLoop.Wait = AsyncTimerLoop.realWait) {
        self.preferences = preferences
        self.send = send
        self.now = now
        self.calendar = calendar
        self.scheduler = AsyncTimerLoop(wait: wait)
    }

    var isArmed: Bool { scheduler.isArmed }

    func start() {
        reload()
    }

    func stop() {
        scheduler.cancel()
    }

    /// Re-reads the schedules. Called at launch and whenever the reader edits one.
    func reload() {
        scheduler.cancel()
        guard !preferences.scheduledCommands.isEmpty else { return }
        Task { @MainActor [weak self] in
            await self?.evaluate()
        }
    }

    /// The next moment an action is due, for the settings card's "next" line.
    func nextFire(now: Date? = nil) -> (schedule: ScheduledCommand, date: Date)? {
        let reference = now ?? self.now()
        return preferences.scheduledCommands
            .filter { $0.isEnabled && AutomationCommandPolicy.allows($0.command) }
            .compactMap { schedule in
                schedule.nextFireDate(after: reference, calendar: calendar)
                    .map { (schedule: schedule, date: $0) }
            }
            .min { $0.date < $1.date }
    }

    func evaluate(now reference: Date? = nil) async {
        guard !evaluationInProgress else { return }
        evaluationInProgress = true
        defer { evaluationInProgress = false }

        let moment = reference ?? now()
        let schedules = preferences.scheduledCommands
        preferences.pruneScheduledCommandFiredOccurrences(keeping: Set(schedules.map(\.id)))

        var retryNeeded = false
        for schedule in schedules {
            guard let fireDate = schedule.isDue(now: moment, calendar: calendar) else { continue }
            let key = ScheduledCommand.occurrenceKey(id: schedule.id, fireDate: fireDate, calendar: calendar)
            guard preferences.scheduledCommandFiredOccurrence(for: schedule.id) != key else { continue }
            // The ledger is written before the send: a provider that answers slowly must not let
            // the next tick send the same occurrence again.
            preferences.setScheduledCommandFiredOccurrence(key, for: schedule.id)
            logger.info("Scheduled command \(schedule.command.identifier, privacy: .public) firing")
            switch await send(schedule.command) {
            case .deferred:
                // Nothing reached the car, so the occurrence goes back in the ledger and a short
                // timer tries it again for as long as the catch-up window lasts.
                preferences.setScheduledCommandFiredOccurrence(nil, for: schedule.id)
                retryNeeded = true
            case .failed:
                // A failure includes a request lost to the network, and every action a schedule
                // can carry is safe to repeat, so it is retried a few times before the
                // occurrence is given up.
                let failures = (failedSends[key] ?? 0) + 1
                if failures < Self.maxFailedSends {
                    failedSends[key] = failures
                    preferences.setScheduledCommandFiredOccurrence(nil, for: schedule.id)
                    retryNeeded = true
                } else {
                    failedSends[key] = nil
                }
            case .sent:
                failedSends[key] = nil
            case .alreadyQueued, .coolingDown:
                break
            }
        }
        scheduleNext(after: max(moment, now()), retrying: retryNeeded)
    }

    /// Arms a single tick for the next due moment (or the idle ceiling when nothing is scheduled).
    /// After a deferral or a failure the tick comes sooner, so the catch-up window is used.
    private func scheduleNext(after moment: Date, retrying: Bool) {
        scheduler.cancel()
        let fallback = moment.addingTimeInterval(Self.maxIdleInterval)
        let next = nextFire(now: moment)?.date
        var target = min(max(next ?? fallback, moment.addingTimeInterval(1)), fallback)
        if retrying {
            target = min(target, moment.addingTimeInterval(Self.retryInterval))
        }
        scheduler.scheduleOnce(after: max(1, target.timeIntervalSince(moment))) { [weak self] in
            await self?.evaluate()
        }
    }
}
