import Foundation

/// Every write the app makes to GitHub lives in this file, so they stay auditable in one place — everything in
/// `GitHubProvider.swift` reads. Each is the result of a press of yours: the flow's moves on your own PRs, and in any
/// PR's conversation a reply, a resolve and a comment, posted as you. Nothing here reviews, approves or requests
/// changes, and no comment starts on a line: those are the review session's, on your word.
extension GitHubProvider {
    public func markReady(repo: String, number: Int) async throws {
        try await Shell.output(ghPath, ["pr", "ready", String(number), "--repo", repo])
    }

    /// Renames one of your PRs, from the title on its page.
    public func retitle(repo: String, number: Int, title: String) async throws {
        try await editPull(repo: repo, number: number, ["title": title])
    }

    /// Replaces a PR's description. On stdin, so a body of any length or character goes exactly as written.
    public func editBody(repo: String, number: Int, body: String) async throws {
        try await editPull(repo: repo, number: number, ["body": body])
    }

    /// The REST API rather than `gh pr edit`: gh 2.70 and older read the PR's classic project cards before any
    /// edit, and GitHub now refuses that query, so every edit failed.
    private func editPull(repo: String, number: Int, _ fields: [String: String]) async throws {
        let json = try JSONSerialization.data(withJSONObject: fields)
        try await Shell.output(ghPath, ["api", "-X", "PATCH", "repos/\(repo)/pulls/\(number)", "--input", "-"], stdin: json)
    }

    /// Closes one of your PRs without merging it; it can be reopened on GitHub.
    public func close(repo: String, number: Int) async throws {
        try await Shell.output(ghPath, ["pr", "close", String(number), "--repo", repo])
    }

    /// Always a squash: one commit per PR on the base branch.
    public func squashMerge(repo: String, number: Int) async throws {
        try await Shell.output(ghPath, ["pr", "merge", String(number), "--repo", repo, "--squash"])
    }

    /// Replies in a review thread.
    public func reply(threadId: String, body: String) async throws {
        try await mutate(
            "mutation($id: ID!, $body: String!) { addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $id, body: $body}) { comment { id } } }",
            ["id": threadId, "body": body]
        )
    }

    /// Resolves a review thread, or opens a resolved one again.
    public func setResolved(threadId: String, _ resolved: Bool) async throws {
        let field = resolved ? "resolveReviewThread" : "unresolveReviewThread"
        try await mutate("mutation($id: ID!) { \(field)(input: {threadId: $id}) { thread { isResolved } } }", ["id": threadId])
    }

    /// A comment on the PR's conversation. The body on stdin, as `editPull` sends one.
    public func comment(repo: String, number: Int, body: String) async throws {
        let json = try JSONSerialization.data(withJSONObject: ["body": body])
        try await Shell.output(ghPath, ["api", "-X", "POST", "repos/\(repo)/issues/\(number)/comments", "--input", "-"], stdin: json)
    }

    /// Runs once: a retry after a 502 could post it twice. GraphQL's own errors come back as an answer, not a failure.
    private func mutate(_ query: String, _ variables: [String: any Sendable]) async throws {
        try GitHubDecoding.throwErrors(in: try await graphQL(query: query, variables: variables, retrying: false))
    }

    /// Asks a team of the org that owns the repo to review. Asking again after a team member has reviewed puts the
    /// team back on the PR. The REST API, for the reason `editPull` gives.
    public func requestTeamReview(repo: String, number: Int, team: String) async throws {
        try await Shell.output(ghPath, ["api", "-X", "POST", "repos/\(repo)/pulls/\(number)/requested_reviewers", "-f", "team_reviewers[]=\(team)"])
    }
}
