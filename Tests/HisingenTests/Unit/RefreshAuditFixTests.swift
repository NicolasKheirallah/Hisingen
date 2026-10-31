import Foundation
import Testing
@testable import Hisingen

struct RefreshAuditFixTests {
    @Test
    func recoveryIntentsRespectProviderStandDown() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let deadline = now.addingTimeInterval(300)
        let situation = RefreshGate.Situation(isAsleep: false, isOnline: true, hasSession: true,
            isWorking: false, rateLimitedUntil: deadline, selectedVIN: "VIN", now: now)
        #expect(RefreshGate.admit(.wake, in: situation) == .refused(.rateLimited(until: deadline)))
        #expect(RefreshGate.admit(.networkRestored, in: situation) == .refused(.rateLimited(until: deadline)))
    }
}
