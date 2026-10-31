import Foundation

enum PolestarReadFailurePolicy {
    static func abortRefresh(_ error: any Error) -> Bool {
        if error is CancellationError || error is URLError { return true }
        switch error as? PolestarError {
        case .authenticationRequired, .rateLimited, .network, .server, .responseTooLarge:
            return true
        default: return false
        }
    }
}
