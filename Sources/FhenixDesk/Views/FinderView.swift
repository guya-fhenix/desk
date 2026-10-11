import DeskCore
import SwiftUI

/// Search (⌘K): one box over the dimmed window that finds any open PR the app knows of by `repo#number`,
/// title or branch, and any screen by name. ↩ opens it here — your own PR in Pull Requests, one in the review
/// queue in Reviews, anything else on GitHub — and ⌘↩ opens it on GitHub.
struct FinderView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    /// One result: a screen to go to, or a pull request.
    private enum Hit: Identifiable {
        case page(Page)
        case pullRequest(PullRequest)

        var id: String {
            switch self {
            case .page(let page): return "page:\(page.title)"
            case .pullRequest(let pr): return pr.url
            }
        }
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
                    TextField("PR, page, branch, or #", text: $query)
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
                    Text(query.isEmpty ? "No open pull requests yet." : "No PR or page matches.")
                        .scaled(.callout).foregroundStyle(.secondary)
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
                    hint(["↩"], "open")
                    hint(["⌘", "↩"], "github")
                    hint(["Esc"], "close")
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

    /// Screens first, and only once something is typed; then the PRs, most recently updated first.
    private var hits: [Hit] {
        let typed = query.trimmingCharacters(in: .whitespaces)
        let pages = typed.isEmpty ? [] : Page.all.filter { $0.title.lowercased().contains(typed.lowercased()) }
        let prs = (model.state.github?.allOpen ?? [])
            .filter { $0.matches(search: typed) }
            .sorted { $0.updatedAt > $1.updatedAt }
        return pages.map(Hit.page) + prs.map(Hit.pullRequest)
    }

    @ViewBuilder private func row(_ hit: Hit, selected: Bool) -> some View {
        HStack(spacing: 12) {
            switch hit {
            case .page(let page):
                Chip(text: "page", color: .blue).frame(width: 52, alignment: .leading)
                Text(page.title).lineLimit(1)
                Spacer(minLength: 8)
            case .pullRequest(let pr):
                Chip(text: pr.isDraft ? "draft" : "open", color: pr.isDraft ? .secondary : .green).frame(width: 52, alignment: .leading)
                Text(pr.title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Text("\(pr.repoName)#\(pr.number)").scaled(.caption.monospaced()).foregroundStyle(.secondary)
                StatusDot(color: checksColor(pr)).help("CI: \(pr.checks.rawValue.lowercased())")
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

    private func checksColor(_ pr: PullRequest) -> Color {
        if pr.checks.isRed { return .red }
        if pr.checks.isPending { return .orange }
        return pr.checks == .success ? .green : .gray
    }

    private func move(_ step: Int, in hits: [Hit]) -> KeyPress.Result {
        guard !hits.isEmpty else { return .handled }
        index = min(max(index + step, 0), hits.count - 1)
        return .handled
    }

    private func open(_ hits: [Hit], onGitHub: Bool) {
        guard hits.indices.contains(index) else { return }
        switch hits[index] {
        case .page(let page):
            if let tab = page.tab { model.pendingTab = tab } else { model.showingSettings = true }
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
}
