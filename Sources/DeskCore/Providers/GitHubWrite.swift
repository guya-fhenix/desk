import Foundation

/// One comment on its way into the draft review. A nil `line` is a comment on the file as a whole.
public struct DraftThread: Sendable, Hashable {
    public var path: String
    public var line: Int?
    public var side: DiffSide
    public var body: String

    public init(path: String, line: Int?, side: DiffSide = .right, body: String) {
        self.path = path
        self.line = line
        self.side = side
        self.body = body
    }

    /// Where it sits. One comment per line: a draft that already has one there — yours, or an earlier
    /// run's — keeps it, and this one is not added.
    var key: DraftKey { DraftKey(path: path, line: line) }
}

struct DraftKey: Hashable {
    var path: String
    var line: Int?
}

/// What a post did to the pending review.
public struct PostedDraft: Sendable, Hashable {
    /// GraphQL node id of the pending review, new or already there.
    public var id: String
    public var added: Int
    /// Left out because the draft already had a comment on that line.
    public var skipped: Int

    public init(id: String, added: Int, skipped: Int) {
        self.id = id
        self.added = added
        self.skipped = skipped
    }
}

public enum GitHubWriteError: Error, CustomStringConvertible, Sendable {
    /// GitHub refused the mutation; the message is its own.
    case refused(String)
    /// The draft exists but not every comment made it in. A re-run adds only what it lacks.
    case partial(added: Int, underlying: String)
    case unreadable(String)

    public var description: String {
        switch self {
        case .refused(let message): return "GitHub refused the draft: \(message)"
        case .partial(let added, let underlying):
            return "the draft on GitHub has only \(added) of the comments: \(underlying)"
        case .unreadable(let text): return "unreadable answer from GitHub: \(text.prefix(200))"
        }
    }
}

/// Every write the app makes to GitHub lives in this file, so they stay auditable in one place — everything in
/// `GitHubProvider.swift` reads. Two kinds: Claude's comments into your pending review on someone else's PR,
/// here, and the flow's moves on your own PRs, at the end.
///
/// A pending review is visible to you alone and notifies nobody. Nothing here submits one, approves,
/// requests changes or comments in public: you finish the review on GitHub.
extension GitHubProvider {
    /// Adds the threads to your pending review on the PR, creating one against `commitId` when there is
    /// none. GitHub allows one pending review per person per PR, so an existing one — even one you started
    /// by hand — is added to, never replaced. Nil when there was nothing to add and no draft to add it to.
    public func postDraft(repo: String, number: Int, commitId: String, threads: [DraftThread]) async throws -> PostedDraft? {
        let target = try await pendingDraft(repo: repo, number: number)
        let fresh = threads.filter { !target.keys.contains($0.key) }
        let skipped = threads.count - fresh.count
        var draftId = target.draftId
        guard !fresh.isEmpty else { return draftId.map { PostedDraft(id: $0, added: 0, skipped: skipped) } }

        var remaining = fresh
        if draftId == nil {
            // Line comments go in with the review itself, so a new draft lands whole or not at all.
            let lines = fresh.filter { $0.line != nil }
            draftId = try await createDraft(pullRequestId: target.pullRequestId, commitId: commitId, threads: lines)
            remaining = fresh.filter { $0.line == nil }
        }
        guard let draftId else { throw GitHubWriteError.unreadable("no draft id") }
        var added = fresh.count - remaining.count
        for thread in remaining {
            do {
                try await addThread(to: draftId, thread)
                added += 1
            } catch {
                throw GitHubWriteError.partial(added: added, underlying: "\(error)")
            }
        }
        return PostedDraft(id: draftId, added: added, skipped: skipped)
    }

    /// The PR's node id and your pending review on it, with the lines it already comments on. Only your
    /// own pending review is ever visible, so the first one is it.
    private func pendingDraft(repo: String, number: Int) async throws -> (pullRequestId: String, draftId: String?, keys: Set<DraftKey>) {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw GitHubWriteError.refused("not owner/name: \(repo)") }
        let data = try await graphQL(query: GitHubQueries.pendingDraftQuery, variables: [
            "owner": parts[0], "name": parts[1], "number": number,
        ])
        let root = try Self.data(data)
        guard let pull = (root["repository"] as? [String: Any])?["pullRequest"] as? [String: Any],
              let pullId = pull["id"] as? String
        else { throw GitHubWriteError.unreadable(String(decoding: data, as: UTF8.self)) }
        let review = ((pull["reviews"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first
        let comments = ((review?["comments"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let keys = Set(comments.compactMap { comment -> DraftKey? in
            guard let path = comment["path"] as? String else { return nil }
            return DraftKey(path: path, line: (comment["line"] as? Int) ?? (comment["originalLine"] as? Int))
        })
        return (pullId, review?["id"] as? String, keys)
    }

    private func createDraft(pullRequestId: String, commitId: String, threads: [DraftThread]) async throws -> String {
        let data = try await graphQL(query: GitHubQueries.createDraftMutation, variables: [
            "pr": pullRequestId,
            "commit": commitId,
            "threads": threads.map { thread -> [String: any Sendable] in
                ["path": thread.path, "line": thread.line ?? 0, "side": thread.side.rawValue, "body": thread.body]
            },
        ], retrying: false)
        let root = try Self.data(data)
        guard let id = ((root["addPullRequestReview"] as? [String: Any])?["pullRequestReview"] as? [String: Any])?["id"] as? String
        else { throw GitHubWriteError.unreadable(String(decoding: data, as: UTF8.self)) }
        return id
    }

    private func addThread(to draftId: String, _ thread: DraftThread) async throws {
        var variables: [String: any Sendable] = ["review": draftId, "path": thread.path, "body": thread.body]
        if let line = thread.line {
            variables["line"] = line
            variables["side"] = thread.side.rawValue
            variables["subject"] = "LINE"
        } else {
            variables["subject"] = "FILE"
        }
        _ = try Self.data(try await graphQL(query: GitHubQueries.addThreadMutation, variables: variables, retrying: false))
    }

    /// The `data` object of a GraphQL answer, or GitHub's own error messages.
    private static func data(_ data: Data) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw GitHubWriteError.unreadable(String(decoding: data, as: UTF8.self))
        }
        if let errors = object["errors"] as? [[String: Any]], !errors.isEmpty {
            throw GitHubWriteError.refused(errors.compactMap { $0["message"] as? String }.joined(separator: "; "))
        }
        guard let payload = object["data"] as? [String: Any] else {
            throw GitHubWriteError.unreadable(String(decoding: data, as: UTF8.self))
        }
        return payload
    }
}

/// The flow's moves on your own PRs, each one the result of a press of yours.
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

    /// Asks a team of the org that owns the repo to review. Asking again after a team member has reviewed puts the
    /// team back on the PR. The REST API, for the reason `editPull` gives.
    public func requestTeamReview(repo: String, number: Int, team: String) async throws {
        try await Shell.output(ghPath, ["api", "-X", "POST", "repos/\(repo)/pulls/\(number)/requested_reviewers", "-f", "team_reviewers[]=\(team)"])
    }
}

extension GitHubQueries {
    static let pendingDraftQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          id
          reviews(states: PENDING, first: 1) { nodes { id comments(first: 100) { nodes { path line originalLine } } } }
        }
      }
    }
    """

    /// No `event`: that is what keeps the review pending. The verdict is chosen when it is submitted.
    static let createDraftMutation = """
    mutation($pr: ID!, $commit: GitObjectID!, $threads: [DraftPullRequestReviewThread]) {
      addPullRequestReview(input: { pullRequestId: $pr, commitOID: $commit, threads: $threads }) {
        pullRequestReview { id }
      }
    }
    """

    static let addThreadMutation = """
    mutation($review: ID!, $path: String!, $body: String!, $line: Int, $side: DiffSide, $subject: PullRequestReviewThreadSubjectType) {
      addPullRequestReviewThread(input: {
        pullRequestReviewId: $review, path: $path, body: $body, line: $line, side: $side, subjectType: $subject
      }) { thread { id } }
    }
    """
}
