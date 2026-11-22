import Foundation
import Testing
@testable import Hisingen

/// Shortcut timer fields are free text, so the parse decides whether the car gets the window the
/// person meant. A refusal is acceptable; a silently shifted hour is not.
struct IntentTimeParsingTests {
    @Test
    func validClockTimesParse() throws {
        let morning = try intentClockTime("07:30", name: "start time")
        #expect(morning.hour == 7)
        #expect(morning.minute == 30)
        let midnight = try intentClockTime("00:00", name: "start time")
        #expect(midnight.hour == 0 && midnight.minute == 0)
        let late = try intentClockTime("23:59", name: "stop time")
        #expect(late.hour == 23 && late.minute == 59)
    }

    @Test
    func impossibleTimesAreRefused() {
        for text in ["24:00", "07:60", "7", "07:30:00", "0730", "", "ab:cd", "-1:00"] {
            #expect(throws: IntentError.self) {
                _ = try intentClockTime(text, name: "start time")
            }
        }
    }
}
