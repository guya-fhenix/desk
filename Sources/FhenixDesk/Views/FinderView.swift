import DeskCore
import SwiftUI

/// Search (⌘K): one box over the dimmed window that finds any open PR the app knows of by `repo#number`, title or
/// branch, and any of your tickets by key or summary. ↩ opens it here — your own PR on Pull Requests, one in the review
/// queue on Reviews, a ticket on Jira — and a PR on none of those screens, marked so, on GitHub; ⌘↩ opens either on
/// GitHub or Jira.
struct FinderView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    /// One result: a pull request or a ticket.
    private enum Hit: Identifiable {
        case pullRequest(PullRequest)
        case ticket(Ticket)

        var id: String {
            switch self {
            case .pullRequest(let pr): return pr.url
            case .ticket(let ticket): return "ticket:\(ticket.key)"
            }
        }
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
                    TextField("PR, review, ticket, or #", text: $query)
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
                    hint(["⌘", "↩"], "Open on GitHub or Jira")
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

    /// The PRs, then your tickets, each ranked by how well it matches and, for PRs, most recently updated first among
    /// equals. With nothing typed, every open PR.
    private var hits: [Hit] {
        let typed = query.trimmingCharacters(in: .whitespaces)
        let open = (model.state.github?.allOpen ?? []).sorted { $0.updatedAt > $1.updatedAt }
        guard !typed.isEmpty else { return open.map(Hit.pullRequest) }
        // `repo#number` and branch names are matched exactly; the title loosely.
        let prs = Self.ranked(open) { pr in pr.matches(search: typed) ? 500 : FuzzyMatch.score(pr.title, typed) }
        let tickets = Self.ranked(model.state.openTickets) { FuzzyMatch.score("\($0.key) \($0.summary)", typed) }
        return prs.map(Hit.pullRequest) + tickets.map(Hit.ticket)
    }

    /// The items that match, best first; a stable sort, so equals keep the order they came in.
    private static func ranked<Item>(_ items: [Item], score: (Item) -> Int?) -> [Item] {
        items.enumerated()
            .compactMap { offset, item in score(item).map { (score: $0, offset: offset, item: item) } }
            .sorted { ($0.score, -$0.offset) > ($1.score, -$1.offset) }
            .map(\.item)
    }

    @ViewBuilder private func row(_ hit: Hit, selected: Bool) -> some View {
        HStack(spacing: 12) {
            switch hit {
            case .ticket(let ticket):
                Chip(text: "Ticket", color: .orange).frame(width: 68, alignment: .leading)
                Text(ticket.summary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Text(ticket.key).scaled(.caption.monospaced()).foregroundStyle(.secondary)
            case .pullRequest(let pr):
                // Which screen it opens on: yours on Pull Requests, the review queue's on Reviews, any other on GitHub.
                let screen = screen(of: pr)
                Chip(text: screen == .reviews ? "Review" : "PR", color: screen == .reviews ? .green : .teal).frame(width: 68, alignment: .leading)
                Text(pr.title).lineLimit(1).truncationMode(.tail)
                if pr.isDraft { Chip(text: "Draft", color: .secondary).fixedSize() }
                Spacer(minLength: 8)
                if screen == nil {
                    Label("Opens on GitHub", systemImage: "arrow.up.right.square")
                        .scaled(.caption).foregroundStyle(.secondary).fixedSize()
                        .help("On none of the app's screens — reviewed already, a bot's, or someone's draft — so ↩ opens it on GitHub")
                }
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
        case .ticket(let ticket):
            if onGitHub {
                model.open(ticket.url)
            } else {
                model.selectTicket = ticket.key
                model.pendingTab = .tickets
            }
        case .pullRequest(let pr):
            if let screen = screen(of: pr), !onGitHub {
                model.selectPullRequest = pr.url
                model.pendingTab = screen
            } else {
                model.open(pr.url)
            }
        }
        close()
    }

    private func close() { model.showingFinder = false }

    /// The screen a PR has a page on: yours on Pull Requests, the review queue's on Reviews; nil for any other.
    private func screen(of pr: PullRequest) -> DeskWindow.Tab? {
        if model.state.mine.contains(where: { $0.url == pr.url }) { return .pullRequests }
        if model.state.reviewQueue(.all).contains(where: { $0.url == pr.url }) { return .reviews }
        return nil
    }

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
