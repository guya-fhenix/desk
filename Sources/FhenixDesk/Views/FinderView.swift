import DeskCore
import SwiftUI

/// Search (⌘K): one box over the dimmed window that finds any open PR the app knows of by `repo#number`, title or
/// branch, any of your tickets by key or summary, and the app's commands by name, each kind under its own label. ↩ opens
/// it here — your own PR on Tasks, one in the review queue on Reviews, a ticket on Jira — and a PR on none of those
/// screens, marked so, on GitHub; ⌘↩ opens either in the browser, on GitHub or Jira. A command runs on either.
struct FinderView: View {
    @Environment(AppModel.self) private var model
    @State private var query = FinderView.initialQuery
    /// What the palette opens with: empty, but for a snapshot of it (`--snapshot window … finder=<query>`).
    nonisolated(unsafe) static var initialQuery = ""
    @State private var index = 0
    @State private var resultsHeight: CGFloat = 0
    @FocusState private var focused: Bool

    /// One result: a task, a ticket, a pull request, a session, or a command.
    private enum Hit: Identifiable {
        case task(WorkTask)
        case ticket(Ticket)
        case pullRequest(PullRequest)
        case session(ClaudeJob)
        case command(Command)

        var id: String {
            switch self {
            case .task(let task): return "task:\(task.id)"
            case .ticket(let ticket): return "ticket:\(ticket.key)"
            case .pullRequest(let pr): return pr.url
            case .session(let job): return "session:\(job.id)"
            case .command(let command): return "command:\(command.title)"
            }
        }

        /// The label its group goes under.
        var group: String {
            switch self {
            case .task: return "Tasks"
            case .ticket: return "Jira"
            case .pullRequest: return "Pull requests"
            case .session: return "Sessions"
            case .command: return "Commands"
            }
        }
    }

    /// Something to do rather than open: its name, its mark, the key that does it outside Search, and what it does.
    private struct Command {
        var title: String
        var icon: String
        var key: String
        var run: @MainActor (AppModel) -> Void
    }

    private static let commands = [
        Command(title: "Open master in iTerm", icon: "bubble.left.and.bubble.right", key: "⇧⌘M") { $0.openMaster() },
        // On the Master screen, where it asks before it acts: a restart is never one keypress away.
        Command(title: "Restart master…", icon: "arrow.triangle.2.circlepath", key: "") {
            $0.showMasterScreen()
            $0.confirmingMasterRestart = true
        },
        Command(title: "Sync now", icon: "arrow.clockwise", key: "⌘R") { $0.refreshAll() },
        Command(title: "Settings", icon: "gearshape", key: "⌘,") { $0.showingSettings = true },
    ]

    var body: some View {
        let hits = self.hits
        ZStack(alignment: .top) {
            Theme.scrim
                .ignoresSafeArea()
                .onTapGesture { close() }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.quiet)
                    TextField("Task, PR, ticket, session, command, or #", text: $query)
                        .textFieldStyle(.plain)
                        .scaled(AppTextStyle(size: 16))
                        .focused($focused)
                        .onSubmit { open(hits, inBrowser: false) }
                        .onKeyPress(.downArrow) { move(1, in: hits) }
                        .onKeyPress(.upArrow) { move(-1, in: hits) }
                        .accessibilityLabel("Search tasks, tickets, pull requests, sessions and commands")
                    Button(action: close) { InstrumentKey(key: "esc") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close search")
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.ruleSoft).frame(height: 1) }
                if hits.isEmpty {
                    // Not a dead end: what the app does not know of, GitHub may.
                    VStack(alignment: .leading, spacing: 8) {
                        Text(query.isEmpty ? "No open pull requests yet." : "Nothing here matches.")
                            .scaled(.secondary).foregroundStyle(Theme.quiet)
                        if !query.isEmpty {
                            HStack(spacing: 4) {
                                InstrumentKey(key: "⌘↩")
                                Text("Search GitHub for “\(query)”").scaled(.secondary).foregroundStyle(Theme.quiet).padding(.leading, 2)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            results(hits).onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resultsHeight = $0 }
                        }
                        // As tall as the results, up to a point; past it they scroll.
                        .frame(height: min(resultsHeight, 460))
                        .onChange(of: index) { _, new in proxy.scrollTo(new) }
                    }
                }
                KeyHints(hints: [(["↑", "↓"], "move"), (["↩"], "open"), (["⌘↩"], "open in browser"), (["esc"], "close")])
                    .padding(.bottom, 10)
                    .background(Theme.ground)
            }
            .scaledFrame(width: 640)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.ruleStrong))
            .shadow(color: .black.opacity(0.18), radius: 20, y: 12)
            .padding(.top, 96)
            .accessibilityAddTraits(.isModal)
        }
        // Key equivalents for the two presses a text field does not take itself.
        .background {
            Button("Close") { close() }.keyboardShortcut(.cancelAction).opacity(0)
            Button("Open in browser") { open(hits, inBrowser: true) }.keyboardShortcut(.return, modifiers: .command).opacity(0)
        }
        .onAppear { focused = true }
        .onChange(of: query) { index = 0 }
    }

    /// As the board orders them: your tasks, your tickets, the PRs, the sessions, each ranked by how well it matches and,
    /// for PRs, most recently updated first among equals; then the commands, the ones whose name matches first. With
    /// nothing typed, every open PR and every command.
    private var hits: [Hit] {
        let typed = query.trimmingCharacters(in: .whitespaces)
        let open = (model.state.github?.allOpen ?? []).sorted { $0.updatedAt > $1.updatedAt }
        guard !typed.isEmpty else { return open.map(Hit.pullRequest) + Self.commands.map(Hit.command) }
        // `repo#number` and branch names are matched exactly; the title loosely.
        let prs = Self.ranked(open) { pr in pr.matches(search: typed) ? 500 : FuzzyMatch.score(pr.title, typed) }
        let tickets = Self.ranked(model.state.openTickets) { FuzzyMatch.score("\($0.key) \($0.summary)", typed) }
        let tasks = Self.ranked(model.state.tasks) { FuzzyMatch.score("\($0.id) \($0.title)", typed) }
        let sessions = Self.ranked(model.state.claudeJobs) { FuzzyMatch.score("\($0.name) \($0.request ?? "")", typed) }
        let matched = Self.ranked(Self.commands) { FuzzyMatch.score($0.title, typed) }
        let commands = matched + Self.commands.filter { command in !matched.contains { $0.title == command.title } }
        return tasks.map(Hit.task) + tickets.map(Hit.ticket) + prs.map(Hit.pullRequest) + sessions.map(Hit.session)
            + commands.map(Hit.command)
    }

    /// The items that match, best first; a stable sort, so equals keep the order they came in.
    private static func ranked<Item>(_ items: [Item], score: (Item) -> Int?) -> [Item] {
        items.enumerated()
            .compactMap { offset, item in score(item).map { (score: $0, offset: offset, item: item) } }
            .sorted { ($0.score, -$0.offset) > ($1.score, -$1.offset) }
            .map(\.item)
    }

    /// The results, each kind under its label.
    private func results(_ hits: [Hit]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(hits.enumerated()), id: \.element.id) { offset, hit in
                if offset == 0 || hits[offset - 1].group != hit.group {
                    SectionLabel(hit.group).padding(EdgeInsets(top: offset == 0 ? 8 : 10, leading: 8, bottom: 4, trailing: 8))
                }
                row(hit, selected: offset == index)
                    .id(offset)
                    .onTapGesture { index = offset; open(hits, inBrowser: false) }
            }
        }
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 8, trailing: 8))
    }

    /// A result as the board draws it: a DM Mono name in a column of its own, or a command's mark, then the title, and
    /// on the right where it stands; tinted, with ↩, while selected.
    @ViewBuilder private func row(_ hit: Hit, selected: Bool) -> some View {
        HStack(spacing: 10) {
            switch hit {
            case .task(let task):
                name(TaskHeader.label(task))
                Text(task.title).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                facts(
                    TaskHeader.chip(task), tone: TaskHeader.chipTone(task) ?? Theme.quiet,
                    " · \(task.pullRequests.count) pull request\(task.pullRequests.count == 1 ? "" : "s")"
                )
            case .session(let job):
                // Which session it is and what it was started on, never what it is doing: that is in `claude agents`.
                name(job.name)
                Text(job.request ?? job.ticketKey ?? "").lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                facts(job.role == .other ? "session" : job.role.rawValue)
            case .ticket(let ticket):
                name(ticket.key)
                Text(ticket.summary).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                facts([ticket.status, ticket.priority].compactMap { $0 }.joined(separator: " · "))
            case .pullRequest(let pr):
                // Which screen it opens on: yours on Tasks, the review queue's on Reviews, any other on GitHub.
                let screen = screen(of: pr)
                name("\(pr.repoName) #\(pr.number)")
                Text(pr.title).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                ChecksBadge(pr: pr).scaled(.secondary)
                facts(([pr.isDraft ? "Draft" : nil, screen == .reviews ? "Review" : screen == nil ? "On GitHub" : nil].compactMap { $0 }
                    + [UpNextTab.checks(pr)]).joined(separator: " · "))
                    .help(screen == nil ? "On none of the app's screens — reviewed already, a bot's, or someone's draft — so ↩ opens it on GitHub" : "")
            case .command(let command):
                Image(systemName: command.icon).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.quiet).frame(width: 18)
                Text(command.title).frame(maxWidth: .infinity, alignment: .leading)
                Text(command.key).scaled(.caption.monospaced()).foregroundStyle(Theme.quiet)
            }
            if selected { InstrumentKey(key: "↩") }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 36)
        .background(selected ? Theme.tint : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .overlay { if selected { RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.tintLine) } }
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func name(_ text: String) -> some View {
        Text(text).scaled(.code).foregroundStyle(Theme.quiet).lineLimit(1).scaledFrame(width: 150, alignment: .leading)
    }

    private func facts(_ text: String) -> some View {
        Text(text).scaled(.secondary).foregroundStyle(Theme.quiet).lineLimit(1).fixedSize()
    }

    /// Where it stands in its colour, then the rest quiet: "waits on you · 1 pull request".
    private func facts(_ lead: String, tone: Color, _ rest: String) -> some View {
        Text("\(Text(lead).foregroundStyle(tone))\(rest)").scaled(.secondary).foregroundStyle(Theme.quiet).lineLimit(1).fixedSize()
    }

    private func move(_ step: Int, in hits: [Hit]) -> KeyPress.Result {
        guard !hits.isEmpty else { return .handled }
        index = min(max(index + step, 0), hits.count - 1)
        return .handled
    }

    private func open(_ hits: [Hit], inBrowser: Bool) {
        if hits.isEmpty, inBrowser, !query.isEmpty {
            searchGitHub()
            return
        }
        guard hits.indices.contains(index) else { return }
        switch hits[index] {
        case .task(let task):
            if inBrowser, let ticket = model.state.ticket(task.id) {
                model.open(ticket.url)
            } else {
                // The Tasks screen selects a task from its id, or opens its PR's page when the task is a PR.
                model.selectPullRequest = task.id
                model.pendingTab = .pullRequests
            }
        case .session(let job):
            model.show(jobId: job.id)
        case .ticket(let ticket):
            if inBrowser {
                model.open(ticket.url)
            } else {
                model.selectTicket = ticket.key
                model.pendingTab = .tickets
            }
        case .pullRequest(let pr):
            if let screen = screen(of: pr), !inBrowser {
                model.selectPullRequest = pr.url
                model.pendingTab = screen
            } else {
                model.open(pr.url)
            }
        case .command(let command):
            command.run(model)
        }
        close()
    }

    private func close() { model.showingFinder = false }

    /// The screen a PR has a page on: yours on Tasks, the review queue's on Reviews; nil for any other.
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
