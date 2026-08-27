import DeskCore
import Foundation
import Testing

@Suite struct DecodingTests {
    @Test func decodesGitHubSearch() throws {
        let json = """
        {"data":{"search":{"nodes":[{"number":928,"title":"[FEAT] gauge","url":"https://github.com/FhenixProtocol/cofhe/pull/928","isDraft":false,
          "createdAt":"2026-08-27T11:12:21Z","updatedAt":"2026-08-27T12:26:33Z","mergedAt":null,"state":"OPEN",
          "baseRefName":"feat/base","headRefName":"feat/head","additions":208,"deletions":16,"author":{"login":"me"},
          "repository":{"nameWithOwner":"FhenixProtocol/cofhe"},"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"BLOCKED",
          "commits":{"nodes":[{"commit":{"oid":"abc","statusCheckRollup":{"state":"SUCCESS","contexts":{"totalCount":9}}}}]},
          "reviews":{"nodes":[{"state":"COMMENTED","submittedAt":"2026-08-27T11:12:25Z","author":{"login":"claude"}}]},
          "reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Team","name":"Protocol Team"}}]},
          "timelineItems":{"nodes":[{"createdAt":"2026-08-27T11:12:22Z","requestedReviewer":{"__typename":"Team","name":"Protocol Team"}},{}]}}]}}}
        """
        let pr = try #require(GitHubDecoding.pullRequests(from: Data(json.utf8)).first)
        #expect(pr.repoName == "cofhe")
        #expect(pr.checks == .success)
        #expect(pr.checkCount == 9)
        #expect(pr.headSha == "abc")
        #expect(pr.mergeState == .blocked)
        #expect(pr.requestedReviewers == ["Protocol Team"])
        #expect(pr.reviewRequestEvents.count == 1)
        #expect(pr.reviewRequestEvents[0].isTeam)
        #expect(pr.humanReviews(botLogins: ["claude"]).isEmpty)
    }

    @Test func graphQLErrorsThrow() {
        let json = #"{"data":null,"errors":[{"message":"rate limited"}]}"#
        #expect(throws: GitHubError.self) { try GitHubDecoding.pullRequests(from: Data(json.utf8)) }
    }

    @Test func decodesJiraSearch() throws {
        let json = """
        {"issues":[{"key":"PRO-484","fields":{"summary":"Create a status page","updated":"2026-08-24T10:45:16.473+0300",
          "priority":{"name":"Highest"},"status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}}}}],"isLast":true}
        """
        let tickets = try JiraDecoding.tickets(fromSearchResponse: Data(json.utf8), site: "fhenix.atlassian.net", assignedToMe: true)
        let ticket = try #require(tickets.first)
        #expect(ticket.key == "PRO-484")
        #expect(ticket.category == .inProgress)
        #expect(ticket.priority == "Highest")
        #expect(ticket.url == "https://fhenix.atlassian.net/browse/PRO-484")
        #expect(ticket.updatedAt == JSON.parseISO8601("2026-08-24T07:45:16.473Z"))
    }

    @Test func parsesDatesWithAndWithoutFractions() {
        #expect(JSON.parseISO8601("2026-08-27T11:12:21Z") != nil)
        #expect(JSON.parseISO8601("2026-08-23T11:54:57.327Z") != nil)
        #expect(JSON.parseISO8601("nope") == nil)
    }
}
