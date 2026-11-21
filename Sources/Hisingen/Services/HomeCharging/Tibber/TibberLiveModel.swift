import Foundation
import OSLog

/// The live stream's part of the charging card, resolved to words the Perific lines already use.
struct TibberLivePresentation: Equatable {
    /// `House 3.4 kW`. `nil` until a frame arrives.
    var houseLine: String?
    /// False when the line shows the last frame received rather than a current one.
    var isLive = false
    /// While the car charges: `Car 2.3 kW, rest of the house 1.1 kW`. Only when both readings are
    /// current and agree closely enough to subtract.
    var splitLine: String?
    /// `Production 2.1 kW`, while the home is producing and the frame is current.
    var productionLine: String?
    /// Set when the frame is last known.
    var freshnessLine: String?

    static func make(reading: TibberLiveMeasurement?, carKw: Double?, now: Date) -> TibberLivePresentation {
        guard let reading else { return TibberLivePresentation(houseLine: nil, splitLine: nil, productionLine: nil, freshnessLine: nil) }
        let current = reading.isCurrent(now: now)
        // The split rules are the Perific ones: both readings current, the car drawing, and the
        // house drawing at least nine tenths of what the car draws.
        var split: String?
        if current, let carKw, carKw >= HomeChargerTelemetry.zeroPowerThresholdKw, reading.importKw >= carKw * 0.9 {
            split = L10n.format("Car %@, rest of the house %@", Format.powerKw(carKw),
                                Format.powerKw(max(0, reading.importKw - carKw)))
        }
        // Production is momentary, so a frame that is no longer current says nothing about now.
        var production: String?
        if current, let kw = reading.productionKw, kw >= 0.1 {
            production = L10n.format("Production %@", Format.powerKw(kw))
        }
        var freshness: String?
        if !current {
            freshness = L10n.format("Pulse last read %@ ago", Format.shortDuration(minutes: max(1, Int(reading.age(now: now) / 60))))
        }
        return TibberLivePresentation(houseLine: L10n.format("House %@", Format.powerKw(reading.importKw)),
                                      isLive: current, splitLine: split, productionLine: production,
                                      freshnessLine: freshness)
    }
}

/// Tibber's live stream for the connected home: the house's grid import from a Pulse (or Watty)
/// reader, and the home's production while it is producing. It draws beside the charger exactly as
/// the Perific lines do, with the same last-known and age rules, and stays absent when the home
/// reports no live reader.
///
/// Read only, like everything that talks to Tibber. The token from the Keychain goes out once, in
/// the stream's `connection_init`, and nowhere else.
@MainActor
final class TibberLiveModel: ObservableObject {
    enum Link: Equatable, Sendable {
        case notConfigured
        case connecting
        case live
        /// The home reports no live reader paired, so there is no stream to read.
        case noPulse
        case reconnecting
        case unauthorized
    }

    @Published private(set) var link: Link = .notConfigured
    @Published private(set) var reading: TibberLiveMeasurement?
    /// Ticks with each frame so ages ("Pulse last read 4 min ago") keep moving.
    @Published private(set) var clock = Date()

    private let store: HomeChargingStore
    private let dependencies: HomeChargingModel.Dependencies
    private let logger = AppLog.logger("tibber-live")
    private var loopTask: Task<Void, Never>?
    private var socket: TibberLiveSocket?
    private var generation = 0

    init(preferences: PreferencesStore, dependencies: HomeChargingModel.Dependencies) {
        self.store = HomeChargingStore(defaults: preferences.d, keychain: preferences.keychain)
        self.dependencies = dependencies
    }

    /// What the charging card shows right now.
    func presentation(carKw: Double?) -> TibberLivePresentation {
        TibberLivePresentation.make(reading: reading, carKw: carKw, now: max(clock, dependencies.now()))
    }

    // MARK: Lifecycle

    func start() {
        guard store.tibberHome != nil, loopTask == nil else { return }
        generation &+= 1
        let current = generation
        loopTask = Task { [weak self] in await self?.run(generation: current) }
    }

    /// Stops and forgets, because the home was disconnected or erased.
    func reset() {
        generation &+= 1
        loopTask?.cancel()
        loopTask = nil
        closeSocket()
        reading = nil
        link = .notConfigured
    }

    // MARK: Loop

    private func run(generation current: Int) async {
        var backoff: TimeInterval = 2
        while !Task.isCancelled, current == generation {
            guard let home = store.tibberHome, let token = (try? store.tibberToken()) ?? nil, !token.isEmpty else {
                link = .notConfigured
                return
            }
            do {
                if link != .live { link = .connecting }
                // The home itself says whether a live reader is paired, so an absent line stays
                // absent instead of a subscription that is refused over and over.
                let stream = try await TibberClient(token: token, transport: dependencies.transport).liveStream(homeID: home.id)
                try Task.checkCancellation()
                guard stream.realTimeEnabled else {
                    link = .noPulse
                    return
                }
                let socket = try await TibberLiveSocket.open(
                    url: stream.url ?? TibberLiveSocket.subscriptionURL, token: token, homeID: home.id,
                    connector: dependencies.tibberSocketConnector ?? URLSessionTibberSocketConnector())
                self.socket = socket
                for await measurement in await socket.measurements() {
                    guard !Task.isCancelled, current == generation else { closeSocket(); return }
                    reading = measurement
                    clock = dependencies.now()
                    link = .live
                }
                closeSocket()
                // The stream ended on its own: a refusal names the reason, anything else reconnects.
                if let failure = await socket.streamFailure {
                    if case .unauthorized = failure { link = .unauthorized; return }
                    if case .rejected(_, let message) = failure, message.lowercased().contains("pulse") {
                        link = .noPulse
                        return
                    }
                }
                link = .reconnecting
                backoff = 2
            } catch DirectChargerError.unauthorized {
                link = .unauthorized
                return
            } catch is CancellationError {
                return
            } catch let error as DirectChargerError {
                link = .reconnecting
                logger.notice("Tibber live stream unavailable: \(String(describing: error), privacy: .private)")
                if case .rateLimited(let retryAfter) = error {
                    let delay = retryAfter.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? Self.retryInterval
                    backoff = max(backoff, min(delay, 86_400))
                }
            } catch {
                link = .reconnecting
            }
            guard !Task.isCancelled, current == generation else { return }
            try? await dependencies.wait(backoff)
            backoff = min(backoff * 2, 300)
        }
    }

    /// How long to wait before asking again when Tibber throttles the live-stream check without
    /// naming a time.
    static let retryInterval: TimeInterval = 60

    private func closeSocket() {
        guard let socket else { return }
        self.socket = nil
        Task { await socket.close() }
    }
}
