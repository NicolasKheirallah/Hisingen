import Foundation

struct PolestarConsumerSession: Sendable {
    let accessToken: String
    let refreshToken: String?
    let tokenExpiry: Date
    let tokenLifetime: TimeInterval
    let cars: [CarSummary]
    let identities: [String: PolestarAPI.CarIdentity]
    let selectedVIN: String?
    let discoverySucceeded: Bool
    let tokenEndpoint: URL?
    let authorizationEndpoint: URL?
    let userinfoEndpoint: URL?
    let revocationEndpoint: URL?
}

struct PolestarCandidateCommand: Sendable {
    let token: String
    let isCurrent: @Sendable () async -> Bool
}

/// Isolates login work until the facade can commit its complete result.
struct PolestarLoginCandidate: Sendable {
    let api: PolestarAPI

    func password(email: String, password: String, preferredVIN: String?, command: PolestarCandidateCommand? = nil) async throws -> PolestarConsumerSession {
        try await api.discoverOIDCConfiguration()
        let code = try await api.obtainAuthorizationCode(email: email, password: password)
        return try await exchange(code: code.code, verifier: code.verifier, preferredVIN: preferredVIN, command: command)
    }

    func exchange(code: String, verifier: String, preferredVIN: String?, command: PolestarCandidateCommand? = nil) async throws -> PolestarConsumerSession {
        let token = try await api.exchangeCode(code, verifier: verifier,
            clientID: api.oidcClientID, redirectURI: api.oidcRedirectURL)
        await api.installCandidateToken(token)
        if let command, await command.isCurrent() {
            do {
                try await api.verifyCommandAccount(accessToken: command.token)
                if await command.isCurrent() { await api.setCandidateDiscoveryCommand(command) }
            } catch {
                try Task.checkCancellation()
            }
        }
        try await api.fetchCarInfo(preferredVIN: preferredVIN)
        return try await api.candidateSnapshot()
    }
}

struct PolestarCommandOperations {
    private var operations: [String: UUID] = [:]

    mutating func begin(vin: String) -> UUID? {
        guard operations[vin] == nil else { return nil }
        let id = UUID()
        operations[vin] = id
        return id
    }

    func owns(vin: String, id: UUID) -> Bool { operations[vin] == id }

    mutating func finish(vin: String, id: UUID) {
        guard owns(vin: vin, id: id) else { return }
        operations[vin] = nil
    }

    mutating func reset() { operations.removeAll() }
}
