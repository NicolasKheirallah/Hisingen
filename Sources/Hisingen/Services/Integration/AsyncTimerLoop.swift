import Foundation

/// One shared Task.sleep-based scheduler replacing the hand-rolled Timer/reentrancy idioms
/// sibling services each maintained (repeating `Timer.scheduledTimer`, one-shot
/// `Timer(timeInterval:)` + run-loop mode, `Task.sleep` while-loops). Task-based ticks are
/// immune to run-loop modes – a status-item menu no longer defers them – and cancellation is
/// structural, with no invalidation bookkeeping to drift out of sync.
@MainActor
final class AsyncTimerLoop {
    private var task: Task<Void, Never>?
    /// Bumped on every (re)arm and cancel so a superseded run cannot clear a newer handle.
    private var epoch = UUID()

    /// True while a tick is armed; mirrors `Timer.isValid` for one-shot schedules.
    var isArmed: Bool { task != nil }

    /// Arms a single tick `delay` seconds from now, replacing any pending schedule.
    func scheduleOnce(after delay: TimeInterval,
                      _ tick: @escaping @MainActor () async -> Void) {
        arm(after: delay, interval: nil, tick: tick)
    }

    /// Arms a tick every `interval` seconds (the first after `interval`), replacing any
    /// previous loop. Inject the interval so tests do not wait real minutes.
    func scheduleRepeating(after interval: TimeInterval,
                           _ tick: @escaping @MainActor () async -> Void) {
        arm(after: interval, interval: interval, tick: tick)
    }

    /// Cancels the armed tick or loop. Safe to call repeatedly.
    func cancel() {
        epoch = UUID()
        task?.cancel()
        task = nil
    }

    private func arm(after delay: TimeInterval, interval: TimeInterval?,
                     tick: @escaping @MainActor () async -> Void) {
        cancel()
        let armedEpoch = epoch
        task = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, delay))) } catch { return }
            while !Task.isCancelled {
                await tick()
                guard let interval else { break }
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
            guard let self, self.epoch == armedEpoch else { return }
            self.task = nil
        }
    }
}
