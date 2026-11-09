import Foundation

public enum JiraError: Error, CustomStringConvertible, Sendable {
    case acliNotFound
    case notAuthenticated
    case badOutput(String)
    /// The workflow has no way from where the ticket stands to the status asked for. acli names the ones
    /// it does have, which is the whole diagnostic.
    case transitionRefused(key: String, status: String, detail: String)
    /// Jira would not save an edit to the ticket's summary or description; acli says why.
    case editRefused(key: String, detail: String)

    public var description: String {
        switch self {
        case .acliNotFound: return "Jira: acli not found. Install it with `brew install acli` or set the path in Settings."
        case .notAuthenticated: return "Jira: not signed in. Run `acli jira auth login --web` in a terminal."
        case .badOutput(let detail): return "Jira: unexpected acli output — \(detail)"
        case .transitionRefused(let key, let status, let detail):
            return "Jira: could not move \(key) to “\(status)” — \(detail)"
        case .editRefused(let key, let detail):
            return "Jira: could not save \(key) — \(detail)"
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
    /// What runs acli: `Shell.run`, but for a test.
    let run: ShellRun
    /// The signed-in site, only needed to build browse URLs. Read once from the CLI.
    private var account: JiraAccount?

    public init(acliPath: String, run: @escaping ShellRun = Shell.run) {
        self.acliPath = acliPath
        self.run = run
    }

    /// Nil when the CLI is there but nobody is signed in.
    public func signedInAccount() async -> JiraAccount? {
        if let account { return account }
        guard let text = try? await Shell.output(acliPath, ["jira", "auth", "status"], run: run) else { return nil }
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

    /// Everyone else's unfinished tickets in these projects, unassigned ones included, for the Jira screen's
    /// assignee filter. Placed the way yours are; nothing without a project to scope it to, or it would be the site.
    public func teamOpenIssues(projects: [String]) async throws -> [Ticket] {
        guard !projects.isEmpty else { return [] }
        let others = "project in (\(projects.joined(separator: ","))) AND resolution = Unresolved"
            + " AND (assignee is EMPTY OR assignee != currentUser())"
        async let sprint = search(jql: "\(others) AND sprint in openSprints() ORDER BY updated DESC", assignedToMe: false, placement: .sprint)
        async let backlog = search(
            jql: "\(others) AND (sprint is EMPTY OR sprint not in openSprints()) ORDER BY updated DESC",
            assignedToMe: false, placement: .backlog
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
        let data = try await acli(["jira", "project", "list", "--paginate", "--json"])
        return try JiraDecoding.projectKeys(from: data)
    }

    /// `--paginate` walks every page itself, which is why no cursor is threaded through here.
    private func search(jql: String, assignedToMe: Bool, placement: TicketPlacement) async throws -> [Ticket] {
        guard let account = await signedInAccount() else { throw JiraError.notAuthenticated }
        let data = try await acli([
            "jira", "workitem", "search", "--jql", jql,
            // acli allows only this handful; `updated` is not among them, which is why `Ticket` carries no
            // timestamp. The JQL still orders by it.
            "--fields", "key,summary,status,priority,assignee,reporter,description",
            "--json", "--paginate",
        ])
        return try JiraDecoding.tickets(from: data, site: account.site, assignedToMe: assignedToMe, placement: placement)
    }

    private func acli(_ arguments: [String]) async throws -> Data {
        do {
            return Data(try await Shell.output(acliPath, arguments, run: run).utf8)
        } catch {
            throw Self.mapAcliError(error)
        }
    }

    /// What an acli failure means: acli missing, nobody signed in, or for a write, `refused` with what acli printed.
    /// Anything else, a timeout say, goes on as it came.
    static func mapAcliError(_ error: any Error, refused: ((String) -> JiraError)? = nil) -> any Error {
        guard let error = error as? ShellError else { return error }
        switch error {
        case .executableNotFound: return JiraError.acliNotFound
        case .failed(_, _, let stderr):
            if stderr.lowercased().contains("unauthorized") { return JiraError.notAuthenticated }
            return refused?(stderr.trimmingCharacters(in: .whitespacesAndNewlines)) ?? error
        case .timedOut: return error
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
            assignee: issue.fields.assignee?.displayName,
            assigneeAvatar: issue.fields.assignee?.avatarUrls?["48x48"],
            reporter: issue.fields.reporter?.displayName,
            placement: placement,
            description: JiraDescription.markdown(issue.fields.description),
            descriptionEditable: JiraDescription.roundTrips(issue.fields.description)
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
        public var assignee: Person?
        public var reporter: Person?
        public var description: ADFNode?
    }

    public struct Person: Decodable {
        public var displayName: String
        public var avatarUrls: [String: String]?
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
