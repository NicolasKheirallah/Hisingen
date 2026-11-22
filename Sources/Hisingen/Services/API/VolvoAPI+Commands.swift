import Foundation

extension VolvoAPI {
    /// The car's advertised command names, refreshed before it gates a command once the cached
    /// copy is older than `commandListFreshnessWindow`.
    ///
    /// A failed refresh keeps the last known list and reports it as stale. That is the whole
    /// point of the cache: the list decides whether lock, climate, engine and honk/flash are
    /// offered, so an answer of "no list" would read as "the car advertises nothing" and dim a
    /// control the car still supports. Where there is no earlier list there is nothing to keep,
    /// so the caller gets nil and the probe records no command answers at all, which falls back
    /// to the model table exactly as before this rule existed.
    func advertisedCommandList(vin: String, enabled: Bool) async throws -> AdvertisedCommandList? {
        guard enabled else { return nil }
        if let cached = commandListCache[vin], cached.isFresh(within: Self.commandListFreshnessWindow) {
            return cached
        }
        let subject = Self.endpointBackoffSubject("commands", vin: vin)
        if let until = backoffs.blockedUntil(subject), until > Date() {
            // The endpoint is already standing down from a recent failure. Ask again when the
            // stand-down ends rather than on every refresh in between.
            return lastKnownCommandList(vin)
        }
        do {
            let list: [VolvoCommandDTO] = try await getList(
                "/connected-vehicle/v2/vehicles/\(vin)/commands", scope: .vehicle(vin))
            let value = AdvertisedCommandList(
                names: Set(list.compactMap(\.normalizedName)), fetchedAt: Date(), isStale: false)
            commandListCache[vin] = value
            backoffs.unblock(subject)
            return value
        } catch {
            guard let standDown = Self.optionalStandDown(for: error) else { throw error }
            backoffs.block(subject, until: Date().addingTimeInterval(standDown.duration), reason: nil)
            logger.warning("Volvo command list could not be refreshed, keeping the last known list: \(String(describing: error), privacy: .public)")
            return lastKnownCommandList(vin)
        }
    }

    /// The list this session last confirmed, marked stale so the capability answer can say the
    /// command answers built from it may be out of date.
    private func lastKnownCommandList(_ vin: String) -> AdvertisedCommandList? {
        guard let last = commandListCache[vin] else { return nil }
        let stale = AdvertisedCommandList(names: last.names, fetchedAt: last.fetchedAt, isStale: true)
        commandListCache[vin] = stale
        return stale
    }

    /// Test hook: moves the cached list's confirmation time into the past, so the age rule can be
    /// exercised without waiting out the window.
    func ageCommandList(vin: String, by interval: TimeInterval) {
        guard let entry = commandListCache[vin] else { return }
        commandListCache[vin] = AdvertisedCommandList(
            names: entry.names,
            fetchedAt: entry.fetchedAt.addingTimeInterval(-interval),
            isStale: entry.isStale)
    }

    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        guard commandCatalog.implements(command) else { throw RemoteCommandError.unsupported }
        guard selectedVIN == vin || cars.contains(where: { $0.vin == vin }) else {
            throw RemoteCommandError.missingContext
        }
        guard !remoteCommandsInFlight.contains(vin) else { throw RemoteCommandError.busy }
        remoteCommandsInFlight.insert(vin)
        defer { remoteCommandsInFlight.remove(vin) }
        try await refreshTokenIfNeeded()
        guard let token = accessToken else { throw VolvoError.authenticationRequired(.expiredSession) }
        return try await dispatchCommand(command, vin: vin, accessToken: token)
    }
}
