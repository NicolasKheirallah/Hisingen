import Foundation

/// What a command result's banner can offer after it lands. The command and the VIN it was
/// approved for travel together, so the banner never acts on a vehicle the reader has since
/// switched away from.
struct RemoteCommandFollowUp: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The send failed and the failure says the command did not run.
        case retry
        /// The send succeeded and this sends its reversal.
        case undo
    }

    let kind: Kind
    let command: RemoteCommand
    let targetVIN: String

    /// Whether a failed send may be sent again. Only a `RemoteCommandError` qualifies: those are
    /// refusals made before the request left the app, or the provider's answer that the command
    /// did not run. Any other error (a dropped connection, a timeout, a cancelled request) can
    /// arrive after the vehicle already acted, and sending again could repeat a physical action
    /// such as unlocking the car or honking the horn.
    static func permitsRetry(after error: any Error) -> Bool {
        error is RemoteCommandError
    }
}
