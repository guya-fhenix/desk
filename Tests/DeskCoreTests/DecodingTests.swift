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
          "reviews":{"nodes":[{"state":"COMMENTED","submittedAt":"2026-08-27T11:12:25Z","author":{"login":"claude"}},
            {"state":"PENDING","submittedAt":null,"author":{"login":"me"}}]},
          "pending":{"nodes":[{"id":"PRR_1","commit":{"oid":"abc"},"comments":{"totalCount":4,
            "nodes":[{"body":"**Nit**\\n\\nx\\n\\n<!-- fhenix-desk -->"},{"body":"mine"},{"body":"**Major**\\n\\ny <!-- fhenix-desk -->"},{"body":"also mine"}]}}]},
          "reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Team","name":"Protocol Team"}}]},
          "timelineItems":{"nodes":[{"createdAt":"2026-08-27T11:12:22Z","requestedReviewer":{"__typename":"Team","name":"Protocol Team"}},{}]},
          "reviewThreads":{"nodes":[{"isResolved":false},{"isResolved":true},{"isResolved":false}]}}]}}}
        """
        let pr = try #require(GitHubDecoding.pullRequests(from: Data(json.utf8)).prs.first)
        #expect(pr.repoName == "cofhe")
        #expect(pr.checks == .success)
        #expect(pr.checkCount == 9)
        #expect(pr.headSha == "abc")
        #expect(pr.mergeState == .blocked)
        #expect(pr.requestedReviewers == ["Protocol Team"])
        #expect(pr.reviewRequestEvents.count == 1)
        #expect(pr.reviewRequestEvents[0].isTeam)
        #expect(pr.humanReviews(botLogins: ["claude"]).isEmpty)
        #expect(pr.unresolvedThreads == 2)
        // Your own draft review: not a submitted review, but where the review's state is read from —
        // including which of its comments are Claude's, by the marker.
        #expect(pr.reviews.count == 1)
        #expect(pr.pendingReview == PendingReview(id: "PRR_1", commitId: "abc", comments: 4, claudeComments: 2))
    }

    @Test func missingReviewThreadsMeanNoneUnresolved() throws {
        let json = """
        {"data":{"search":{"nodes":[{"number":1,"title":"t","url":"u","isDraft":false,"createdAt":"2026-08-27T11:12:21Z","updatedAt":"2026-08-27T12:26:33Z",
          "mergedAt":null,"state":"OPEN","baseRefName":"main","headRefName":"h","additions":0,"deletions":0,"author":{"login":"me"},
          "repository":{"nameWithOwner":"o/r"},"reviewDecision":null,"mergeStateStatus":null,"commits":{"nodes":[]},"reviews":{"nodes":[]},
          "reviewRequests":{"nodes":[]},"timelineItems":{"nodes":[]}}]}}}
        """
        let pr = try #require(GitHubDecoding.pullRequests(from: Data(json.utf8)).prs.first)
        #expect(pr.unresolvedThreads == 0)
    }

    @Test func reviewDecisionFallsBackToReviewsAndRulesets() throws {
        func decision(_ reviews: String, rules: String = "") throws -> ReviewDecision {
            let json = """
            {"data":{"search":{"nodes":[{"number":1,"title":"t","url":"u","isDraft":false,"createdAt":"2026-08-27T11:12:21Z","updatedAt":"2026-08-27T12:26:33Z",
              "mergedAt":null,"state":"OPEN","baseRefName":"main","headRefName":"h","additions":0,"deletions":0,"author":{"login":"me"},
              "repository":{"nameWithOwner":"o/r"},"reviewDecision":null,"mergeStateStatus":null,"baseRef":{"rules":{"nodes":[\(rules)]}},"commits":{"nodes":[]},"reviews":{"nodes":[\(reviews)]},
              "reviewRequests":{"nodes":[]},"timelineItems":{"nodes":[]}}]}}}
            """
            return try #require(GitHubDecoding.pullRequests(from: Data(json.utf8)).prs.first).reviewDecision
        }
        func review(_ state: String, _ at: String, _ by: String) -> String {
            #"{"state":"\#(state)","submittedAt":"2026-08-27T\#(at):00:00Z","author":{"login":"\#(by)"}}"#
        }
        #expect(try decision("") == .none)
        #expect(try decision(review("COMMENTED", "10", "a")) == .none)
        // An approval stands through a later comment from the same reviewer.
        #expect(try decision([review("APPROVED", "10", "a"), review("COMMENTED", "11", "a")].joined(separator: ",")) == .approved)
        #expect(try decision([review("APPROVED", "10", "a"), review("CHANGES_REQUESTED", "11", "b")].joined(separator: ",")) == .changesRequested)
        #expect(try decision([review("CHANGES_REQUESTED", "10", "a"), review("APPROVED", "11", "a")].joined(separator: ",")) == .approved)
        #expect(try decision([review("APPROVED", "10", "a"), review("DISMISSED", "11", "a")].joined(separator: ",")) == .none)
        // A ruleset asking for a code owner's review, as cofhe's master does, with no approving count.
        let codeOwners = #"{"type":"PULL_REQUEST","parameters":{"requiredApprovingReviewCount":0,"requireCodeOwnerReview":true}},{"type":"DELETION","parameters":null}"#
        #expect(try decision("", rules: codeOwners) == .reviewRequired)
        #expect(try decision(review("APPROVED", "10", "a"), rules: codeOwners) == .approved)
        #expect(try decision("", rules: #"{"type":"PULL_REQUEST","parameters":{"requiredApprovingReviewCount":0,"requireCodeOwnerReview":false}}"#) == .none)
        // Two approvals asked for: one isn't enough.
        let two = #"{"type":"PULL_REQUEST","parameters":{"requiredApprovingReviewCount":2,"requireCodeOwnerReview":false}}"#
        #expect(try decision(review("APPROVED", "10", "a"), rules: two) == .reviewRequired)
        #expect(try decision([review("APPROVED", "10", "a"), review("APPROVED", "11", "b")].joined(separator: ","), rules: two) == .approved)
    }

    @Test func graphQLErrorsThrow() {
        let json = #"{"data":null,"errors":[{"message":"rate limited"}]}"#
        #expect(throws: GitHubError.self) { try GitHubDecoding.pullRequests(from: Data(json.utf8)) }
    }

    @Test func serverErrorsFromGhAreTransient() {
        #expect(GitHubError.isTransient(stderr: "gh: HTTP 502\n"))
        #expect(GitHubError.isTransient(stderr: "gh: HTTP 503 Service Unavailable"))
        #expect(!GitHubError.isTransient(stderr: "gh: HTTP 401: Bad credentials"))
        #expect(!GitHubError.isTransient(stderr: ""))
    }

    @Test func decodesAcliWorkItemSearch() throws {
        let json = """
        [{"id":"20322","key":"PRO-484","self":"https://jira-prod-eu-47-2.prod.atl-paas.net/rest/api/3/issue/20322",
          "fields":{"summary":"Create a status page","priority":{"name":"Highest"},
            "status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}}}}]
        """
        let tickets = try JiraDecoding.tickets(from: Data(json.utf8), site: "fhenix.atlassian.net", assignedToMe: true)
        let ticket = try #require(tickets.first)
        #expect(ticket.key == "PRO-484")
        #expect(ticket.category == .inProgress)
        #expect(ticket.priority == "Highest")
        // acli's `self` points at an internal host, so the browse URL is built from the signed-in site.
        #expect(ticket.url == "https://fhenix.atlassian.net/browse/PRO-484")
        #expect(ticket.assignedToMe)
    }

    @Test func decodesAcliProjectList() throws {
        let json = #"[{"key":"PRO","name":"Protocol"},{"key":"DOC","name":"Documentation"}]"#
        #expect(try JiraDecoding.projectKeys(from: Data(json.utf8)) == ["PRO", "DOC"])
    }

    @Test func readsTheSignedInSiteFromAuthStatus() {
        let text = """
        ✓ Authenticated
          Site: fhenix.atlassian.net
          Email: guya@fhenix.io
          Authentication Type: oauth
        """
        let account = try! #require(JiraDecoding.account(fromStatus: text))
        #expect(account.site == "fhenix.atlassian.net")
        #expect(account.email == "guya@fhenix.io")
        // Signed out: acli says so instead, and there is no account to report.
        #expect(JiraDecoding.account(fromStatus: "✗ Error: unauthorized: use 'acli jira auth login' to authenticate") == nil)
    }

    @Test func parsesDatesWithAndWithoutFractions() {
        #expect(JSON.parseISO8601("2026-08-27T11:12:21Z") != nil)
        #expect(JSON.parseISO8601("2026-08-23T11:54:57.327Z") != nil)
        #expect(JSON.parseISO8601("nope") == nil)
    }
}

@Suite struct RepositoryListTests {
    @Test func searchesScopeToTheTrackedReposRatherThanTheOrg() {
        let queries = GitHubQueries.searches(login: "me", repos: ["fhenixprotocol/cofhe", "fhenixprotocol/gitops"], since: Fixtures.t0)
        for query in [queries.mine, queries.reviews, queries.merged, queries.reviewed] {
            #expect(query.contains("repo:fhenixprotocol/cofhe"))
            #expect(query.contains("repo:fhenixprotocol/gitops"))
            #expect(!query.contains("org:"))
        }
        #expect(queries.mine.contains("author:me"))
        #expect(queries.reviews.contains("review-requested:me"))
    }

    @Test func repositoryPageDecodesAndCarriesItsCursor() throws {
        let json = """
        {"data":{"organization":{"repositories":{
          "pageInfo":{"hasNextPage":true,"endCursor":"Y3Vyc29y"},
          "nodes":[
            {"name":"cofhe","nameWithOwner":"FhenixProtocol/cofhe","isArchived":false,"pushedAt":"2026-09-01T10:00:00Z"},
            {"name":"old","nameWithOwner":"FhenixProtocol/old","isArchived":true,"pushedAt":null}
          ]}}}}
        """
        let page = try GitHubDecoding.repositories(from: Data(json.utf8))
        // The slug is lowercased because remotes and search qualifiers are compared in that form.
        #expect(page.repos.map(\.slug) == ["fhenixprotocol/cofhe", "fhenixprotocol/old"])
        #expect(page.repos[0].name == "cofhe")
        #expect(page.repos[1].isArchived)
        #expect(page.repos[1].pushedAt == nil)
        #expect(page.next == "Y3Vyc29y")
    }

    @Test func lastPageStopsThePaging() throws {
        let json = #"{"data":{"organization":{"repositories":{"pageInfo":{"hasNextPage":false,"endCursor":"z"},"nodes":[]}}}}"#
        #expect(try GitHubDecoding.repositories(from: Data(json.utf8)).next == nil)
    }

    @Test func searchPageCarriesItsCursorUntilTheLast() throws {
        func next(_ hasNextPage: Bool) throws -> String? {
            let json = #"{"data":{"search":{"pageInfo":{"hasNextPage":\#(hasNextPage),"endCursor":"Y3Vyc29y"},"nodes":[]}}}"#
            return try GitHubDecoding.pullRequests(from: Data(json.utf8)).next
        }
        #expect(try next(true) == "Y3Vyc29y")
        #expect(try next(false) == nil)
    }
}

@Suite struct MarkdownTests {
    @Test func splitsADescriptionIntoBlocks() {
        let text = """
        ## What
        Fixes the thing.
        Second line of the same paragraph.

        - first
        - second
          - nested
        1. step one
        2. step two

        ```swift
        let x = 1
        # not a heading
        ```
        > a note
        ---
        """
        let blocks = Markdown.blocks(text)
        #expect(blocks.contains(.heading(level: 2, text: "What")))
        // Consecutive lines join into one paragraph, the way markdown reads them.
        #expect(blocks.contains(.paragraph("Fixes the thing. Second line of the same paragraph.")))
        #expect(blocks.contains(.bullet(indent: 0, text: "first")))
        #expect(Markdown.blocks("- [x] done\n- [ ] todo") == [
            .task(indent: 0, done: true, text: "done"), .task(indent: 0, done: false, text: "todo"),
        ])
        #expect(blocks.contains(.bullet(indent: 1, text: "nested")))
        #expect(blocks.contains(.numbered(indent: 0, number: "2", text: "step two")))
        // A `#` inside a fence is code, not a heading.
        #expect(blocks.contains(.code(language: "swift", text: "let x = 1\n# not a heading")))
        #expect(blocks.contains(.quote("a note")))
        #expect(blocks.contains(.rule))
        #expect(!blocks.contains(.heading(level: 1, text: "not a heading")))
    }

    @Test func anUnclosedFenceStillKeepsItsText() {
        let blocks = Markdown.blocks("intro\n```\nstranded\n")
        #expect(blocks.contains(.code(language: nil, text: "stranded")))
    }

    /// Jira's hard breaks: the next line stays on its own line in the same block, and a numbered line
    /// after one is still a list.
    @Test func aHardBreakKeepsItsLine() {
        #expect(Markdown.blocks("One\\\nTwo  \nThree\nfour") == [.paragraph("One\nTwo\nThree four")])
        #expect(Markdown.blocks("- item\\\nmore of it\n- next") == [
            .bullet(indent: 0, text: "item\nmore of it"), .bullet(indent: 0, text: "next"),
        ])
        #expect(Markdown.blocks("Steps:\\\n1. build") == [.paragraph("Steps:"), .numbered(indent: 0, number: "1", text: "build")])
        // Two breaks in a row are a blank line, so what follows is a paragraph of its own.
        #expect(Markdown.blocks("1. last\\\n\\\nAfter:\\\nmore") == [
            .numbered(indent: 0, number: "1", text: "last"), .paragraph("After:\nmore"),
        ])
    }

    @Test func aPipeTableKeepsItsHeaderAndCells() {
        #expect(Markdown.blocks("| Policy | Condition |\n| --- | :---: |\n| a \\| b | `x` |\nafter") == [
            .table(header: ["Policy", "Condition"], rows: [["a | b", "`x`"]]),
            .paragraph("after"),
        ])
        #expect(Markdown.blocks("| a | b |") == [.table(header: nil, rows: [["a", "b"]])])
    }

    @Test func emptyAndPlainTextSurvive() {
        #expect(Markdown.blocks("").isEmpty)
        #expect(Markdown.blocks("just words") == [.paragraph("just words")])
        // Half-written markup must not throw the text away.
        #expect(String(Markdown.inline("**unclosed").characters).contains("unclosed"))
    }
}
