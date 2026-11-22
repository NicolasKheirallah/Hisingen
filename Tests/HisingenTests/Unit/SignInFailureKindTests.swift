import Foundation
import Testing
@testable import Hisingen

struct SignInFailureKindTests {
    @Test
    func invalidCredentialsMapToTheCredentialsKind() {
        let error = VehicleServiceError.authenticationRequired(provider: .polestar, reason: .invalidCredentials)
        #expect(SignInFailureKind.classify(error, provider: .polestar) == .invalidCredentials)
    }

    @Test
    func callbackRejectionMapsToTheInteractiveChallengeKind() {
        let error = VehicleServiceError.authenticationRequired(provider: .polestar, reason: .callbackRejected)
        #expect(SignInFailureKind.classify(error, provider: .polestar) == .interactiveChallenge)
    }

    @Test
    func expiredSessionMapsToTheSessionExpiredKind() {
        let error = VehicleServiceError.authenticationRequired(provider: .polestar, reason: .expiredSession)
        #expect(SignInFailureKind.classify(error, provider: .polestar) == .sessionExpired)
    }

    @Test
    func aChangedSignInPageMapsToTheSigningFlowChangedKind() {
        let error = VehicleServiceError.incompatibleAPI(provider: .polestar, operation: "Polestar sign-in form")
        #expect(SignInFailureKind.classify(error, provider: .polestar) == .signingFlowChanged)
    }

    @Test
    func offlineMapsToTheTransientKind() {
        #expect(SignInFailureKind.classify(URLError(.notConnectedToInternet), provider: .polestar) == .transient)
    }

    @Test
    func polestarPermissionDeniedMapsToTheInteractiveChallengeKind() {
        let error = VehicleServiceError.permissionDenied(provider: .polestar, operation: "VIN telemetry: /v1/vehicles")
        #expect(SignInFailureKind.classify(error, provider: .polestar) == .interactiveChallenge)
    }

    @Test
    func onlyChallengeExpiryAndFlowChangeAreRecoverableThroughInteractiveSignIn() {
        #expect(SignInFailureKind.interactiveChallenge.interactiveSignInHelps)
        #expect(SignInFailureKind.sessionExpired.interactiveSignInHelps)
        #expect(SignInFailureKind.signingFlowChanged.interactiveSignInHelps)
        #expect(!SignInFailureKind.invalidCredentials.interactiveSignInHelps)
        #expect(!SignInFailureKind.transient.interactiveSignInHelps)
        #expect(!SignInFailureKind.unspecified.interactiveSignInHelps)
    }

    /// Volvo retired the original `dc-` applications and answered their grants with
    /// `invalid_client`. Classifying that as bad owner credentials sent the owner to retype the
    /// same dead values; signing in again with new credentials is the way back.
    @Test
    func aRetiredApplicationIsNotTheOwnersTypingMistake() {
        let error = VolvoError.appCredentialsRejected.asVehicleServiceError
        #expect(error.requiresAuthentication)
        #expect(!error.allowsAutomaticRetry)
        #expect(!error.isRejectedCredential)
        #expect(SignInFailureKind.classify(error, provider: .volvo) == .sessionExpired)
        #expect(SignInFailureKind.classify(error, provider: .volvo).interactiveSignInHelps)
        // The message has to point at the credentials, not at an empty Settings form.
        #expect(error.errorDescription?.contains("client ID") == true)
    }
}
