import DeskCore
import Testing

@Suite struct TimeTextTests {
    /// Whole numbers in the coarsest unit that still says something: nobody should read "161.4d".
    @Test func ageIsWholeAndCoarse() {
        #expect(TimeText.duration(nil) == "–")
        #expect(TimeText.duration(-5) == "0m")
        #expect(TimeText.duration(45 * 60) == "45m")
        #expect(TimeText.duration(3.6 * 3_600) == "3h")
        #expect(TimeText.duration(47 * 3_600) == "47h")
        #expect(TimeText.duration(2.5 * 86_400) == "2d")
        #expect(TimeText.duration(21 * 86_400) == "3w")
        #expect(TimeText.duration(161.4 * 86_400) == "5mo")
    }
}
