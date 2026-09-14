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
    func onlyChallengeExpiryAndFlowChangeAreRecoverableThroughInteractiveSignIn() {
        #expect(SignInFailureKind.interactiveChallenge.interactiveSignInHelps)
        #expect(SignInFailureKind.sessionExpired.interactiveSignInHelps)
        #expect(SignInFailureKind.signingFlowChanged.interactiveSignInHelps)
        #expect(!SignInFailureKind.invalidCredentials.interactiveSignInHelps)
        #expect(!SignInFailureKind.transient.interactiveSignInHelps)
        #expect(!SignInFailureKind.unspecified.interactiveSignInHelps)
    }
}
