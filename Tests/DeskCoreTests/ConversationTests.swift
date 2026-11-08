import DeskCore
import Foundation
import Testing

@Suite struct ConversationTests {
    private static let json = #"""
    {"data":{"repository":{"pullRequest":{
      "reviewThreads":{"nodes":[
        {"id":"T1","isResolved":false,"isOutdated":false,"path":"src/gate.rs","line":42,"originalLine":40,"diffSide":"RIGHT",
         "viewerCanReply":true,"viewerCanResolve":true,"viewerCanUnresolve":false,
         "comments":{"nodes":[
           {"id":"C1","author":{"__typename":"Bot","login":"coderabbitai"},"body":"<!-- x -->\n\n**Missing bounds check**","createdAt":"2026-11-01T10:00:00Z","url":"https://github.com/o/r/pull/1#discussion_r1"},
           {"id":"C2","author":{"__typename":"User","login":"guya"},"body":"on purpose","createdAt":"2026-11-01T11:00:00Z","url":"u2"}]}},
        {"id":"T2","isResolved":true,"isOutdated":true,"path":"src/old.rs","line":null,"originalLine":7,"diffSide":"LEFT",
         "viewerCanReply":true,"viewerCanResolve":false,"viewerCanUnresolve":true,
         "comments":{"nodes":[{"id":"C3","author":null,"body":"gone","createdAt":"2026-11-01T09:00:00Z","url":"u3"}]}}]},
      "comments":{"nodes":[
        {"id":"I1","author":{"__typename":"User","login":"haim"},"body":"LGTM overall","createdAt":"2026-11-02T08:00:00Z","url":"u4"}]},
      "reviews":{"nodes":[
        {"id":"R1","state":"COMMENTED","body":"","submittedAt":"2026-11-01T10:00:00Z","url":"u5","author":{"__typename":"Bot","login":"coderabbitai"}},
        {"id":"R2","state":"APPROVED","body":"","submittedAt":"2026-11-03T08:00:00Z","url":"u6","author":{"__typename":"User","login":"haim"}},
        {"id":"R3","state":"PENDING","body":"draft","submittedAt":null,"url":"u7","author":{"__typename":"User","login":"guya"}},
        {"id":"R4","state":"CHANGES_REQUESTED","body":"fix the gate","submittedAt":"2026-11-01T12:00:00Z","url":"u8","author":{"__typename":"User","login":"dan"}}]}
    }}}}
    """#

    @Test func decodesThreadsCommentsAndTheReviewsThatSaySomething() throws {
        let conversation = try GitHubDecoding.conversation(from: Data(Self.json.utf8))

        let open = try #require(conversation.openThreads.first)
        #expect(conversation.openThreads.count == 1 && open.location == "src/gate.rs:42")
        #expect(open.comments.map(\.author) == ["coderabbitai[bot]", "guya"])
        #expect(open.comments[0].isBot && open.comments[0].name == "coderabbitai")
        #expect(open.comments[0].firstLine == "Missing bounds check")
        #expect(open.canReply && open.canToggle)

        // Outdated: where it was written, on its side; resolved, so the press it may have is Unresolve.
        let resolved = try #require(conversation.resolvedThreads.first)
        #expect(resolved.line == 7 && resolved.side == .left && resolved.isOutdated && resolved.canToggle)
        #expect(resolved.comments[0].author == "ghost")

        // The comment and the reviews that say something, oldest first: CodeRabbit's empty review only carries its
        // threads, and a pending one is a draft.
        #expect(conversation.entries.map(\.id) == ["R4", "I1", "R2"])
        #expect(conversation.entries.map(\.verb) == ["requested changes", nil, "approved"])
    }

    @Test func botHTMLBecomesTheMarkdownItMeans() {
        let body = """
        <summary><strong><picture><img src="x.svg"></picture> Recent review info</strong></summary><br>
        <h3>Bugbot is paused</h3>
        Takes a `Vec<u8>` and <code>Option<T></code> <a href="https://x.io">here</a>
        """
        #expect(Markdown.blocks(body) == [
            .paragraph("**Recent review info**"),
            .heading(level: 3, text: "Bugbot is paused"),
            .paragraph("Takes a `Vec<u8>` and <code>Option<T></code> [here](https://x.io)"),
        ])
    }

    @Test func theDiffShowsOnlyThreadsStillOnTheirLine() throws {
        let conversation = try GitHubDecoding.conversation(from: Data(Self.json.utf8))
        #expect(conversation.threads(at: "src/gate.rs", side: .right, line: 42).map(\.id) == ["T1"])
        #expect(conversation.threads(at: "src/gate.rs", side: .left, line: 42).isEmpty)
        // Outdated: its line moved away, so the diff has no row for it.
        #expect(conversation.threads(at: "src/old.rs", side: .left, line: 7).isEmpty)
    }
}
