import Foundation
import OSLog

/// What one unattended send ended as. Deliberately its own type rather than
/// `RemoteCommandDispatchOutcome`: the queue adds two answers the coordinator cannot give
/// (already queued, cooling down), and a caller that reports "which vehicles failed" needs one
/// value it can compare and print.
enum AutomationSendResult: Equatable, Sendable {
    /// The provider accepted the command.
    case sent
    /// Nothing reached the provider and the send is safe to try again (busy lane, target not
    /// loaded yet).
    case deferred(reason: String)
    /// Refused before or during the send: gate, authorization, cooldown, provider failure.
    case failed(reason: String)
    /// The same command was already on its way to that vehicle.
    case alreadyQueued(reason: String)
    /// The same command went to that vehicle inside its cooldown.
    case coolingDown(reason: String, retryAfter: TimeInterval)

    /// Whether the command reached the provider.
    var didSend: Bool { self == .sent }

    /// The reason to show, for every outcome that carries one.
    var reason: String? {
        switch self {
        case .sent: return nil
        case .deferred(let reason), .failed(let reason), .alreadyQueued(let reason):
            return reason
        case .coolingDown(let reason, _): return reason
        }
    }
}

/// The one lane every unattended command crosses: queue, cooldown, dispatch.
///
/// Two rules make the difference between a feature and a nuisance:
/// - **Once.** One command at a time. The coordinator has a single in-flight slot, so a schedule
///   and a location trigger firing in the same second would otherwise have one of them refused
///   as busy. Here the second one waits its turn, and a duplicate of a command already waiting is
///   refused with a reason instead of being sent twice.
/// - **Not again.** A successful send starts the command's cooldown (see `CommandCooldown`), and
///   a repeat inside it is refused with the wait spelled out.
///
/// Interactive taps do not come through here; a person watching the control is their own
/// throttle. Cooldowns live in memory on purpose: a relaunch is a fresh session, and the
/// schedule ledger already stops an occurrence from firing twice across one.
@MainActor
final class AutomationCommandDispatcher {
    typealias Dispatch = @MainActor (RemoteCommand, String) async -> RemoteCommandDispatchOutcome

    private struct QueuedSend {
        let command: RemoteCommand
        let vin: String
        let continuation: CheckedContinuation<AutomationSendResult, Never>
    }

    private let logger = AppLog.logger("automation")
    private let dispatch: Dispatch
    private let now: @Sendable () -> Date
    private var queue: [QueuedSend] = []
    private var inFlight: (command: RemoteCommand, vin: String)?
    private var successfulSends: [String: Date] = [:]
    private var isDraining = false

    init(dispatch: @escaping Dispatch, now: @escaping @Sendable () -> Date = { Date() }) {
        self.dispatch = dispatch
        self.now = now
    }

    /// How many sends are waiting behind the running one. The settings card shows it so a
    /// stalled queue is visible rather than silent.
    var queuedCount: Int { queue.count }
    var isBusy: Bool { inFlight != nil || !queue.isEmpty }

    /// The last successful send of this command to this vehicle inside the process, for the
    /// settings card's "next allowed" readout.
    func lastSentAt(_ command: RemoteCommand, to vin: String) -> Date? {
        successfulSends[Self.key(command: command, vin: vin)]
    }

    /// Queues the command and resolves with its outcome once it is this send's turn.
    func send(_ command: RemoteCommand, to vin: String) async -> AutomationSendResult {
        let target = vin.normalizedVIN
        guard !target.isEmpty else {
            return .deferred(reason: L10n.text("The target vehicle could not be loaded."))
        }
        if let inFlight, inFlight.command == command, inFlight.vin == target {
            return .alreadyQueued(
                reason: L10n.format("%@ is already on its way to this vehicle.", command.title))
        }
        if queue.contains(where: { $0.command == command && $0.vin == target }) {
            return .alreadyQueued(
                reason: L10n.format("%@ is already queued for this vehicle.", command.title))
        }
        if case .refused(let retryAfter) = cooldown(command, vin: target, now: now()) {
            return .coolingDown(
                reason: CommandCooldown.refusalReason(command: command, retryAfter: retryAfter),
                retryAfter: retryAfter)
        }
        return await withCheckedContinuation { continuation in
            queue.append(QueuedSend(command: command, vin: target, continuation: continuation))
            drainIfNeeded()
        }
    }

    private func cooldown(_ command: RemoteCommand, vin: String, now: Date) -> CommandCooldown.Decision {
        CommandCooldown.evaluate(
            command: command, lastSentAt: successfulSends[Self.key(command: command, vin: vin)],
            now: now)
    }

    private func drainIfNeeded() {
        guard !isDraining, !queue.isEmpty else { return }
        isDraining = true
        Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let item = queue.removeFirst()
            inFlight = (item.command, item.vin)
            let result = await run(item.command, vin: item.vin)
            inFlight = nil
            item.continuation.resume(returning: result)
        }
        isDraining = false
    }

    private func run(_ command: RemoteCommand, vin: String) async -> AutomationSendResult {
        // Re-checked at execution time: a duplicate queued behind a successful send of the same
        // command must not go out once the first one has started the cooldown.
        let sentAt = now()
        if case .refused(let retryAfter) = cooldown(command, vin: vin, now: sentAt) {
            return .coolingDown(
                reason: CommandCooldown.refusalReason(command: command, retryAfter: retryAfter),
                retryAfter: retryAfter)
        }
        logger.info("Automation command \(command.identifier, privacy: .public) queued for \(vin, privacy: .private)")
        switch await dispatch(command, vin) {
        case .sent:
            successfulSends[Self.key(command: command, vin: vin)] = sentAt
            return .sent
        case .deferred(let reason):
            return .deferred(reason: reason)
        case .refused(let reason):
            // A refusal means nothing reached the car, so it must not start a cooldown that
            // would block the reader's own retry a moment later.
            return .failed(reason: reason)
        }
    }

    private static func key(command: RemoteCommand, vin: String) -> String {
        "\(vin.normalizedVIN)|\(command.identifier)"
    }
}
