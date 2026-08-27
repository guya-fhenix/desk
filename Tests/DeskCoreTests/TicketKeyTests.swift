import DeskCore
import Testing

@Suite struct TicketKeyTests {
    let matcher = TicketKeyMatcher(projectKeys: ["PRO", "READY"])

    @Test func findsLowercaseKeyInBranch() {
        #expect(matcher.keys(in: "feat/pro-393-394-verify-measurement") == ["PRO-393"])
    }

    @Test func findsMultipleDistinctKeys() {
        #expect(matcher.keys(in: "PRO-491 fheos alerts and ready-204 follow-up pro-491") == ["PRO-491", "READY-204"])
    }

    @Test func ignoresUnknownProjects() {
        #expect(matcher.keys(in: "ABC-12 and AVX-512 and pro_12").isEmpty)
    }

    @Test func mergesAcrossTexts() {
        #expect(matcher.keys(in: ["pro-1", "PRO-1 again", "pro-2"]) == ["PRO-1", "PRO-2"])
    }
}
