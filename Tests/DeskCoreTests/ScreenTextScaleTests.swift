import DeskCore
import Testing

struct ScreenTextScaleTests {
    /// Laptops keep the boards' sizes; a wider screen gets larger text, in 0.05 steps, up to 1.3.
    @Test func scaleFollowsTheScreensWidth() {
        #expect(ScreenTextScale.scale(forWidth: 1440) == 1)
        #expect(ScreenTextScale.scale(forWidth: 1512) == 1)
        #expect(ScreenTextScale.scale(forWidth: 1728) == 1)
        #expect(ScreenTextScale.scale(forWidth: 1920) == 1.05)
        #expect(ScreenTextScale.scale(forWidth: 2240) == 1.1)
        #expect(ScreenTextScale.scale(forWidth: 2560) == 1.2)
        #expect(ScreenTextScale.scale(forWidth: 3008) == 1.3)
        #expect(ScreenTextScale.scale(forWidth: 6016) == 1.3)
    }
}
