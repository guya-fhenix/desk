import Foundation

public enum JiraError: Error, CustomStringConvertible, Sendable {
    case acliNotFound
    case notAuthenticated
    case badOutput(String)
    /// The workflow has no way from where the ticket stands to the status asked for. acli names the ones
    /// it does have, which is the whole diagnostic.
    case transitionRefused(key: String, status: String, detail: String)

    public var description: String {
        switch self {
        case .acliNotFound: return "Jira: acli not found. Install it with `brew install acli` or set the path in Settings."
        case .notAuthenticated: return "Jira: not signed in. Run `acli jira auth login --web` in a terminal."
        case .badOutput(let detail): return "Jira: unexpected acli output — \(detail)"
        case .transitionRefused(let key, let status, let detail):
            return "Jira: could not move \(key) to “\(status)” — \(detail)"
        }
    }
}

/// Where acli is signed in, as `acli jira auth status` reports it.
public struct JiraAccount: Sendable, Equatable {
    public var site: String
    public var email: String?

    public init(site: String, email: String? = nil) {
        self.site = site
        self.email = email
    }
}

/// Reads Jira through the Atlassian CLI, the way `GitHubProvider` reads GitHub through `gh`: the CLI
/// holds the OAuth tokens, so the app stores no Jira credential of its own.
public actor JiraProvider {
    /// Not private: the one write path lives in `JiraWrite.swift`, apart from these reads.
    let acliPath: String
    /// The signed-in site, only needed to build browse URLs. Read once from the CLI.
    private var account: JiraAccount?

    public init(acliPath: String) {
        self.acliPath = acliPath
    }

    /// Nil when the CLI is there but nobody is signed in.
    public func signedInAccount() async -> JiraAccount? {
        if let account { return account }
        guard let text = try? await Shell.output(acliPath, ["jira", "auth", "status"]) else { return nil }
        guard let parsed = JiraDecoding.account(fromStatus: text) else { return nil }
        account = parsed
        return parsed
    }

    private static let mine = "assignee = currentUser() AND resolution = Unresolved"

    /// Two searches rather than one: sprint membership is a JQL function, not a field acli will return,
    /// so which search a ticket comes back in is what places it.
    public func myOpenIssues() async throws -> [Ticket] {
        async let sprint = search(
            jql: "\(Self.mine) AND sprint in openSprints() ORDER BY updated DESC", assignedToMe: true, placement: .sprint
        )
        async let backlog = search(
            jql: "\(Self.mine) AND (sprint is EMPTY OR sprint not in openSprints()) ORDER BY updated DESC",
            assignedToMe: true, placement: .backlog
        )
        return try await sprint + backlog
    }

    /// Tickets referenced by a PR but assigned to someone else. The Tickets screen never shows these, so
    /// they are left unplaced rather than given a sprint they may not be in.
    public func issues(keys: [String]) async throws -> [Ticket] {
        guard !keys.isEmpty else { return [] }
        return try await search(jql: "key in (\(keys.joined(separator: ","))) ORDER BY updated DESC", assignedToMe: false, placement: .unknown)
    }

    public func projectKeys() async throws -> [String] {
        let data = try await run(["jira", "project", "list", "--paginate", "--json"])
        return try JiraDecoding.projectKeys(from: data)
    }

    /// `--paginate` walks every page itself, which is why no cursor is threaded through here.
    private func search(jql: String, assignedToMe: Bool, placement: TicketPlacement) async throws -> [Ticket] {
        guard let account = await signedInAccount() else { throw JiraError.notAuthenticated }
        let data = try await run([
            "jira", "workitem", "search", "--jql", jql,
            // acli allows only this handful; `updated` is not among them, which is why `Ticket` carries no
            // timestamp. The JQL still orders by it.
            "--fields", "key,summary,status,priority",
            "--json", "--paginate",
        ])
        return try JiraDecoding.tickets(from: data, site: account.site, assignedToMe: assignedToMe, placement: placement)
    }

    private func run(_ arguments: [String]) async throws -> Data {
        do {
            return Data(try await Shell.output(acliPath, arguments).utf8)
        } catch let error as ShellError {
            if case .failed(_, _, let stderr) = error, stderr.lowercased().contains("unauthorized") {
                throw JiraError.notAuthenticated
            }
            if case .executableNotFound = error { throw JiraError.acliNotFound }
            throw error
        }
    }
}

public enum JiraDecoding {
    /// `acli jira auth status` prints a short block of labelled lines rather than JSON.
    public static func account(fromStatus text: String) -> JiraAccount? {
        guard text.contains("Authenticated") else { return nil }
        var site: String?
        var email: String?
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let value = trimmed.dropPrefix("Site:") { site = value }
            if let value = trimmed.dropPrefix("Email:") { email = value }
        }
        guard let site, !site.isEmpty else { return nil }
        return JiraAccount(site: site, email: email)
    }

    public static func tickets(from data: Data, site: String, assignedToMe: Bool, placement: TicketPlacement = .unknown) throws -> [Ticket] {
        do {
            return try JSONDecoder().decode([Issue].self, from: data).map { ticket($0, site: site, assignedToMe: assignedToMe, placement: placement) }
        } catch {
            throw JiraError.badOutput("\(error)")
        }
    }

    public static func projectKeys(from data: Data) throws -> [String] {
        do {
            return try JSONDecoder().decode([Project].self, from: data).map(\.key)
        } catch {
            throw JiraError.badOutput("\(error)")
        }
    }

    static func ticket(_ issue: Issue, site: String, assignedToMe: Bool, placement: TicketPlacement) -> Ticket {
        Ticket(
            key: issue.key,
            summary: issue.fields.summary,
            status: issue.fields.status.name,
            category: TicketStatusCategory(jiraKey: issue.fields.status.statusCategory.key),
            priority: issue.fields.priority?.name,
            url: "https://\(site)/browse/\(issue.key)",
            assignedToMe: assignedToMe,
            placement: placement
        )
    }

    public struct Issue: Decodable {
        public var key: String
        public var fields: Fields
    }

    public struct Fields: Decodable {
        public var summary: String
        public var status: Status
        public var priority: Named?
    }

    public struct Status: Decodable {
        public var name: String
        public var statusCategory: StatusCategory
    }

    public struct StatusCategory: Decodable { public var key: String }
    public struct Named: Decodable { public var name: String }
    public struct Project: Decodable { public var key: String }
}

private extension String {
    /// The value after a `Label:` prefix, trimmed; nil when the line is something else.
    func dropPrefix(_ label: String) -> String? {
        guard hasPrefix(label) else { return nil }
        return String(dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
    }
}
