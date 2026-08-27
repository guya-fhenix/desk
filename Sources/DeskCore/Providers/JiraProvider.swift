import Foundation

public enum JiraError: Error, CustomStringConvertible, Sendable {
    case badURL(String)
    case http(status: Int, body: String)
    case unauthorized

    public var description: String {
        switch self {
        case .badURL(let url): return "Jira: bad URL \(url)"
        case .http(let status, let body): return "Jira: HTTP \(status) \(body.prefix(200))"
        case .unauthorized: return "Jira: authentication failed. Check email and API token."
        }
    }
}

public actor JiraProvider {
    private let site: String
    private let authorization: String
    private let session: URLSession
    private static let pageSize = 100
    private static let fields = "summary,status,priority,updated"

    public init(site: String, email: String, token: String, session: URLSession = .shared) {
        self.site = site
        self.authorization = "Basic " + Data("\(email):\(token)".utf8).base64EncodedString()
        self.session = session
    }

    public func myOpenIssues() async throws -> [Ticket] {
        try await search(jql: "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC", assignedToMe: true)
    }

    public func issues(keys: [String]) async throws -> [Ticket] {
        guard !keys.isEmpty else { return [] }
        let list = keys.joined(separator: ",")
        return try await search(jql: "key in (\(list)) ORDER BY updated DESC", assignedToMe: false)
    }

    public func projectKeys() async throws -> [String] {
        let data = try await get(path: "/rest/api/3/project/search", query: [URLQueryItem(name: "maxResults", value: "100")])
        let page = try JSONDecoder().decode(ProjectPage.self, from: data)
        return page.values.map(\.key)
    }

    private func search(jql: String, assignedToMe: Bool) async throws -> [Ticket] {
        var tickets: [Ticket] = []
        var nextPageToken: String?
        repeat {
            var query = [
                URLQueryItem(name: "jql", value: jql),
                URLQueryItem(name: "fields", value: Self.fields),
                URLQueryItem(name: "maxResults", value: String(Self.pageSize)),
            ]
            if let nextPageToken { query.append(URLQueryItem(name: "nextPageToken", value: nextPageToken)) }
            let data = try await get(path: "/rest/api/3/search/jql", query: query)
            let page = try JiraDecoding.decoder().decode(SearchPage.self, from: data)
            tickets.append(contentsOf: page.issues.map { JiraDecoding.ticket($0, site: site, assignedToMe: assignedToMe) })
            nextPageToken = page.isLast == true ? nil : page.nextPageToken
        } while nextPageToken != nil
        return tickets
    }

    private func get(path: String, query: [URLQueryItem]) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = site
        components.path = path
        components.queryItems = query
        guard let url = components.url else { throw JiraError.badURL(path) }
        var request = URLRequest(url: url)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw JiraError.unauthorized }
        guard (200..<300).contains(status) else { throw JiraError.http(status: status, body: String(decoding: data, as: UTF8.self)) }
        return data
    }

    struct SearchPage: Decodable {
        var issues: [Issue]
        var nextPageToken: String?
        var isLast: Bool?
    }

    struct Issue: Decodable {
        var key: String
        var fields: Fields
    }

    struct Fields: Decodable {
        var summary: String
        var status: Status
        var priority: Named?
        var updated: Date
    }

    struct Status: Decodable {
        var name: String
        var statusCategory: StatusCategory
    }

    struct StatusCategory: Decodable { var key: String }
    struct Named: Decodable { var name: String }
    struct ProjectPage: Decodable { var values: [Project] }
    struct Project: Decodable { var key: String }
}

public enum JiraDecoding {
    /// Jira sends "2026-08-25T08:00:47.108+0300", which is not strict ISO-8601.
    static func decoder() -> JSONDecoder {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = formatter.date(from: text) ?? JSON.parseISO8601(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad Jira date: \(text)"))
        }
        return decoder
    }

    static func ticket(_ issue: JiraProvider.Issue, site: String, assignedToMe: Bool) -> Ticket {
        Ticket(
            key: issue.key,
            summary: issue.fields.summary,
            status: issue.fields.status.name,
            category: TicketStatusCategory(jiraKey: issue.fields.status.statusCategory.key),
            priority: issue.fields.priority?.name,
            url: "https://\(site)/browse/\(issue.key)",
            updatedAt: issue.fields.updated,
            assignedToMe: assignedToMe
        )
    }

    public static func tickets(fromSearchResponse data: Data, site: String, assignedToMe: Bool) throws -> [Ticket] {
        let page = try decoder().decode(JiraProvider.SearchPage.self, from: data)
        return page.issues.map { ticket($0, site: site, assignedToMe: assignedToMe) }
    }
}
