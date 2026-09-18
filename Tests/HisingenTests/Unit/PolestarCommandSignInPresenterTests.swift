import Foundation
import Testing
@testable import Hisingen

/// Pins `PolestarCommandSignInPresenter.sessionEndOutcome` — the total function whose
/// exhaustive switch at the completion site guarantees every callback-less session end
/// resumes the awaiting `signIn` continuation. The force-login generic-failure case is
/// the regression that motivated the extraction: that branch once recorded a trace and
/// returned, leaving the continuation resumed-never and the coordinator's re-entrancy
/// guard wedged until relaunch.
struct PolestarCommandSignInPresenterTests {
    @Test
    func userCancellationWinsOverEveryOtherInput() {
        for forceLogin in [false, true] {
            for hasAuthorizeURL in [false, true] {
                guard case .userCancellation = PolestarCommandSignInPresenter.sessionEndOutcome(
                    isUserCancellation: true,
                    isPresentationFailure: false,
                    hasAuthorizeURL: hasAuthorizeURL,
                    forceLogin: forceLogin)
                else {
                    Issue.record("A deliberate dismissal must resolve as userCancellation")
                    return
                }
            }
        }
    }

    @Test
    func presentationFailureFallsBackToTheBrowserOnlyForNormalRuns() {
        guard case .presentationFallback = PolestarCommandSignInPresenter.sessionEndOutcome(
            isUserCancellation: false,
            isPresentationFailure: true,
            hasAuthorizeURL: true,
            forceLogin: false)
        else {
            Issue.record("A normal run with a flow URL must fall back to the browser")
            return
        }
        // The default browser would auto-consent with the stored account — exactly what a
        // force-login run exists to avoid — so it must fail instead of falling back.
        guard case .failure = PolestarCommandSignInPresenter.sessionEndOutcome(
            isUserCancellation: false,
            isPresentationFailure: true,
            hasAuthorizeURL: true,
            forceLogin: true)
        else {
            Issue.record("A force-login run must not hand over to the default browser")
            return
        }
    }

    @Test
    func presentationFailureWithoutAFlowURLCannotFallBack() {
        guard case .failure = PolestarCommandSignInPresenter.sessionEndOutcome(
            isUserCancellation: false,
            isPresentationFailure: true,
            hasAuthorizeURL: false,
            forceLogin: false)
        else {
            Issue.record("No flow URL means no browser fallback is possible")
            return
        }
    }

    @Test
    func genericSessionEndedErrorAlwaysFailsLoudly() {
        // Regression: under force-login this once returned without resuming the continuation.
        for forceLogin in [false, true] {
            guard case .failure = PolestarCommandSignInPresenter.sessionEndOutcome(
                isUserCancellation: false,
                isPresentationFailure: false,
                hasAuthorizeURL: true,
                forceLogin: forceLogin)
            else {
                Issue.record("A generic session-ended error must resume the continuation with a failure")
                return
            }
        }
    }

    @Test
    func everyFailureCarriesTheDiagnosticTraceItsPathOwes() {
        // The trace legend is what makes a self-dismissing sheet diagnosable from the
        // API log; a nil trace here would silently reopen the old invisible paths.
        guard case .failure(_, let forceLoginPresentationTrace) = PolestarCommandSignInPresenter.sessionEndOutcome(
            isUserCancellation: false,
            isPresentationFailure: true,
            hasAuthorizeURL: true,
            forceLogin: true)
        else {
            Issue.record("expected failure")
            return
        }
        #expect(forceLoginPresentationTrace == "force-login requested but presentation failed; browser fallback suppressed")

        guard case .failure(_, let forceLoginEndedTrace) = PolestarCommandSignInPresenter.sessionEndOutcome(
            isUserCancellation: false,
            isPresentationFailure: false,
            hasAuthorizeURL: true,
            forceLogin: true)
        else {
            Issue.record("expected failure")
            return
        }
        #expect(forceLoginEndedTrace == "session-ended-force-login")

        // The plain run's generic failure keeps the pre-existing silent-cancel shape: the
        // session-failure row (recorded at the call site) is its evidence, as before.
        guard case .failure(_, let genericTrace) = PolestarCommandSignInPresenter.sessionEndOutcome(
            isUserCancellation: false,
            isPresentationFailure: false,
            hasAuthorizeURL: true,
            forceLogin: false)
        else {
            Issue.record("expected failure")
            return
        }
        #expect(genericTrace == nil)
    }
}
