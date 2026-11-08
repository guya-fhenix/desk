import AppKit
import DeskCore
import SwiftUI

/// A PR's diff as fetched, with each file's rows worked out once rather than on every redraw.
struct LoadedDiff {
    /// The head the PR had when it was fetched: `gh pr diff` does not say which commit it diffed.
    let sha: String
    let files: [DiffFile]
    let rows: [String: [DiffRow]]

    init(sha: String, files: [DiffFile]) {
        self.sha = sha
        self.files = files
        rows = Dictionary(files.map { ($0.path, $0.rows) }, uniquingKeysWith: { first, _ in first })
    }
}

/// Where a session's link asked the diff to go.
struct DiffJump: Equatable {
    var url: String
    var path: String
    var side: DiffSide
    var line: Int
}

struct DiffRowID: Hashable {
    var path: String
    /// The row's place in the file's rows; -1 is the file's header.
    var index: Int
}

/// The lines you picked in one file: a click, then a shift-click to extend.
struct DiffSelection: Equatable {
    var path: String
    var anchor: Int
    var end: Int
    var range: ClosedRange<Int> { min(anchor, end)...max(anchor, end) }
}

/// Reviewing a teammate's PR: its diff here, the review session in the terminal panel beside it. The code is only
/// read here; comments and the verdict are the session's to post, on your word.
struct ReviewDiffScreen: View {
    var pr: PullRequest
    var model: AppModel
    var onBack: () -> Void
    @State private var selection: DiffSelection?
    @State private var scrollTarget: DiffRowID?
    @State private var flash: DiffRowID?
    @State private var collapsed: Set<String> = []
    private let mono = Font.system(size: 12, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                BackLink(title: "\(pr.repoName)#\(pr.number)", action: onBack)
                Spacer(minLength: Theme.Space.m)
                Button("Ask Claude") { askClaude() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(selection == nil)
                    .help("Pastes the selected lines into the review session, for you to ask about. Click a line, shift-click to extend. ⌘↩")
                Button(model.reviewRunning(pr) ? "Review session" : "Start review") { model.startReview(pr) }
                    .help("The review session in the terminal panel")
                Button("Review on GitHub") { model.openDraft(pr) }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 6)
            VStack(alignment: .leading, spacing: 6) {
                Text(pr.title).scaled(.title3.weight(.semibold)).lineLimit(2)
                if let error = model.sessionErrors[pr.url] {
                    Text(error).scaled(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if let diff = model.diffs[pr.url], diff.sha != pr.headSha {
                    HStack(spacing: 8) {
                        Text("New commits since this diff was fetched.").scaled(.caption).foregroundStyle(.orange)
                        Button("Reload") { model.loadDiff(pr, force: true) }.controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, Theme.Space.m)
            Hairline()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .task(id: pr.url) { model.loadDiff(pr) }
    }

    @ViewBuilder private var content: some View {
        if let diff = model.diffs[pr.url] {
            HStack(spacing: 0) {
                fileList(diff)
                Rectangle().fill(Theme.line).frame(width: 1)
                rows(diff)
            }
        } else if let error = model.diffErrors[pr.url] {
            EmptyState(icon: "exclamationmark.triangle", text: "Couldn't load the diff.", detail: error,
                       actionTitle: "Retry", action: { model.loadDiff(pr, force: true) })
                .padding(.vertical, 20)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fileList(_ diff: LoadedDiff) -> some View {
        List(diff.files) { file in
            Button { scrollTarget = DiffRowID(path: file.path, index: -1) } label: {
                HStack(spacing: 6) {
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text("+\(file.additions) −\(file.deletions)").scaled(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help(file.path)
        }
        .listStyle(.sidebar)
        .frame(width: 230)
    }

    private func rows(_ diff: LoadedDiff) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // The file you are in stays pinned at the top while its rows scroll under it.
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(diff.files) { file in
                        Section {
                            if !collapsed.contains(file.path) {
                                let rows = diff.rows[file.path] ?? []
                                if file.isBinary {
                                    Text("Binary file").font(mono).foregroundStyle(.secondary).padding(8)
                                }
                                ForEach(rows.indices, id: \.self) { index in
                                    row(rows[index], id: DiffRowID(path: file.path, index: index))
                                }
                            }
                        } header: {
                            fileHeader(file)
                        }
                    }
                }
                .padding(.bottom, Theme.Space.xl)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                collapsed.remove(target.path)
                withAnimation { proxy.scrollTo(target, anchor: target.index < 0 ? .top : .center) }
                scrollTarget = nil
            }
            // A session's link: the line it named, or the nearest one the diff has, lit up for a moment.
            .onChange(of: model.diffJump, initial: true) { _, jump in
                guard let jump, jump.url == pr.url, let file = diff.files.first(where: { $0.path == jump.path }) else { return }
                let target = DiffRowID(path: file.path, index: file.row(nearest: jump.line, on: jump.side) ?? -1)
                scrollTarget = target
                flash = target
                model.diffJump = nil
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    if flash == target { flash = nil }
                }
            }
        }
    }

    private func fileHeader(_ file: DiffFile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: collapsed.contains(file.path) ? "chevron.right" : "chevron.down")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: 12)
            Text(file.previousPath.map { "\($0) → \(file.path)" } ?? file.path)
                .font(mono.weight(.semibold)).lineLimit(1).truncationMode(.head)
            Text(file.status == .modified ? "" : file.status.rawValue).scaled(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text("+\(file.additions)").foregroundStyle(.green)
            Text("−\(file.deletions)").foregroundStyle(.red)
        }
        .font(mono)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture {
            if collapsed.contains(file.path) { collapsed.remove(file.path) } else { collapsed.insert(file.path) }
        }
        .id(DiffRowID(path: file.path, index: -1))
    }

    @ViewBuilder private func row(_ row: DiffRow, id: DiffRowID) -> some View {
        switch row {
        case .hunk(let header):
            Text(header)
                .font(mono).foregroundStyle(.secondary).lineLimit(1)
                .padding(.vertical, 3).padding(.leading, 100)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08))
                .id(id)
        case .line(let line):
            HStack(alignment: .top, spacing: 0) {
                Text(line.oldLine.map(String.init) ?? "").frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
                Text(line.newLine.map(String.init) ?? "").frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
                Text(marker(line) + line.text).padding(.leading, 12)
            }
            .font(mono)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background(line, id))
            .contentShape(Rectangle())
            .onTapGesture { select(id, extend: NSEvent.modifierFlags.contains(.shift)) }
            .id(id)
        }
    }

    private func marker(_ line: DiffLine) -> String {
        switch line.kind {
        case .added: "+ "
        case .removed: "- "
        case .context: "  "
        }
    }

    private func background(_ line: DiffLine, _ id: DiffRowID) -> Color {
        if flash == id { return .yellow.opacity(0.4) }
        if let selection, selection.path == id.path, selection.range.contains(id.index) { return .accentColor.opacity(0.28) }
        switch line.kind {
        case .added: return .green.opacity(0.15)
        case .removed: return .red.opacity(0.15)
        case .context: return .clear
        }
    }

    private func select(_ id: DiffRowID, extend: Bool) {
        if extend, var selection, selection.path == id.path {
            selection.end = id.index
            self.selection = selection
        } else if selection == DiffSelection(path: id.path, anchor: id.index, end: id.index) {
            selection = nil
        } else {
            selection = DiffSelection(path: id.path, anchor: id.index, end: id.index)
        }
    }

    /// The selected lines, with their path and numbers, into the session's input — not sent.
    private func askClaude() {
        guard let selection, let rows = model.diffs[pr.url]?.rows[selection.path] else { return }
        let lines = selection.range.compactMap { index -> DiffLine? in
            if case .line(let line) = rows[index] { return line }
            return nil
        }
        guard let first = lines.first, let last = lines.last else { return }
        let number = { (line: DiffLine) in line.newLine ?? line.oldLine ?? 0 }
        let body = lines.map { marker($0) + $0.text }.joined(separator: "\n")
        model.askClaude(pr, "\(selection.path) lines \(number(first))–\(number(last)):\n```diff\n\(body)\n```\n")
    }
}
