import DeskCore
import SwiftUI

/// Search (⌘K): one box over the dimmed window that finds any open PR the app knows of by `repo#number`,
/// title or branch, any of your tickets by key or summary, any screen by name, and the commands — each with its key.
/// ↩ opens it here — your own PR in Pull Requests, one in the review queue in Reviews, a ticket in Jira, anything
/// else on GitHub — or runs the command; ⌘↩ opens it on GitHub.
struct FinderView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    /// One result: a screen to go to, a command to run, a pull request or a ticket.
    private enum Hit: Identifiable {
        case page(Page)
        case command(Command)
        case pullRequest(PullRequest)
        case ticket(Ticket)

        var id: String {
            switch self {
            case .page(let page): return "page:\(page.title)"
            case .command(let command): return "command:\(command.title)"
            case .pullRequest(let pr): return pr.url
            case .ticket(let ticket): return "ticket:\(ticket.key)"
            }
        }
    }

    /// A press the palette can make for you, with the key that makes it without the palette.
    private struct Command {
        var title: String
        var keys: [String] = []
        var run: () -> Void
    }

    /// A screen, by the name the sidebar gives it. Settings is the one that is not a tab.
    private struct Page {
        var title: String
        var tab: DeskWindow.Tab?

        static let all = DeskWindow.Tab.allCases.map { Page(title: $0.title, tab: $0) } + [Page(title: "Settings", tab: nil)]
    }

    var body: some View {
        let hits = self.hits
        ZStack(alignment: .top) {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("PR, ticket, page, command, or #", text: $query)
                        .textFieldStyle(.plain)
                        .scaled(.title3)
                        .focused($focused)
                        .onSubmit { open(hits, onGitHub: false) }
                        .onKeyPress(.downArrow) { move(1, in: hits) }
                        .onKeyPress(.upArrow) { move(-1, in: hits) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                Hairline()
                if hits.isEmpty {
                    // Not a dead end: what the app does not know of, GitHub may.
                    VStack(alignment: .leading, spacing: 8) {
                        Text(query.isEmpty ? "No open pull requests yet." : "Nothing here matches.")
                            .scaled(.callout).foregroundStyle(.secondary)
                        if !query.isEmpty {
                            HStack(spacing: 4) {
                                KeyCap(key: "⌘")
                                KeyCap(key: "↩")
                                Text("Search GitHub for “\(query)”").scaled(.caption).foregroundStyle(.secondary).padding(.leading, 2)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(Array(hits.enumerated()), id: \.element.id) { offset, hit in
                                    row(hit, selected: offset == index)
                                        .id(offset)
                                        .onTapGesture { index = offset; open(hits, onGitHub: false) }
                                }
                            }
                            .padding(8)
                        }
                        .frame(maxHeight: 380)
                        .onChange(of: index) { _, new in proxy.scrollTo(new) }
                    }
                }
                Hairline()
                HStack(spacing: 16) {
                    hint(["↩"], "Open")
                    hint(["⌘", "↩"], "Open on GitHub")
                    hint(["Esc"], "Close")
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .frame(width: 640)
            .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
            .padding(.top, 90)
        }
        // Key equivalents for the two presses a text field does not take itself.
        .background {
            Button("Close") { close() }.keyboardShortcut(.cancelAction).opacity(0)
            Button("Open on GitHub") { open(hits, onGitHub: true) }.keyboardShortcut(.return, modifiers: .command).opacity(0)
        }
        .onAppear { focused = true }
        .onChange(of: query) { index = 0 }
    }

    /// Screens and commands first, and only once something is typed; then the PRs, then your tickets, each ranked by
    /// how well it matches and, for PRs, most recently updated first among equals.
    private var hits: [Hit] {
        let typed = query.trimmingCharacters(in: .whitespaces)
        let open = model.state.github?.allOpen ?? []
        guard !typed.isEmpty else { return open.sorted { $0.updatedAt > $1.updatedAt }.map(Hit.pullRequest) }
        let pages = Self.ranked(Page.all) { FuzzyMatch.score($0.title, typed) }
        // `repo#number` and branch names are matched exactly; the title loosely.
        let prs = Self.ranked(open.sorted { $0.updatedAt > $1.updatedAt }) { pr in
            pr.matches(search: typed) ? 500 : FuzzyMatch.score(pr.title, typed)
        }
        let commands = Self.ranked(commands(for: prs.first)) { FuzzyMatch.score($0.title, typed) }
        let tickets = Self.ranked(model.state.openTickets) { FuzzyMatch.score("\($0.key) \($0.summary)", typed) }
        return pages.map(Hit.page) + commands.map(Hit.command) + prs.map(Hit.pullRequest) + tickets.map(Hit.ticket)
    }

    /// The items that match, best first; a stable sort, so equals keep the order they came in.
    private static func ranked<Item>(_ items: [Item], score: (Item) -> Int?) -> [Item] {
        items.enumerated()
            .compactMap { offset, item in score(item).map { (score: $0, offset: offset, item: item) } }
            .sorted { ($0.score, -$0.offset) > ($1.score, -$1.offset) }
            .map(\.item)
    }

    /// What the palette can run: syncing, each Settings pane, and the presses on the PR that matches best.
    private func commands(for pr: PullRequest?) -> [Command] {
        var commands = [Command(title: "Sync Now", keys: ["⌘", "R"]) { model.refreshAll() }]
        commands += SettingsPane.allCases.map { pane in
            Command(title: "Settings: \(pane.title)", keys: pane == .general ? ["⌘", ","] : []) { model.openSettings(pane) }
        }
        if let pr {
            let label = "\(pr.repoName)#\(pr.number)"
            if model.state.reviewNeed(for: pr) != nil, model.canReview(pr) {
                commands.append(Command(title: "Review \(label)") { model.review(pr) })
            }
            if let job = model.state.claudeJobs(for: pr).first {
                commands.append(Command(title: "Attach to the session on \(label)") { model.attach(job, for: pr) })
            }
        }
        return commands
    }

    @ViewBuilder private func row(_ hit: Hit, selected: Bool) -> some View {
        HStack(spacing: 12) {
            switch hit {
            case .page(let page):
                Chip(text: "Page", color: .blue).frame(width: 68, alignment: .leading)
                Text(page.title).lineLimit(1)
                Spacer(minLength: 8)
            case .command(let command):
                Chip(text: "Command", color: .purple).frame(width: 68, alignment: .leading)
                Text(command.title).lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 3) { ForEach(command.keys, id: \.self) { KeyCap(key: $0) } }
            case .ticket(let ticket):
                Chip(text: "Ticket", color: .orange).frame(width: 68, alignment: .leading)
                Text(ticket.summary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Text(ticket.key).scaled(.caption.monospaced()).foregroundStyle(.secondary)
            case .pullRequest(let pr):
                // A chip only for a draft: every result here is open, so "Open" on each said nothing.
                Group { if pr.isDraft { Chip(text: "Draft", color: .secondary) } }.frame(width: 68, alignment: .leading)
                Text(pr.title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Text(verbatim: "\(pr.repoName)#\(pr.number)").scaled(.caption.monospaced()).foregroundStyle(.secondary)
                ChecksBadge(pr: pr)
            }
            if selected { KeyCap(key: "↩") }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? Theme.rowSelected : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { KeyCap(key: $0) }
            Text(label).scaled(.caption).foregroundStyle(.secondary).padding(.leading, 2)
        }
    }

    private func move(_ step: Int, in hits: [Hit]) -> KeyPress.Result {
        guard !hits.isEmpty else { return .handled }
        index = min(max(index + step, 0), hits.count - 1)
        return .handled
    }

    private func open(_ hits: [Hit], onGitHub: Bool) {
        if hits.isEmpty, onGitHub, !query.isEmpty {
            searchGitHub()
            return
        }
        guard hits.indices.contains(index) else { return }
        switch hits[index] {
        case .page(let page):
            if let tab = page.tab { model.pendingTab = tab } else { model.showingSettings = true }
        case .command(let command):
            command.run()
        case .ticket(let ticket):
            // ⌘↩ has no GitHub to go to for a ticket, so both open it in Jira, where it is read and moved.
            model.open(ticket.url)
        case .pullRequest(let pr):
            let state = model.state
            if onGitHub {
                model.open(pr.url)
            } else if state.mine.contains(where: { $0.url == pr.url }) {
                model.selectPullRequest = pr.url
                model.pendingTab = .pullRequests
            } else if state.reviewQueue(.all).contains(where: { $0.url == pr.url }) {
                model.selectPullRequest = pr.url
                model.pendingTab = .reviews
            } else {
                // Open, but on no screen here — reviewed already, a bot's, or a draft: GitHub is where it is.
                model.open(pr.url)
            }
        }
        close()
    }

    private func close() { model.showingFinder = false }

    /// GitHub's own search over the org's pull requests, for a query nothing here matched.
    private func searchGitHub() {
        let terms = "\(query) org:\(model.config.githubOrg) is:pr"
        // `&`, `+`, `=` and `#` are legal in a query string but would end or change this one, so they are encoded too.
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=#"))
        let encoded = terms.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        model.open("https://github.com/search?type=pullrequests&q=\(encoded)")
        close()
    }
}
