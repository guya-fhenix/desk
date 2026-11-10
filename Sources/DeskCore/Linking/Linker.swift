import Foundation

public enum RebaseReason: String, Sendable {
    case conflicts
    case behindBase
    case baseMerged

    public var text: String {
        switch self {
        case .conflicts: return "merge conflicts"
        case .behindBase: return "behind its base"
        case .baseMerged: return "its base branch was merged"
        }
    }
}

public enum Linker {
    /// The local clone of a PR's repository: the remote that names the same owner/name wins, else a
    /// directory named like the repo.
    public static func repo(for pr: PullRequest, in repos: [RepoRef]) -> RepoRef? {
        let slug = pr.repo.lowercased()
        if let match = repos.first(where: { GitParsing.repoSlug(fromRemote: $0.remote) == slug }) { return match }
        return repos.first { $0.name == pr.repoName }
    }

    /// Whether a PR into a branch named like this one's head is built on it. Not a fork's, nor one from the default
    /// branch: a PR into a branch of that name targets origin's branch, which only shares the name.
    private static func isBase(_ pr: PullRequest) -> Bool { !pr.isCrossRepository && pr.headRef != pr.defaultBranch }

    /// Maps each PR url to the url of the PR it is stacked on.
    public static func stackParents(_ pullRequests: [PullRequest]) -> [String: String] {
        var headsByRepo: [String: [String: String]] = [:]
        for pr in pullRequests where isBase(pr) { headsByRepo[pr.repo, default: [:]][pr.headRef] = pr.url }
        var parents: [String: String] = [:]
        for pr in pullRequests {
            if let parent = headsByRepo[pr.repo]?[pr.baseRef], parent != pr.url { parents[pr.url] = parent }
        }
        return parents
    }

    public static func stackDepth(_ url: String, parents: [String: String]) -> Int {
        var depth = 0
        var current = url
        var visited = Set<String>()
        while let parent = parents[current], visited.insert(parent).inserted {
            depth += 1
            current = parent
        }
        return depth
    }

    /// Orders PRs so every stack is contiguous: stacks sorted by comparing their roots, each child indented
    /// beneath its parent by number. A PR whose parent is not in the list is a root; the caller notes the parent.
    public static func stacked(
        _ pullRequests: [PullRequest], parents: [String: String], order: [KeyPathComparator<StackedPullRequest>]
    ) -> [StackedPullRequest] {
        let urls = Set(pullRequests.map(\.url))
        var children: [String: [PullRequest]] = [:]
        var rootPullRequests: [PullRequest] = []
        for pr in pullRequests {
            if let parent = parents[pr.url], urls.contains(parent) { children[parent, default: []].append(pr) } else { rootPullRequests.append(pr) }
        }

        var visited = Set<String>()
        func build(_ pr: PullRequest, depth: Int, into stack: inout [StackedPullRequest]) {
            guard visited.insert(pr.url).inserted else { return }
            let index = stack.count
            stack.append(StackedPullRequest(pullRequest: pr, depth: depth, stackSize: 1))
            for child in (children[pr.url] ?? []).sorted(by: { $0.number < $1.number }) { build(child, depth: depth + 1, into: &stack) }
            stack[index].stackSize = stack.count - index
        }
        var roots: [StackedPullRequest] = []
        var stacks: [String: [StackedPullRequest]] = [:]
        // PRs whose bases form a cycle never hang off a root; the second pass lists them rather than drops them.
        for pr in rootPullRequests + pullRequests where !visited.contains(pr.url) {
            var stack: [StackedPullRequest] = []
            build(pr, depth: 0, into: &stack)
            roots.append(stack[0])
            stacks[stack[0].id] = stack
        }
        return roots.sorted(using: order).flatMap { stacks[$0.id] ?? [] }
    }

    /// A base that is neither the default branch nor a merged PR's head is a release branch, a teammate's draft or a
    /// parent the searches did not reach: nothing says it needs a rebase, so it gets none.
    public static func rebaseReason(_ pr: PullRequest, mergedHeads: Set<String>) -> RebaseReason? {
        if pr.hasConflicts { return .conflicts }
        if pr.mergeState == .behind { return .behindBase }
        if pr.baseRef != pr.defaultBranch && mergedHeads.contains(pr.baseRef) { return .baseMerged }
        return nil
    }

    /// The head branches of merged PRs, by repo `owner/name`.
    public static func mergedHeadsByRepo(_ merged: [PullRequest]) -> [String: Set<String>] {
        var heads: [String: Set<String>] = [:]
        for pr in merged where isBase(pr) { heads[pr.repo, default: []].insert(pr.headRef) }
        return heads
    }
}

/// A pull request placed in its stack: depth 0 for a root, one more for each PR it sits on within the same list.
public struct StackedPullRequest: Identifiable, Sendable, Hashable {
    public var pullRequest: PullRequest
    public var depth: Int
    /// PRs in the stack this one roots, counting itself. 1 when nothing is stacked on it.
    public var stackSize: Int

    public var id: String { pullRequest.url }

    public init(pullRequest: PullRequest, depth: Int = 0, stackSize: Int = 1) {
        self.pullRequest = pullRequest
        self.depth = depth
        self.stackSize = stackSize
    }
}
