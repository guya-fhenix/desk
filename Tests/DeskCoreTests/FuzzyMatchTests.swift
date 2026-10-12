import DeskCore
import Testing

@Suite struct FuzzyMatchTests {
    @Test func ranksCloserMatchesHigher() {
        let title = "Pointer-based ACPShareRegistry: ACP and metadata"
        let prefix = FuzzyMatch.score(title, "pointer")
        let wordStart = FuzzyMatch.score(title, "acp")
        let inside = FuzzyMatch.score(title, "share")
        let scattered = FuzzyMatch.score(title, "metadata pointer")
        let letters = FuzzyMatch.score(title, "pbsr")
        #expect(prefix! > wordStart!)
        #expect(wordStart! > inside!)
        #expect(inside! > scattered!)
        #expect(scattered! > letters!)
    }

    @Test func missesWhatIsNotThere() {
        #expect(FuzzyMatch.score("Settings", "zzq") == nil)
        #expect(FuzzyMatch.score("Settings", "") == nil)
        // Two letters in order are in nearly every title, so they are not a match on their own.
        #expect(FuzzyMatch.score("Up Next", "ut") == nil)
    }
}
