import Foundation

/// Tibber import prices through Home Assistant's `tibber.get_prices` action.
enum HomeTibberPrices {
    /// Best effort: an install without Tibber, or one whose action refuses the range, yields no
    /// prices and the sessions are priced from Hisingen's own rate settings instead.
    static func fetch(client: HomeAssistantClient, home: String?, from start: Date, to end: Date,
                      timeZone: TimeZone) async -> [HomePricePoint] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let data: HAJSONValue = .object([
            "start": .string(formatter.string(from: start)),
            "end": .string(formatter.string(from: end))
        ])
        guard let result = try? await client.callService(domain: "tibber", service: "get_prices", data: data, returnResponse: true),
              let response = result.response else { return [] }
        return TibberPriceResponse.points(from: response, home: home)
    }
}

/// Brings the charger's completed sessions into Hisingen's charging history.
///
/// Safe to run any number of times, at any moment: every session carries a stable key, a repeated
/// sync lands on the rows it already wrote, and a session still running is left for a later pass.
enum HomeSessionSync {
    struct Summary: Equatable, Sendable {
        var inserted = 0
        var enriched = 0
        var updated = 0
        var merged = 0
        var unchanged = 0
        var unassigned = 0
        var captureComponentAnswered = false
        /// Local history is switched off in Settings, so nothing was written.
        var skippedByPrivacy = false
        var windowStart: Date?
        var finishedAt: Date?

        var changedRows: Int { inserted + enriched + updated + merged }
    }

    /// Home Assistant's recorder keeps ten days of state history unless the install changed it.
    static let defaultLookback: TimeInterval = 10 * 86_400

    struct Environment {
        var client: HomeAssistantClient
        var pairing: HomeChargingPairing
        var ledger: ChargingSessionLedger
        var recordingEnabled: Bool
        var fallback: HomeSessionPricer.Fallback
        var now: Date
    }

    static func run(_ environment: Environment) async throws -> Summary {
        var summary = Summary(finishedAt: environment.now)
        guard environment.recordingEnabled else {
            summary.skippedByPrivacy = true
            return summary
        }
        let pairing = environment.pairing
        let ledger = environment.ledger
        let now = environment.now

        let earliest = now.addingTimeInterval(-defaultLookback)
        let cursor = ledger.latestWallboxEnd(chargerID: pairing.chargerID).map { $0.addingTimeInterval(-86_400) }
        let windowStart = max(earliest, cursor ?? earliest)
        summary.windowStart = windowStart

        var candidates: [HomeChargingSessionCandidate] = []

        // 1. The durable capture component, when it is installed.
        let capture = try await captureSessions(client: environment.client, pairing: pairing, since: windowStart.addingTimeInterval(-86_400))
        summary.captureComponentAnswered = capture != nil
        candidates += capture ?? []

        // 2. The recorder history of the charger's own sensors.
        let entities = pairing.entities
        if let statusID = entities.chargingState, let energyID = entities.sessionEnergy {
            var ids = [statusID, energyID]
            if let power = entities.power { ids.append(power) }
            let history = try await environment.client.history(entityIDs: ids, from: windowStart, to: now)
            let reconstructed = HomeSessionReconstructor.reconstruct(
                chargerID: pairing.chargerID,
                status: history[statusID] ?? [], energy: history[energyID] ?? [],
                power: entities.power.flatMap { history[$0] } ?? [], now: now
            )
            // A capture record for the same charge is the stronger source; do not feed the weaker twin.
            candidates += reconstructed.filter { weaker in
                !candidates.contains { stronger in
                    stronger.keyKind.rank > weaker.keyKind.rank && overlaps(stronger, weaker)
                }
            }
        }
        guard !candidates.isEmpty else { return summary }

        // 3. Prices, once for the whole span.
        let span = (start: candidates.map(\.startedAt).min()!, end: candidates.map(\.endedAt).max()!)
        let tibber = await HomeTibberPrices.fetch(
            client: environment.client, home: pairing.tibberHome,
            from: span.start.addingTimeInterval(-3_600), to: span.end.addingTimeInterval(3_600),
            timeZone: pairing.timeZone
        )

        // 4. Match each session to its vehicle and write it. Strongest key first.
        for candidate in candidates.sorted(by: { $0.keyKind.rank > $1.keyKind.rank }) {
            let observed = ledger.observedVehicleSessions(from: candidate.startedAt, to: candidate.endedAt)
            let decision = HomeSessionAttribution.decide(candidate: candidate, pairing: pairing, observed: observed)
            let cost = HomeSessionPricer.price(candidate, tibber: tibber, networkFeeOrePerKwh: pairing.networkFeeOrePerKwh,
                                               fallback: environment.fallback)
            guard let result = ledger.recordWallboxSession(candidate, decision: decision, cost: cost,
                                                           locationName: pairing.locationAlias) else { continue }
            switch result.kind {
            case .inserted: summary.inserted += 1
            case .enriched: summary.enriched += 1
            case .updated: summary.updated += 1
            case .merged: summary.merged += 1
            case .unchanged: summary.unchanged += 1
            }
            if case .unassigned = decision, result.kind == .inserted { summary.unassigned += 1 }
        }
        return summary
    }

    /// `nil` when the component is not installed (Home Assistant says it does not know the action).
    private static func captureSessions(client: HomeAssistantClient, pairing: HomeChargingPairing,
                                        since: Date) async throws -> [HomeChargingSessionCandidate]? {
        let data: HAJSONValue = .object(["charger_id": .string(pairing.chargerID), "since": .string(HATimestamp.format(since))])
        do {
            let result = try await client.callService(domain: "hisingen_home_charging", service: "get_sessions",
                                                      data: data, returnResponse: true)
            guard let response = result.response else { return [] }
            return HomeCaptureSessions.candidates(from: response, chargerID: pairing.chargerID)
        } catch HomeAssistantError.notFound {
            return nil
        } catch HomeAssistantError.rejected(let status, _) where status == 400 {
            return nil
        }
    }

    private static func overlaps(_ a: HomeChargingSessionCandidate, _ b: HomeChargingSessionCandidate) -> Bool {
        let overlap = min(a.endedAt, b.endedAt).timeIntervalSince(max(a.startedAt, b.startedAt))
        let shorter = max(60, min(a.endedAt.timeIntervalSince(a.startedAt), b.endedAt.timeIntervalSince(b.startedAt)))
        return overlap / shorter >= HomeSessionAttribution.requiredOverlap
    }
}
