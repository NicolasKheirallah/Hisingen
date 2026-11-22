import Foundation
import Testing
@testable import Hisingen

/// The unattended command lane: one send at a time, a duplicate while one is in flight is refused
/// instead of doubled, and a command inside its cooldown is refused with the wait spelled out.
@Suite(.serialized)
@MainActor
struct CommandQueueAndCooldownTests {
    private let vin = "YSMQUEUETEST00001"

    // MARK: - Queue

    @Test
    func aQueuedCommandRunsOnceEvenWhenTheCallerRepeatsIt() async {
        let gate = DispatchGate()
        var dispatched: [String] = []
        let dispatcher = AutomationCommandDispatcher(dispatch: { command, _ in
            dispatched.append(command.identifier)
            await gate.enter()
            return .sent(.accepted)
        })

        let first = Task { await dispatcher.send(.lock, to: vin) }
        await gate.waitForEntry()

        let duplicate = await dispatcher.send(.lock, to: vin)

        await gate.release()
        let firstResult = await first.value

        #expect(firstResult == .sent)
        #expect(dispatched == ["lock"])
        guard case .alreadyQueued(let reason) = duplicate else {
            Issue.record("expected the in-flight duplicate to be refused as already queued, got \(duplicate)")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test
    func differentCommandsAreSentOneAfterAnotherAndEachOnce() async {
        var dispatched: [String] = []
        let dispatcher = AutomationCommandDispatcher(dispatch: { command, _ in
            dispatched.append(command.identifier)
            return .sent(.delivered)
        })

        let first = await dispatcher.send(.lock, to: vin)
        let second = await dispatcher.send(.closeWindows, to: vin)

        #expect(first == .sent)
        #expect(second == .sent)
        #expect(dispatched == ["lock", "close-windows"])
        #expect(dispatcher.queuedCount == 0)
        #expect(dispatcher.isBusy == false)
    }

    @Test
    func aCommandWithoutAVehicleDefersWithoutDispatching() async {
        var dispatchCount = 0
        let dispatcher = AutomationCommandDispatcher(dispatch: { _, _ in
            dispatchCount += 1
            return .sent(.accepted)
        })

        let result = await dispatcher.send(.lock, to: "   ")

        // Nothing was sent, so a later trigger or schedule tick may still try once a car is loaded.
        guard case .deferred(let reason) = result else {
            Issue.record("expected a deferral, got \(result)")
            return
        }
        #expect(!reason.isEmpty)
        #expect(dispatchCount == 0)
    }

    // MARK: - Cooldown

    @Test
    func aDuplicateInsideTheCooldownIsRefusedWithAReason() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_790_000_000))
        var dispatchCount = 0
        let dispatcher = AutomationCommandDispatcher(
            dispatch: { _, _ in
                dispatchCount += 1
                return .sent(.accepted)
            },
            now: { clock.now }
        )

        #expect(await dispatcher.send(.lock, to: vin) == .sent)

        let duplicate = await dispatcher.send(.lock, to: vin)

        guard case .coolingDown(let reason, let retryAfter) = duplicate else {
            Issue.record("expected a cooldown refusal, got \(duplicate)")
            return
        }
        #expect(reason == CommandCooldown.refusalReason(command: .lock, retryAfter: retryAfter))
        #expect(!reason.isEmpty)
        #expect(abs(retryAfter - 30) < 0.001)
        #expect(dispatchCount == 1)

        // Past the interval the same command goes out again.
        clock.advance(by: 31)
        #expect(await dispatcher.send(.lock, to: vin) == .sent)
        #expect(dispatchCount == 2)
    }

    @Test
    func aRefusedSendDoesNotStartACooldown() async {
        var outcomes: [RemoteCommandDispatchOutcome] = [
            .refused(reason: "The vehicle did not accept the command."),
            .sent(.accepted),
        ]
        var dispatchCount = 0
        let dispatcher = AutomationCommandDispatcher(dispatch: { _, _ in
            dispatchCount += 1
            return outcomes.removeFirst()
        })

        let refused = await dispatcher.send(.lock, to: vin)
        let retried = await dispatcher.send(.lock, to: vin)

        guard case .failed(let reason) = refused else {
            Issue.record("expected the first send to fail, got \(refused)")
            return
        }
        #expect(reason == "The vehicle did not accept the command.")
        #expect(retried == .sent)
        #expect(dispatchCount == 2)
    }

    @Test
    func aDeferralIsReportedSeparatelyFromAFailure() async {
        let dispatcher = AutomationCommandDispatcher(dispatch: { _, _ in
            .deferred(reason: "Vehicle data is still loading.")
        })

        let result = await dispatcher.send(.lock, to: vin)

        #expect(result == .deferred(reason: "Vehicle data is still loading."))
    }

    @Test
    func theCooldownTableCoversThePlannedActionsAndNothingElse() {
        #expect(CommandCooldown.interval(for: .lock) == 30)
        #expect(CommandCooldown.interval(for: .closeWindows) == 60)
        #expect(CommandCooldown.interval(for: .startClimate(
            temperatureCelsius: 21, frontLeftSeat: .off, frontRightSeat: .off,
            rearLeftSeat: .off, rearRightSeat: .off, steeringWheel: .off)) == 120)
        #expect(CommandCooldown.interval(for: .startChargingOverride) == 120)
        // Commands an unattended path never sends carry no interval rather than a hidden one.
        #expect(CommandCooldown.interval(for: .honkHorn) == 0)
        #expect(CommandCooldown.interval(for: .setChargeTarget(80)) == 0)
    }

    @Test
    func aClockThatMovedBackwardsDoesNotFreezeTheCommand() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let future = now.addingTimeInterval(3_600)
        #expect(CommandCooldown.evaluate(command: .lock, lastSentAt: future, now: now) == .allowed)
    }

    // MARK: - Policy

    @Test
    func onlyRoutineCommandsCanRunUnattended() {
        #expect(AutomationCommandPolicy.allows(.lock))
        #expect(AutomationCommandPolicy.allows(.closeWindows))
        #expect(AutomationCommandPolicy.allows(.startChargingOverride))
        // Everything a person has to approve stays a deliberate tap in the Controls tab.
        #expect(AutomationCommandPolicy.allows(.unlock) == false)
        #expect(AutomationCommandPolicy.allows(.openWindows) == false)
        #expect(AutomationCommandPolicy.allows(.honkHorn) == false)
        #expect(AutomationCommandPolicy.allows(.installOTANow) == false)
        #expect(AutomationCommandPolicy.choices().allSatisfy(AutomationCommandPolicy.allows))
        #expect(AutomationCommandPolicy.choices().contains(.lock))
        #expect(AutomationCommandPolicy.choices().contains(.closeWindows))
    }
}

// MARK: - Clock

/// A clock the test can move. `@unchecked Sendable` because the dispatcher reads it from a
/// Sendable closure while the test advances it between awaits on the main actor; the lock keeps
/// the read and the write from interleaving.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }
}

// MARK: - Gate

/// Holds the first dispatch inside the queue so a second caller arrives while it is in flight.
private actor DispatchGate {
    private var entered = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitForEntry() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
