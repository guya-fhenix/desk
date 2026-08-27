import Foundation

public struct RepoRef: Codable, Sendable, Hashable, Identifiable {
    public var id: String { root }
    public var name: String
    public var root: String
    public var remote: String

    public init(name: String, root: String, remote: String) {
        self.name = name
        self.root = root
        self.remote = remote
    }
}

public struct Worktree: Codable, Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var repoName: String
    public var repoRoot: String
    public var path: String
    public var branch: String?
    public var headSha: String
    public var isMain: Bool
    public var isPrunable: Bool
    public var dirtyFiles: Int
    public var ahead: Int
    public var behind: Int
    public var hasUpstream: Bool
    public var behindDefault: Int
    public var defaultBranch: String
    public var lastCommitAt: Date?

    public init(
        repoName: String, repoRoot: String, path: String, branch: String?, headSha: String,
        isMain: Bool, isPrunable: Bool = false, dirtyFiles: Int = 0, ahead: Int = 0, behind: Int = 0,
        hasUpstream: Bool = true, behindDefault: Int = 0, defaultBranch: String = "main", lastCommitAt: Date? = nil
    ) {
        self.repoName = repoName
        self.repoRoot = repoRoot
        self.path = path
        self.branch = branch
        self.headSha = headSha
        self.isMain = isMain
        self.isPrunable = isPrunable
        self.dirtyFiles = dirtyFiles
        self.ahead = ahead
        self.behind = behind
        self.hasUpstream = hasUpstream
        self.behindDefault = behindDefault
        self.defaultBranch = defaultBranch
        self.lastCommitAt = lastCommitAt
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var isOnDefaultBranch: Bool { branch == defaultBranch }
    public var hasLocalWork: Bool { dirtyFiles > 0 || ahead > 0 || !hasUpstream && !isOnDefaultBranch }
}
