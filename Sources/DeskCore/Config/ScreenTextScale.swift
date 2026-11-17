import Foundation

/// How large the app's text is on a screen this many points wide: a laptop's (to 1728 pt) at the boards' sizes, a wider
/// screen larger, as it has the room: 1920 pt at 1.05, 2560 pt (a 27-inch display) at 1.2, and no more than 1.3. In steps
/// of 0.05, so a screen a few points wider than another doesn't change the text.
public enum ScreenTextScale {
    public static func scale(forWidth points: Double) -> Double {
        let raw = 1 + (points - 1728) / (2560 - 1728) * 0.2
        return min(max((raw * 20).rounded() / 20, 1), 1.3)
    }
}
