import Foundation
import Testing
@testable import Hisingen

/// Every branch of `RemoteActionAuthorizer.authorize(_:vehicle:)`, with the confirmation alert and
/// the `LAContext` prompt replaced by recorders so nothing blocks the test host.
@MainActor
struct RemoteActionAuthorizerTests {

    /// Records what the authorizer asked for and answers with canned results.
    @MainActor
    final class Recorder {
        var confirmations: [RemoteCommand] = []
        var authenticationReasons: [String] = []
        var reportedFailures = 0
        var confirmAnswer = true
        var authentication: RemoteActionAuthorizer.OwnerAuthentication = .succeeded

        func authorizer(preferences: PreferencesStore) -> RemoteActionAuthorizer {
            RemoteActionAuthorizer(
                preferences: preferences,
                confirm: { command, _ in
                    self.confirmations.append(command)
                    return self.confirmAnswer
                },
                authenticateOwner: { reason in
                    self.authenticationReasons.append(reason)
                    return self.authentication
                },
                reportAuthenticationFailure: { _ in self.reportedFailures += 1 }
            )
        }
    }

    private func preferences(_ label: String, biometrics: Bool) -> ScopedPreferences {
        let scoped = ScopedPreferences(label: label)
        scoped.store.requireBiometricsForRemoteControls = biometrics
        return scoped
    }

    @Test("Routine commands with biometrics off pass without any prompt")
    func routineCommandWithoutBiometricsIsAllowedSilently() async {
        let scoped = preferences("authorizer-routine", biometrics: false)
        let recorder = Recorder()
        let authorizer = recorder.authorizer(preferences: scoped.store)

        for command in [RemoteCommand.lock, .flashLights, .stopClimate, .setChargeTarget(80)] {
            #expect(command.risk == .routine)
            #expect(await authorizer.authorize(command, vehicle: "Test Car"))
        }
        #expect(recorder.confirmations.isEmpty)
        #expect(recorder.authenticationReasons.isEmpty)
    }

    @Test("A destructive command asks for confirmation and stops when it is declined")
    func declinedConfirmationRefusesTheCommand() async {
        let scoped = preferences("authorizer-declined", biometrics: false)
        let recorder = Recorder()
        recorder.confirmAnswer = false

        let allowed = await recorder.authorizer(preferences: scoped.store).authorize(.installOTANow, vehicle: "Test Car")

        #expect(!allowed)
        #expect(recorder.confirmations == [.installOTANow])
        #expect(recorder.authenticationReasons.isEmpty)
    }

    @Test("A confirmed destructive command still needs the owner check")
    func confirmedDestructiveCommandRunsOwnerCheck() async {
        let scoped = preferences("authorizer-confirmed", biometrics: false)
        let recorder = Recorder()

        let allowed = await recorder.authorizer(preferences: scoped.store).authorize(.installOTANow, vehicle: "Test Car")

        #expect(allowed)
        #expect(recorder.confirmations == [.installOTANow])
        #expect(recorder.authenticationReasons.count == 1)
        #expect(recorder.authenticationReasons.first?.contains("Test Car") == true)
    }

    @Test("A security-sensitive command needs confirmation and the owner check")
    func securitySensitiveCommandRunsBothSteps() async {
        let scoped = preferences("authorizer-unlock", biometrics: false)
        let recorder = Recorder()

        let allowed = await recorder.authorizer(preferences: scoped.store).authorize(.unlock, vehicle: "Test Car")

        #expect(allowed)
        #expect(recorder.confirmations == [.unlock])
        #expect(recorder.authenticationReasons.count == 1)
        #expect(recorder.reportedFailures == 0)
    }

    @Test("Biometrics on routes even a routine command through both steps")
    func biometricsSettingGatesRoutineCommands() async {
        let scoped = preferences("authorizer-biometrics", biometrics: true)
        let recorder = Recorder()

        let allowed = await recorder.authorizer(preferences: scoped.store).authorize(.lock, vehicle: "Test Car")

        #expect(allowed)
        #expect(recorder.confirmations == [.lock])
        #expect(recorder.authenticationReasons.count == 1)
    }

    @Test("A failed owner check refuses the command and reports it")
    func failedOwnerCheckRefusesAndReports() async {
        let scoped = preferences("authorizer-owner-failed", biometrics: false)
        let recorder = Recorder()
        recorder.authentication = .failed

        let allowed = await recorder.authorizer(preferences: scoped.store).authorize(.unlock, vehicle: "Test Car")

        #expect(!allowed)
        #expect(recorder.reportedFailures == 1)
    }

    @Test("An unavailable owner check refuses the command and reports it")
    func unavailableOwnerCheckRefusesAndReports() async {
        let scoped = preferences("authorizer-owner-unavailable", biometrics: true)
        let recorder = Recorder()
        recorder.authentication = .unavailable(NSError(domain: "LAError", code: -6))

        let allowed = await recorder.authorizer(preferences: scoped.store).authorize(.lock, vehicle: "Test Car")

        #expect(!allowed)
        #expect(recorder.reportedFailures == 1)
    }

    @Test("Commands above routine risk never take the silent path")
    func elevatedRiskCommandsAreNotRoutine() {
        #expect(RemoteCommand.unlock.risk == .securitySensitive)
        #expect(RemoteCommand.honkHorn.risk == .securitySensitive)
        #expect(RemoteCommand.installOTANow.risk == .destructive)
        #expect(RemoteCommand.deleteChargeLocation(id: "x").risk == .destructive)
        #expect(RemoteCommand.unlock.risk.requiresDeviceOwnerAuthentication)
        #expect(!RemoteCommand.lock.risk.requiresDeviceOwnerAuthentication)
    }
}
