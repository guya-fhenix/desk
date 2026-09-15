import Foundation

public enum RebaseReason: String, Sendable {
    case conflicts
    case behindBase
    case baseMerged

    public var text: String {
        switch self {
        case .conflicts: return "merge conflicts"
        case .behindBase: return "behind its base"
        case .baseMerged: return "base branch has no open PR"
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

    /// Maps each PR url to the url of the PR it is stacked on.
    public static func stackParents(_ pullRequests: [PullRequest]) -> [String: String] {
        var headsByRepo: [String: [String: String]] = [:]
        for pr in pullRequests { headsByRepo[pr.repo, default: [:]][pr.headRef] = pr.url }
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

    public static func defaultBranches(worktrees: [Worktree], pullRequests: [PullRequest]) -> [String: String] {
        var result: [String: String] = [:]
        for worktree in worktrees where worktree.isMain { result[worktree.repoName] = worktree.defaultBranch }
        for pr in pullRequests where result[pr.repoName] == nil {
            let bases = pullRequests.filter { $0.repoName == pr.repoName }.map(\.baseRef)
            result[pr.repoName] = bases.contains("master") && !bases.contains("main") ? "master" : "main"
        }
        return result
    }

    public static func rebaseReason(_ pr: PullRequest, openHeads: Set<String>, defaultBranch: String) -> RebaseReason? {
        if pr.mergeState == .dirty { return .conflicts }
        if pr.mergeState == .behind { return .behindBase }
        if pr.baseRef != defaultBranch && !openHeads.contains(pr.baseRef) { return .baseMerged }
        return nil
    }

    public static func openHeadsByRepo(_ pullRequests: [PullRequest]) -> [String: Set<String>] {
        var heads: [String: Set<String>] = [:]
        for pr in pullRequests where pr.state == .open { heads[pr.repoName, default: []].insert(pr.headRef) }
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
}
