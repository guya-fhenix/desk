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
          "reviews":{"nodes":[{"state":"COMMENTED","submittedAt":"2026-08-27T11:12:25Z","author":{"__typename":"Bot","login":"coderabbitai"}},
            {"state":"PENDING","submittedAt":null,"author":{"login":"me"}}]},
          "pending":{"nodes":[{"id":"PRR_1","commit":{"oid":"abc"},"comments":{"totalCount":4}}]},
          "reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Team","name":"Protocol Team"}}]},
          "timelineItems":{"nodes":[{"createdAt":"2026-08-27T11:12:22Z","requestedReviewer":{"__typename":"Team","name":"Protocol Team"}},{}]},
          "reviewThreads":{"totalCount":4,"nodes":[{"id":"PRRT_1","isResolved":false},{"id":"PRRT_2","isResolved":true},{"isResolved":false}]}}]}}}
        """
        let pr = try #require(GitHubDecoding.pullRequests(from: Data(json.utf8)).prs.first)
        #expect(pr.repoName == "cofhe")
        #expect(pr.checks == .success)
        #expect(pr.checkCount == 9)
        #expect(pr.headSha == "abc")
        // Not asked for, as in an older answer: from origin, default branch unknown.
        #expect(!pr.isCrossRepository)
        #expect(pr.defaultBranch == "")
        #expect(pr.mergeState == .blocked)
        #expect(pr.requestedReviewers == ["Protocol Team"])
        #expect(pr.reviewRequestEvents.count == 1)
        #expect(pr.reviewRequestEvents[0].isTeam)
        // Two open of the three read, and the one past them that could not be read counts as open too.
        #expect(pr.unresolvedThreads == 3)
        // Counted only: the other searches do not ask for a thread's place or comment.
        #expect(pr.threads.isEmpty)
        // GraphQL drops a bot's `[bot]`; it is put back, so the bot checks see it.
        #expect(pr.reviews.first?.author == "coderabbitai[bot]")
        #expect(pr.author == "me")
        // Your own draft review: not a submitted review, but where the review's state is read from.
        #expect(pr.reviews.count == 1)
        #expect(pr.pendingReview == PendingReview(id: "PRR_1", commitId: "abc", comments: 4))
    }

    /// Your own PR's search: its open threads in full, the author's /pre-pr evidence comment, and the review gate's words.
    @Test func decodesThreadsEvidenceAndTheApprovalsStatus() throws {
        let json = """
        {"data":{"search":{"nodes":[{"number":7,"title":"t","url":"https://github.com/o/r/pull/7","isDraft":true,"createdAt":"2026-08-27T11:12:21Z",
          "updatedAt":"2026-08-27T12:26:33Z","mergedAt":null,"state":"OPEN","baseRefName":"main","headRefName":"h","isCrossRepository":true,"additions":0,"deletions":0,
          "author":{"login":"me"},"repository":{"nameWithOwner":"o/r","defaultBranchRef":{"name":"develop"}},"reviewDecision":null,"mergeStateStatus":null,
          "commits":{"nodes":[{"commit":{"oid":"abc","statusCheckRollup":null,
            "status":{"context":{"description":"medium risk: 0 of 1 approvals on the latest commit"}}}}]},
          "reviews":{"nodes":[]},"reviewRequests":{"nodes":[]},"timelineItems":{"nodes":[]},
          "reviewThreads":{"nodes":[
            {"id":"PRRT_1","isResolved":false,"isOutdated":true,"path":"src/a.rs","line":null,"originalLine":12,
             "comments":{"totalCount":3,"nodes":[{"author":{"__typename":"Bot","login":"coderabbitai"},"body":"**Minor** · x","url":"https://github.com/o/r/pull/7#discussion_r1"}]}},
            {"id":"PRRT_2","isResolved":true,"isOutdated":false,"path":"src/b.rs","line":4,"originalLine":4,
             "comments":{"totalCount":1,"nodes":[{"author":{"login":"me"},"body":"done","url":"u2"}]}}]},
          "comments":{"nodes":[
            {"author":{"login":"alice"},"body":"<!-- pre-pr:start -->\\n## Testing\\nnot mine"},
            {"author":{"login":"me"},"body":"<!-- pre-pr:start -->\\n## Testing\\n- ok"},
            {"author":{"login":"me"},"body":"thanks"}]}}]}}}
        """
        let pr = try #require(GitHubDecoding.pullRequests(from: Data(json.utf8)).prs.first)
        #expect(pr.isCrossRepository)
        #expect(pr.defaultBranch == "develop")
        #expect(pr.unresolvedThreads == 1)
        #expect(pr.threads == [ReviewThread(
            id: "PRRT_1", path: "src/a.rs", line: 12, isOutdated: true, url: "https://github.com/o/r/pull/7#discussion_r1",
            author: "coderabbitai[bot]", body: "**Minor** · x", comments: 3
        )])
        #expect(pr.threads.first?.source == .codeRabbit)
        #expect(pr.evidence == "<!-- pre-pr:start -->\n## Testing\n- ok")
        #expect(pr.approvalStatus == "medium risk: 0 of 1 approvals on the latest commit")
        #expect(pr.approvalGate?.state == .counted(have: 0, needed: 1))
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
        // No gate status: a repo without the review flow.
        #expect(pr.threads.isEmpty && pr.evidence == nil && pr.approvalStatus == nil)
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
        // A state GitHub adds later neither fails the search nor counts.
        #expect(try decision([review("APPROVED", "10", "a"), review("SOMETHING_NEW", "11", "a")].joined(separator: ",")) == .approved)
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

    /// gh failing as the real one does: a body on stdout, its reason on stderr, exit 1. Each call gets the next answer.
    @Test func failedGhCallsRetryOrThrowGhsReasonUnlessGraphQLAnswered() async throws {
        func login(_ answers: ShellResult...) async -> (login: Result<String, any Error>, calls: Int) {
            let calls = Calls()
            let gh = GitHubProvider(ghPath: "/gh", org: "o") { _, arguments, _, _, _, _ in
                answers[min(await calls.add(arguments.joined(separator: " ")), answers.count) - 1]
            }
            let login: Result<String, any Error>
            do { login = .success(try await gh.viewerLogin()) } catch { login = .failure(error) }
            return (login, await calls.list.count)
        }
        let expired = await login(.failed("gh: Bad credentials (HTTP 401)", stdout: #"{"message":"Bad credentials"}"#))
        #expect(throws: ShellError.self) { try expired.login.get() }
        #expect("\(expired.login)".contains("Bad credentials (HTTP 401)"))
        #expect(expired.calls == 1)
        let answered = await login(.failed("gh: no field x", stdout: #"{"errors":[{"message":"no field x"}]}"#))
        #expect(throws: GitHubError.self) { try answered.login.get() }
        #expect("\(answered.login)".contains("GitHub: no field x") && answered.calls == 1)
        let flaky = await login(
            .failed("gh: Server Error (HTTP 502)", stdout: #"{"message":"Server Error"}"#), .ok(#"{"data":{"viewer":{"login":"me"}}}"#)
        )
        #expect(try flaky.login.get() == "me")
        #expect(flaky.calls == 2)
    }

    /// Your own PRs' search decides the snapshot; another search that fails keeps its last list, and the snapshot says why.
    @Test func aFailedSearchKeepsItsLastListAndYoursAlone() async throws {
        @Sendable func search(_ number: Int) -> ShellResult {
            .ok(#"""
            {"data":{"search":{"nodes":[{"number":\#(number),"title":"t","url":"https://github.com/o/r/pull/\#(number)","isDraft":false,
              "createdAt":"2026-08-27T11:12:21Z","updatedAt":"2026-08-27T12:26:33Z","mergedAt":null,"state":"OPEN","baseRefName":"main",
              "headRefName":"h","additions":0,"deletions":0,"author":{"login":"me"},"repository":{"nameWithOwner":"o/r"},"reviewDecision":null,
              "mergeStateStatus":null,"commits":{"nodes":[]},"reviews":{"nodes":[]},"reviewRequests":{"nodes":[]},"timelineItems":{"nodes":[]}}]}}}
            """#)
        }
        let calls = Calls()
        let gh = GitHubProvider(ghPath: "/gh", org: "o") { _, _, _, stdin, _, _ in
            let body = String(decoding: stdin ?? Data(), as: UTF8.self)
            if body.contains("viewer { login }") { return .ok(#"{"data":{"viewer":{"login":"me"}}}"#) }
            if body.contains("is:open author:me") {
                let round = await calls.add("mine")
                return round < 3 ? search(round) : .failed("gh: Bad credentials (HTTP 401)")
            }
            if body.contains("review-requested:me") {
                return await calls.add("reviews") == 1 ? search(7) : .failed("gh: Bad credentials (HTTP 401)")
            }
            return .ok(#"{"data":{"search":{"nodes":[]}}}"#)
        }
        let first = try await gh.snapshot(repos: ["o/r"], since: Fixtures.t0)
        #expect(first.mine.map(\.number) == [1] && first.reviewRequests.map(\.number) == [7] && first.error == nil)
        let second = try await gh.snapshot(repos: ["o/r"], since: Fixtures.t0)
        #expect(second.mine.map(\.number) == [2])
        #expect(second.reviewRequests.map(\.number) == [7])
        #expect(second.error?.contains("Bad credentials (HTTP 401)") == true)
        await #expect(throws: ShellError.self) { try await gh.snapshot(repos: ["o/r"], since: Fixtures.t0) }
    }

    @Test func decodesAcliWorkItemSearch() throws {
        let json = """
        [{"id":"20322","key":"PRO-484","self":"https://jira-prod-eu-47-2.prod.atl-paas.net/rest/api/3/issue/20322",
          "fields":{"summary":"Create a status page","priority":{"name":"Highest"},"assignee":{"displayName":"Roee Zolantz","avatarUrls":{"48x48":"https://a/48"}},
            "reporter":{"accountId":"712020:abc","displayName":"Guy Aluk"},
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
        #expect(ticket.assignee == "Roee Zolantz")
        #expect(ticket.assigneeAvatar == "https://a/48")
        #expect(ticket.reporter == "Guy Aluk")
    }

    /// A PR's checks: Actions jobs by workflow with the failed step and its errors, another app's check, a status.
    @Test func decodesPullRequestChecks() throws {
        let json = #"""
        {"data":{"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
          {"__typename":"CheckRun","name":"check-changelog","status":"COMPLETED","conclusion":"FAILURE",
           "detailsUrl":"https://github.com/o/r/actions/runs/1/job/11","startedAt":"2026-10-08T13:00:36Z","completedAt":"2026-10-08T13:05:36Z",
           "checkSuite":{"workflowRun":{"workflow":{"name":"Changelog Check"}}},
           "steps":{"nodes":[{"name":"Set up job","conclusion":"SUCCESS"},{"name":"Wait for approval","conclusion":"FAILURE"}]},
           "annotations":{"nodes":[{"message":"Node 20 is deprecated","annotationLevel":"WARNING"},
                                   {"message":"CHANGELOG.md was not updated","annotationLevel":"FAILURE"}]}},
          {"__typename":"CheckRun","name":"fhe-engine-fmt","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://github.com/o/r/actions/runs/2/job/21",
           "startedAt":"2026-10-08T13:01:00Z","completedAt":"2026-10-08T13:02:00Z","checkSuite":{"workflowRun":{"workflow":{"name":"Unit Tests"}}},
           "steps":{"nodes":[]},"annotations":{"nodes":[]}},
          {"__typename":"CheckRun","name":"fhe-engine-unit-tests","status":"IN_PROGRESS","conclusion":null,"detailsUrl":"https://github.com/o/r/actions/runs/2/job/22",
           "startedAt":"2026-10-08T13:01:00Z","completedAt":null,"checkSuite":{"workflowRun":{"workflow":{"name":"Unit Tests"}}},
           "steps":{"nodes":[]},"annotations":{"nodes":[]}},
          {"__typename":"CheckRun","name":"Cursor Bugbot","status":"COMPLETED","conclusion":"SKIPPED","detailsUrl":"https://cursor.com",
           "startedAt":null,"completedAt":null,"checkSuite":{"workflowRun":null},"steps":{"nodes":[]},"annotations":{"nodes":[]}},
          {"__typename":"StatusContext","context":"ci/legacy","state":"ERROR","targetUrl":"https://ci/1","description":"Build broke","createdAt":"2026-10-08T13:00:00Z"}
        ]}}}}]}}}}}
        """#
        let checks = try GitHubDecoding.checks(from: Data(json.utf8))
        let changelog = try #require(checks.first { $0.name == "check-changelog" })
        #expect(changelog.outcome == .failed)
        #expect(changelog.workflow == "Changelog Check")
        #expect(changelog.failedStep == "Wait for approval")
        // Warnings and notices are noise next to why it failed.
        #expect(changelog.errors == ["CHANGELOG.md was not updated"])
        #expect(checks.first { $0.name == "fhe-engine-unit-tests" }?.outcome == .running)
        let status = try #require(checks.first { $0.name == "ci/legacy" })
        #expect(status.outcome == .failed && status.errors == ["Build broke"] && status.workflow == nil)

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

    @Test func parsesDatesWithAndWithoutFractionsAndKeepsTheOffset() throws {
        #expect(JSON.parseISO8601("2026-08-27T11:12:21Z") == Date(timeIntervalSince1970: 1_787_829_141))
        #expect(JSON.parseISO8601("2026-08-27T13:12:21+02:00") == Date(timeIntervalSince1970: 1_787_829_141))
        let fractional = try #require(JSON.parseISO8601("2026-08-23T13:54:57.327+02:00"))
        #expect(abs(fractional.timeIntervalSince1970 - 1_787_486_097.327) < 0.001)
        #expect(JSON.parseISO8601("nope") == nil)
    }
}

@Suite struct RepositoryListTests {
    @Test func searchesScopeToTheTrackedReposRatherThanTheOrg() {
        let queries = GitHubQueries.searches(login: "me", repos: ["fhenixprotocol/cofhe", "fhenixprotocol/gitops"], since: Fixtures.t0)
        for query in [queries.mine, queries.reviews, queries.merged] {
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
        #expect(blocks.contains(.quote([.paragraph("a note")])))
        #expect(blocks.contains(.rule))
        #expect(!blocks.contains(.heading(level: 1, text: "not a heading")))
    }

    /// A bot's summary as PR descriptions carry them: the HTML comment hidden, the quote one block, the alert named.
    @Test func aQuoteIsOneBlockAndCommentsAreHidden() {
        let text = "Intro.\n<!-- CURSOR_SUMMARY -->\n> [!NOTE]\n> **Medium Risk**\n>\n> Details here.\n>\n\n<!-- multi\nline -->After.\n\n<sup>Reviewed by Bugbot.</sup>"
        #expect(Markdown.blocks(text) == [
            .paragraph("Intro."), .quote([.paragraph("**Note**"), .paragraph("**Medium Risk**"), .paragraph("Details here.")]),
            .paragraph("After."), .paragraph("Reviewed by Bugbot."),
        ])
    }

    /// A GitHub alert holds Markdown of its own: CodeRabbit's draft notice is a heading and a checklist inside `>`.
    @Test func aQuoteHoldsBlocksOfItsOwn() {
        #expect(Markdown.blocks("> [!IMPORTANT]\n> ## Title\n> - [ ] item") == [
            .quote([.paragraph("**Important**"), .heading(level: 2, text: "Title"), .task(indent: 0, done: false, text: "item")]),
        ])
        #expect(Markdown.blocks("> outer\n> > inner") == [.quote([.paragraph("outer"), .quote([.paragraph("inner")])])])
    }

    /// CodeRabbit's walkthrough table breaks lines in a cell with `<br>`: the row stays one row, the break a space.
    @Test func aBreakInATableRowKeepsTheRow() {
        let text = "| File | Change |\n|---|---|\n| `a.rs` | One.<br>Two.<br/> |\nNext<br>line"
        #expect(Markdown.blocks(text) == [
            .table(header: ["File", "Change"], rows: [["`a.rs`", "One. Two."]]), .paragraph("Next line"),
        ])
    }

    /// The HTML rewrite is for prose: a fenced HTML block keeps its tags, comments and breaks.
    @Test func aFencedHTMLBlockKeepsItsTags() {
        let text = "<b>Bold</b>\n```html\n<div><br>\n<!-- note --><b>x</b></div>\n```\n<br>after"
        #expect(Markdown.blocks(text) == [
            .paragraph("**Bold**"), .code(language: "html", text: "<div><br>\n<!-- note --><b>x</b></div>"), .paragraph("after"),
        ])
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
