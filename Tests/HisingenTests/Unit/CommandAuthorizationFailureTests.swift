import Foundation
import Testing
@testable import Hisingen

/// The report was "Settings → Features → Remote Controls → Authorize, doesn't do anything". The
/// flow was running: it opened a browser, took the callback, and failed afterwards, reporting only
/// through a system notification. These pin the two halves of the fix: the copy each failure maps
/// to, and that the flow answers in the window instead of staying silent.
@Suite(.serialized)
@MainActor
struct CommandAuthorizationFailureTests {

    @Test
    func anExpiredSessionIsReportedAsASignInRequest() {
        let failure = CommandAuthorizationFailure.make(
            for: PolestarError.authenticationRequired(.expiredSession)
        )
        #expect(failure.title == L10n.text("Sign in to Polestar first"))
        #expect(failure.message == L10n.text("Your Polestar session expired. Sign in again. The interactive window handles any new verification step Polestar added."))
        // The alert offers the sign-in itself: telling the reader to go find the control was the
        // half of the problem that survives a visible message.
        #expect(failure.offersSignIn)
    }

    @Test
    func aTransportFailureIsReportedAsRetryable() {
        let failure = CommandAuthorizationFailure.make(for: URLError(.notConnectedToInternet))
        #expect(failure.title == L10n.text("Authorization failed"))
        #expect(failure.message == L10n.text("Couldn't confirm remote-command authorization with Polestar. Check your connection and try again."))
        #expect(!failure.offersSignIn)
    }

    @Test
    func aChangedSignInStepPointsAtTheInteractiveWindow() {
        let failure = CommandAuthorizationFailure.make(
            for: PolestarError.authenticationRequired(.callbackRejected)
        )
        #expect(failure.message == L10n.text("Polestar requested an additional or changed sign-in step. Sign in again via the interactive window, then retry Authorize."))
    }

    /// Without an account session the browser trip cannot be verified, so the flow must say so in
    /// the window and never reach the browser.
    @Test
    func authorizingWithoutAnAccountAsksForSignInInTheWindow() async throws {
        let suite = "CommandAuthorizationFailureTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.command-auth.\(UUID())")
        preferences.activeBrand = .polestar
        preferences.polestarConnectionMode = .polestarID
        let context = RecordingSignInContext()
        let alerts = RecordingCommandAuthorizationAlerts()
        let coordinator = SignInCoordinator(
            context: context,
            preferences: preferences,
            polestarAPI: PolestarAPI(keychain: keychain, preferences: preferences),
            volvoAPI: VolvoAPI(keychain: keychain, preferences: preferences),
            commandAuthorizationAlerts: alerts
        )

        coordinator.beginPolestarCommandAuthorization()
        // With provider credentials on file the flow runs on a task and answers from its catch
        // block, so the assertion has to wait for that turn instead of racing it.
        // Wait on elapsed time, not scheduler turns: a fixed number of yields runs out when the
        // whole suite loads the main actor.
        for _ in 0..<500 where alerts.failures.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(alerts.failures.count == 1, "The click produced no visible answer")
        #expect(alerts.failures.first?.title == L10n.text("Sign in to Polestar first"))
        #expect(context.notices.isEmpty)
    }
}

@MainActor
private final class RecordingCommandAuthorizationAlerts: CommandAuthorizationAlertPresenting {
    private(set) var failures: [CommandAuthorizationFailure] = []
    func present(_ failure: CommandAuthorizationFailure) -> Bool {
        failures.append(failure)
        return false
    }
}

@MainActor
private final class RecordingSignInContext: SignInCoordinatorContext {
    private(set) var adoptedBrands: [VehicleBrand] = []
    private(set) var notices: [String] = []
    private(set) var settingsRefreshes = 0

    func activateBrandAfterSignIn(_ brand: VehicleBrand) { adoptedBrands.append(brand) }
    func dismissSettingsAfterSignIn() {}
    func refreshSettingsSurface() { settingsRefreshes += 1 }
    func presentSignInNotice(title: String, body: String, subtitle: String?) { notices.append(title) }
}
