import Testing
@testable import Hisingen

@Suite("Panel pull gesture")
@MainActor
struct GestureAuditFixTests {
    @Test func reversingPastStartDisarmsPull() {
        let gesture = PanelGestureState()
        gesture.pullDistance = 60
        gesture.pullArmed = true
        #expect(!gesture.acceptsPull(translation: -1))
        #expect(gesture.pullDistance == 0)
        #expect(!gesture.pullArmed)
    }

    @Test func leavingScrollTopDisarmsPull() {
        let gesture = PanelGestureState()
        gesture.pullDistance = 60
        gesture.pullArmed = true
        gesture.scrollOffsetFromTop = 2
        #expect(!gesture.acceptsPull(translation: 100))
        #expect(gesture.pullDistance == 0)
        #expect(!gesture.pullArmed)
    }

    @Test func releaseUsesFinalPositionRatherThanCachedPull() {
        let gesture = PanelGestureState()
        gesture.pullDistance = 100
        #expect(gesture.pullDistanceAtRelease(translation: -1) == 0)
        #expect(gesture.pullDistanceAtRelease(translation: 1) < 1)
        #expect(gesture.pullDistanceAtRelease(translation: 200) > 56)
        gesture.scrollOffsetFromTop = 1
        #expect(gesture.pullDistanceAtRelease(translation: 200) == 0)
    }

}
