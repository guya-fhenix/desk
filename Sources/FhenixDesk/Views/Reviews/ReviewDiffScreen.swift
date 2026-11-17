import AppKit
import DeskCore
import SwiftUI

/// A PR's diff as fetched, with each file's rows worked out once rather than on every redraw.
struct LoadedDiff {
    /// The head the PR had when it was fetched: `gh pr diff` does not say which commit it diffed.
    let sha: String
    let files: [DiffFile]
    let rows: [String: [DiffRow]]
    /// The files too large to open on their own: folded until you unfold them.
    let foldedAtFirst: Set<String>

    init(sha: String, files: [DiffFile]) {
        self.sha = sha
        self.files = files
        foldedAtFirst = files.foldedAtFirst()
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

/// Reviewing a teammate's PR, or a group of them: across the top what they are, your pending comments and the press
/// that takes you to GitHub to submit; then the group's parts down a column, this one's diff in file cards with each
/// review thread under the line it ends on, to reply to or resolve, and on the right the review session, which runs in
/// its own pane in iTerm, where you talk to it. The window's sidebar folds away while it shows, so the code has the room.
struct ReviewDiffScreen: View {
    var pr: PullRequest
    var model: AppModel
    var onBack: () -> Void
    @State private var selection: DiffSelection?
    @State private var scrollTarget: DiffRowID?
    @State private var flash: DiffRowID?
    /// The files whose fold you changed from how the diff opened: a large file opens folded, the rest unfolded.
    @State private var flipped: Set<String> = []
    /// The files whose header is pinned at the top of the scroll, or being pushed off it by the next: the last of them is
    /// the file you are in.
    @State private var atTop: Set<String> = []
    /// The diff has the keyboard, for its line cursor.
    @FocusState private var focused: Bool
    @Environment(\.reviewRoom) private var reviewRoom
    @Environment(\.textScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mono: Font { DiffType(scale: scale).mono }

    var body: some View {
        let parts = model.reviewGroup(for: pr)?.pullRequests ?? [pr]
        VStack(alignment: .leading, spacing: 0) {
            header(parts)
            HStack(spacing: 0) {
                partsColumn(parts)
                VStack(alignment: .leading, spacing: 0) {
                    partHead(titled: parts.count > 1)
                    content
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                ReviewSessionPanel(pr: pr, parts: parts, model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.ground)
        .task(id: pr.url) { model.loadDiff(pr) }
        #if DEBUG
        .task { snapshotGroup() }
        #endif
        .task(id: "\(pr.url) \(pr.updatedAt)") { await model.loadConversation(pr) }
        .onAppear { reviewRoom(true) }
        .onDisappear { reviewRoom(false) }
    }

    /// "‹ cofhe-contracts #175 / Jr-kenny · cofhe-contracts · stack of 3", the group's title and its PRs in DM Mono; on
    /// the right, your pending comments, Copy lines and the way to GitHub to submit.
    private func header(_ parts: [PullRequest]) -> some View {
        // Several PRs read as their task when they are one — a stack, a ticket's — or as how many they are.
        let tasks = parts.count > 1 ? ReviewsTab.groups(parts, model: model) : []
        let task = tasks.count == 1 ? tasks.first : nil
        let title = parts.count == 1 ? pr.title : task?.task.title ?? "\(parts.count) pull requests together"
        let context = parts.count == 1 ? pr.author : task.map { "\($0.authors) · \($0.what)" } ?? "reviewed together"
        let drafts = parts.compactMap(\.pendingReview)
        let comments = drafts.map(\.comments).reduce(0, +)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Button(action: onBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                            Text(verbatim: "\(pr.repoName) #\(pr.number)")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).handCursor()
                    .help("Back to its page")
                    Text("/ \(context)").lineLimit(1)
                }
                .scaled(.secondary).foregroundStyle(Theme.quiet)
                Text(title).scaled(.title).tracking(-0.2).lineLimit(1)
                Text(numbers(parts)).scaled(.code).foregroundStyle(Theme.quiet).lineLimit(1)
            }
            Spacer(minLength: 12)
            if !drafts.isEmpty {
                Text("Pending: \(comments) comment\(comments == 1 ? "" : "s") on \(drafts.count) PR\(drafts.count == 1 ? "" : "s")")
                    .scaled(.secondary).foregroundStyle(Theme.quiet).fixedSize()
            }
            Button("Copy lines") { copyLines() }
                .buttonStyle(.desk)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(selection == nil)
                .help("Copies the selected lines with their path and numbers, to paste into the review session's pane in iTerm. Click a line, shift-click to extend, or move with ↑↓ and extend with ⇧↑↓. ⇧⌘C")
            Button(pr.pendingReview != nil ? "Submit on GitHub" : "Review on GitHub") { model.openDraft(pr) }
                .buttonStyle(.deskPrimary)
                .help("The PR's Files tab on GitHub: your pending review's comments, and Approve, Request changes or Comment to submit")
        }
        .padding(EdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
    }

    /// "cofhe-contracts #175 · #177 · #179": the parts, repo by repo; one PR alone, which the back link names, its branches.
    private func numbers(_ parts: [PullRequest]) -> String {
        guard parts.count > 1 else { return "\(pr.baseRef) ← \(pr.headRef)" }
        var repos: [String] = []
        for part in parts where !repos.contains(part.repoName) { repos.append(part.repoName) }
        return repos.map { repo in
            "\(repo) " + parts.filter { $0.repoName == repo }.map { "#\($0.number)" }.joined(separator: " · ")
        }.joined(separator: " · ")
    }

    /// The PRs reviewed together, repo by repo and each stack base first, this one tinted, with your pending comments and
    /// its open threads: a click shows that one's diff, as the session's links do.
    private func partsColumn(_ parts: [PullRequest]) -> some View {
        let repos = Set(parts.map(\.repo)).count
        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Parts", count: parts.count).padding(EdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8))
            ScrollView {
                let depths = Linker.depths(parts, parents: model.state.stackParents)
                VStack(spacing: 2) {
                    ForEach(parts, id: \.url) { part in partRow(part, depth: depths[part.url] ?? 0, showsRepo: repos > 1) }
                }
            }
            Text("On GitHub you pick Approve, Request changes or Comment for each pull request, and submit.")
                .scaled(.secondary).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 12, leading: 8, bottom: 0, trailing: 8))
        }
        .padding(EdgeInsets(top: 16, leading: 12, bottom: 16, trailing: 12))
        .scaledFrame(width: 232)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.rule).frame(width: 1) }
    }

    private func partRow(_ part: PullRequest, depth: Int, showsRepo: Bool) -> some View {
        let current = part.url == pr.url
        let drafted = part.pendingReview?.comments ?? 0
        let threads = part.unresolvedThreads
        let facts = [
            showsRepo ? part.repoName : nil,
            threads > 0 ? "\(threads) open thread\(threads == 1 ? "" : "s")" : nil,
            "\(Format.sizeBucket(part.size)) +\(part.additions) −\(part.deletions)",
        ].compactMap { $0 }.joined(separator: " · ")
        return Button { if !current { model.showInReview(part) } } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    StackRef(pr: part, depth: depth, name: "#\(part.number)").scaled(.code).foregroundStyle(Theme.quiet)
                        .frame(minWidth: 38, alignment: .leading)
                    Text(part.title).fontWeight(current ? .semibold : .regular)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    if drafted > 0 {
                        Circle().fill(Theme.warn).frame(width: 6, height: 6)
                        Text("\(drafted) drafted ·").foregroundStyle(Theme.ink)
                    }
                    Text(facts)
                }
                .scaled(.secondary).foregroundStyle(Theme.quiet)
                .padding(.leading, 44)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(current ? Theme.tint : .clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay { if current { RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.tintLine) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? .isSelected : [])
        .help(current ? part.title : "Show \(part.repoName) #\(part.number)'s diff")
    }

    /// Over the diff: this part's number and title — in a group; one PR alone has its title over the page — with the file
    /// jump beside them, who wrote it, your notes for the review, and what went wrong or moved since the diff was fetched.
    private func partHead(titled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                if titled {
                    Text(verbatim: "#\(pr.number) · \(pr.title)").scaled(.headline).lineLimit(2)
                } else {
                    Text("By \(pr.author) · \(Format.sizeBucket(pr.size)) +\(pr.additions) −\(pr.deletions)").foregroundStyle(Theme.quiet)
                }
                Spacer(minLength: 0)
                if let diff = model.diffs[pr.url], !diff.files.isEmpty { jumpMenu(diff).frame(maxWidth: 340) }
            }
            if titled { Text("\(pr.author) · \(pr.baseRef) ← \(pr.headRef)").foregroundStyle(Theme.quiet).lineLimit(1) }
            if let notes = model.reviewGroup(for: pr)?.notes, !notes.isEmpty {
                Text("Your notes: \(notes)")
                    .scaled(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
            }
            if let error = model.sessionErrors[pr.url] {
                Text(error).scaled(.secondary).foregroundStyle(Theme.danger).textSelection(.enabled)
            }
            if let diff = model.diffs[pr.url], diff.sha != pr.headSha {
                HStack(spacing: 8) {
                    Text("New commits since this diff was fetched.").scaled(.secondary).foregroundStyle(Theme.warn)
                    Button("Reload") { model.loadDiff(pr, force: true) }.buttonStyle(.desk(.secondary, .small))
                }
            }
        }
        .padding(EdgeInsets(top: 20, leading: 24, bottom: 14, trailing: 24))
    }

    @ViewBuilder private var content: some View {
        if let diff = model.diffs[pr.url] {
            rows(diff)
        } else if let error = model.diffErrors[pr.url] {
            EmptyState(icon: "exclamationmark.triangle", text: "Couldn't load the diff.", detail: error,
                       actionTitle: "Retry", action: { model.loadDiff(pr, force: true) })
                .padding(.vertical, 20)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func folded(_ path: String, in diff: LoadedDiff) -> Bool { diff.foldedAtFirst.contains(path) != flipped.contains(path) }

    /// The file at the top of the scroll.
    private func topFile(_ diff: LoadedDiff) -> Int { diff.files.lastIndex { atTop.contains($0.path) } ?? 0 }

    /// "File 2 of 4 · contracts/ACL.sol ▾": the file at the top of the scroll, and every file with its +/− counts, that
    /// one ticked, each scrolling to its header.
    private func jumpMenu(_ diff: LoadedDiff) -> some View {
        let current = topFile(diff)
        return Menu {
            ForEach(diff.files) { file in
                Toggle(isOn: Binding(get: { file.path == diff.files[current].path }, set: { _ in
                    scrollTarget = DiffRowID(path: file.path, index: -1)
                })) {
                    Text(file.path)
                    Text("+\(file.additions) −\(file.deletions)")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("File \(current + 1) of \(diff.files.count)").foregroundStyle(Theme.quiet).fixedSize()
                Text(diff.files[current].path).lineLimit(1).truncationMode(.head)
                Image(systemName: "chevron.down").scaled(.caption).foregroundStyle(Theme.quiet)
            }
            .menuBox()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(diff.files[current].path)
    }

    private func rows(_ diff: LoadedDiff) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A card per file, drawn a row at a time so the stack stays lazy; the file you are in keeps its header
                // pinned at the top while its rows scroll under it.
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(diff.files) { file in
                        Section {
                            if !folded(file.path, in: diff) {
                                let rows = diff.rows[file.path] ?? []
                                if file.isBinary {
                                    Text("Binary file").font(mono).foregroundStyle(Theme.quiet).padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .reviewBox(.middle, fill: Theme.surface, line: Theme.rule)
                                }
                                ForEach(rows.indices, id: \.self) { index in
                                    row(rows[index], id: DiffRowID(path: file.path, index: index))
                                        .reviewBox(.middle, fill: Theme.surface, line: Theme.rule)
                                    if case .line(let line) = rows[index] {
                                        threads(under: line, in: file.path).reviewBox(.middle, fill: Theme.surface, line: Theme.rule)
                                    }
                                }
                            }
                        } header: {
                            fileHeader(file, folded: folded(file.path, in: diff), large: diff.foldedAtFirst.contains(file.path))
                        } footer: {
                            Color.clear.frame(height: 6).reviewBox(.bottom, fill: Theme.surface, line: Theme.rule).padding(.bottom, 16)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, Theme.Space.xl)
            }
            // ↑ and ↓ move the line cursor, the selection's one line; with ⇧ they stretch the selection. Not while a reply is
            // being typed under a line: there the arrows move the caret, and this handler would run first.
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                let step = press.key == .downArrow ? 1 : -1
                guard !(NSApp.keyWindow?.firstResponder is NSText),
                      let next = moved(step, extend: press.modifiers.contains(.shift), in: diff) else { return .ignored }
                selection = next
                // A line or two of what is above it comes into view too, so going up it is not left under the pinned header.
                let lead = DiffRowID(path: next.path, index: step < 0 ? max(next.end - 2, -1) : next.end)
                withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(lead) }
                return .handled
            }
            .task {
                // A turn of the run loop later, as a page's focus is: asked for while the screen is still being put up, it
                // is dropped.
                await Task.yield()
                focused = true
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                let unfolding = folded(target.path, in: diff)
                if unfolding { flipped.formSymmetricDifference([target.path]) }
                scrollTarget = nil
                Task {
                    // A file unfolded this moment has no rows to scroll to until the stack has drawn them.
                    if unfolding { try? await Task.sleep(for: .milliseconds(100)) }
                    withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(target, anchor: target.index < 0 ? .top : .center) }
                }
            }
            // A session's link, or a thread picked in the session panel: the line it named, or the nearest one the diff
            // has, lit up for a moment.
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

    private func fileHeader(_ file: DiffFile, folded: Bool, large: Bool) -> some View {
        DiffFileHeader(file: file, folded: folded, large: large) {
            flipped.formSymmetricDifference([file.path])
        }
        .reviewBox(.top, fill: Theme.surface, line: Theme.rule)
        // Pinned, it sits at the scroll's top edge; the next file's header pushes it off. One gone from the lazy stack is
        // out of the running: the file on top always has its header on screen.
        .onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).minY <= 1 } action: { onTop in
            if onTop { atTop.insert(file.path) } else { atTop.remove(file.path) }
        }
        .onDisappear { atTop.remove(file.path) }
        .id(DiffRowID(path: file.path, index: -1))
    }

    @ViewBuilder private func row(_ row: DiffRow, id: DiffRowID) -> some View {
        switch row {
        case .hunk(let header):
            DiffHunkRow(header: header).id(id)
        case .line(let line):
            DiffLineRow(line: line, highlight: highlight(id))
                .contentShape(Rectangle())
                .onTapGesture { select(id, extend: NSEvent.modifierFlags.contains(.shift)) }
                .id(id)
        }
    }

    private func threads(under line: DiffLine, in path: String) -> some View {
        DiffThreads(line: line, path: path, pr: pr, model: model)
    }

    /// A session's link lights a line up for a moment; the selection tints its lines.
    private func highlight(_ id: DiffRowID) -> Color? {
        if flash == id { return Theme.warn.opacity(0.3) }
        if let selection, selection.path == id.path, selection.range.contains(id.index) { return Theme.tintLine }
        return nil
    }

    /// The selection after ↑ or ↓: the cursor a line on, into the next open file past the last line, or from the file on
    /// top when there is none yet; with ⇧, the selection stretched a line, within its file. Nil when it would go nowhere.
    private func moved(_ step: Int, extend: Bool, in diff: LoadedDiff) -> DiffSelection? {
        let open = diff.files.map(\.path).filter { !folded($0, in: diff) }
        let line = { (path: String) in diff.rows[path]?.lineIndex(after: nil, step: step).map { DiffSelection(path: path, anchor: $0, end: $0) } }
        guard let selection, let at = open.firstIndex(of: selection.path) else {
            return open.drop { $0 != diff.files[topFile(diff)].path }.lazy.compactMap(line).first ?? open.lazy.compactMap(line).first
        }
        if let index = diff.rows[selection.path]?.lineIndex(after: selection.end, step: step) {
            return DiffSelection(path: selection.path, anchor: extend ? selection.anchor : index, end: index)
        }
        guard !extend else { return nil }
        return (step > 0 ? Array(open[(at + 1)...]) : open[..<at].reversed()).lazy.compactMap(line).first
    }

    private func select(_ id: DiffRowID, extend: Bool) {
        focused = true
        if extend, var selection, selection.path == id.path {
            selection.end = id.index
            self.selection = selection
        } else if selection == DiffSelection(path: id.path, anchor: id.index, end: id.index) {
            selection = nil
        } else {
            selection = DiffSelection(path: id.path, anchor: id.index, end: id.index)
        }
    }

    /// The selected lines, with their path and numbers, on the clipboard: Desk sends nothing to a session, you paste them.
    private func copyLines() {
        guard let selection, let rows = model.diffs[pr.url]?.rows[selection.path] else { return }
        let lines = selection.range.compactMap { index -> DiffLine? in
            if case .line(let line) = rows[index] { return line }
            return nil
        }
        guard let first = lines.first, let last = lines.last else { return }
        let number = { (line: DiffLine) in line.newLine ?? line.oldLine ?? 0 }
        let body = lines.map { $0.marker + $0.text }.joined(separator: "\n")
        Clipboard.copy("\(pr.repoName)#\(pr.number) \(selection.path) lines \(number(first))–\(number(last)):\n```diff\n\(body)\n```\n")
    }

    #if DEBUG
    /// `FHENIX_DESK_REVIEWS_SNAPSHOT=group`, for `--snapshot <pr url> … diff`: the PR's queue group as a review group with
    /// notes, as Review together leaves it, without starting a session.
    private func snapshotGroup() {
        guard ProcessInfo.processInfo.environment["FHENIX_DESK_REVIEWS_SNAPSHOT"] == "group", model.reviewGroup(for: pr) == nil,
              let group = ReviewsTab.groups(model.state.reviewQueue(.all), model: model).first(where: { $0.pullRequests.contains { $0.url == pr.url } })
        else { return }
        model.reviewGroups = [ReviewGroup(pullRequests: group.pullRequests, notes: "Check the decoder's bounds; skip style.")]
    }
    #endif
}

/// The review session beside the diff: whether it runs, that you talk to it in its own pane in iTerm, the comments
/// drafted on GitHub for these PRs, and this PR's threads, each a press that shows its line. Desk sends nothing to the
/// session; Show in iTerm puts its pane in front.
private struct ReviewSessionPanel: View {
    var pr: PullRequest
    var parts: [PullRequest]
    var model: AppModel

    var body: some View {
        let running = model.reviewRunning(pr)
        let drafts = parts.filter { $0.pendingReview != nil }
        let threads = model.conversations[pr.url]?.threads.filter { !$0.isOutdated && $0.line != nil } ?? []
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review session").fontWeight(.semibold)
                HStack(spacing: 6) {
                    ZStack {
                        Circle().stroke(Theme.quiet, lineWidth: 1.5)
                        if running { Circle().trim(from: 0, to: 0.25).stroke(Theme.accentInk, lineWidth: 1.5).rotationEffect(.degrees(-90)) }
                    }
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                    Text(running ? "running in iTerm" : "not started")
                }
                .scaled(.caption.monospaced()).foregroundStyle(Theme.quiet)
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.ruleSoft).frame(height: 1) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(running
                        ? "The session runs in its own pane in iTerm, beside the master. Talk to it there: ask about a part, or tell it to drop a comment."
                        : "Start review opens a session in its own pane in iTerm, beside the master; you talk to it there.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Copy lines (⇧⌘C) puts the lines you select here on the clipboard, with their path and numbers, to paste to it.")
                        .scaled(.secondary).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
                    if !drafts.isEmpty {
                        RuledList(title: "Drafted on GitHub", count: drafts.compactMap(\.pendingReview?.comments).reduce(0, +)) {
                            ForEach(drafts, id: \.url) { part in
                                let comments = part.pendingReview?.comments ?? 0
                                RuledRow {
                                    Text(verbatim: "#\(part.number)").scaled(.code).foregroundStyle(Theme.quiet).scaledFrame(width: 44, alignment: .leading)
                                    Text("\(comments) comment\(comments == 1 ? "" : "s") in your pending review")
                                }
                            }
                        }
                    }
                    if !threads.isEmpty {
                        RuledList(title: "Threads on #\(pr.number)", count: threads.count) {
                            ForEach(threads) { thread in
                                Button { jump(to: thread) } label: {
                                    RuledRow {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(thread.location).scaled(.code).foregroundStyle(Theme.quiet).lineLimit(1).truncationMode(.head)
                                            if let first = thread.comments.first {
                                                Text("\(first.name): \(first.firstLine)").lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                        .padding(.vertical, 7)
                                        Spacer(minLength: 4)
                                        if thread.isResolved { Text("Resolved").scaled(.caption).foregroundStyle(Theme.quiet) }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Show its line in the diff")
                            }
                        }
                    }
                    Text("Pending reviews stay yours: nothing posts until you submit.")
                        .scaled(.secondary).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
                }
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            }
            Button(running ? "Show in iTerm" : "Start review") {
                if running { model.showReview(pr) } else { model.startReview(pr) }
            }
            .buttonStyle(.desk(.secondary, .large, wide: true))
            .help(running ? "The review session's pane in iTerm" : "Starts a review session in a pane of its own in iTerm")
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16))
            .overlay(alignment: .top) { Rectangle().fill(Theme.ruleSoft).frame(height: 1) }
        }
        .scaledFrame(width: 320)
        .frame(maxHeight: .infinity)
        .background(Theme.surface)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.rule).frame(width: 1) }
    }

    private func jump(to thread: ConversationThread) {
        guard let line = thread.line else { return }
        model.diffJump = DiffJump(url: pr.url, path: thread.path, side: thread.side, line: line)
    }
}

enum ReviewBoxPart { case top, middle, bottom, whole }

extension View {
    /// One part of a rounded box drawn a row at a time, as a list or a lazy stack draws it: its top with the rounded
    /// corners, a row of its middle, its bottom, or the whole box in one row. Each part fills and outlines itself; the
    /// outline's open ends run past the row and are clipped, so the parts stacked read as one box.
    func reviewBox(_ part: ReviewBoxPart, fill: Color, line: Color, radius: CGFloat = 8) -> some View {
        let top: CGFloat = part == .top || part == .whole ? radius : 0
        let bottom: CGFloat = part == .bottom || part == .whole ? radius : 0
        let shape = UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top)
        return background(fill).clipShape(shape).overlay {
            Color.clear.overlay {
                shape.strokeBorder(line).padding(.top, top > 0 ? 0 : -2).padding(.bottom, bottom > 0 ? 0 : -2)
            }
            .clipped()
        }
    }
}

// MARK: - The pieces every diff draws: Reviews' diff screen and the Files changed tab of your PR's page.

/// The code at the app's text size, which the rows' heights follow, and the one line-number column, the new number or a
/// removed line's old one: five digits and a gap at the code's size, 44 pt at the default.
struct DiffType {
    var scale: CGFloat
    var mono: Font { AppTextStyle.code.font(scale: scale) }
    var gutter: CGFloat { (AppTextStyle.code.size * scale).rounded() * 3.7 }
}

extension DiffLine {
    /// What a unified diff puts before the line.
    var marker: String {
        switch kind {
        case .added: "+ "
        case .removed: "- "
        case .context: "  "
        }
    }
}

/// A file's header: its path, how it changed, its +/− counts. A button that folds the file, so the keyboard and VoiceOver
/// can fold it too.
struct DiffFileHeader: View {
    var file: DiffFile
    var folded: Bool
    /// One of the files that open folded because they are too large to draw on their own (`foldedAtFirst`).
    var large = false
    var toggle: () -> Void
    @Environment(\.textScale) private var scale

    var body: some View {
        let mono = DiffType(scale: scale).mono
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: folded ? "chevron.right" : "chevron.down")
                    .scaled(.caption.weight(.semibold)).foregroundStyle(Theme.quiet).frame(width: 12)
                Text(file.previousPath.map { "\($0) → \(file.path)" } ?? file.path)
                    .lineLimit(1).truncationMode(.head)
                Text(file.status == .modified ? "" : file.status.rawValue).scaled(.caption).foregroundStyle(Theme.quiet)
                if folded, large { Text("Large diff: click to show").scaled(.caption).foregroundStyle(Theme.quiet) }
                Spacer(minLength: 8)
                Text("+\(file.additions) −\(file.deletions)").foregroundStyle(Theme.quiet)
            }
            .font(mono)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Opaque: pinned, it covers the rows scrolling under it.
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.ruleSoft).frame(height: 1) }
        .help(folded ? "Show its lines" : "Hide its lines")
        .accessibilityValue(folded ? "Collapsed" : "Expanded")
    }
}

struct DiffHunkRow: View {
    var header: String
    @Environment(\.textScale) private var scale

    var body: some View {
        let type = DiffType(scale: scale)
        Text(header)
            .font(type.mono).foregroundStyle(Theme.quiet).lineLimit(1)
            .padding(.vertical, 3).padding(.leading, type.gutter + 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.inset)
    }
}

/// One line of code: its number, its marker and text, tinted green or red by what happened to it, or by `highlight`.
struct DiffLineRow: View {
    var line: DiffLine
    var highlight: Color?
    @Environment(\.textScale) private var scale

    var body: some View {
        let type = DiffType(scale: scale)
        HStack(alignment: .top, spacing: 0) {
            Text((line.newLine ?? line.oldLine).map(String.init) ?? "").frame(width: type.gutter, alignment: .trailing).foregroundStyle(Theme.quiet)
            // Six lines at most: a minified file's or a lockfile's line wrapped whole stands hundreds of points tall among
            // rows of one, and is laid out again on every pass of the lazy stack. The whole line is on GitHub.
            Text(line.marker + line.text).lineLimit(6).padding(.leading, 12)
        }
        .font(type.mono)
        // The boards' 1.75 line height.
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlight ?? tint)
        .help(line.oldLine.map { "Was line \($0)" } ?? "")
    }

    private var tint: Color {
        switch line.kind {
        case .added: Theme.add
        case .removed: Theme.del
        case .context: .clear
        }
    }
}

/// The review threads that end on this line, under it, to reply to or resolve: a right-side one by the line's new number,
/// a left-side one, on a removed line, by its old. An outdated thread has no line here; the conversation lists it.
struct DiffThreads: View {
    var line: DiffLine
    var path: String
    var pr: PullRequest
    var model: AppModel
    @Environment(\.textScale) private var scale

    var body: some View {
        if let conversation = model.conversations[pr.url] {
            let threads = (line.newLine.map { conversation.threads(at: path, side: .right, line: $0) } ?? [])
                + (line.oldLine.map { conversation.threads(at: path, side: .left, line: $0) } ?? [])
            if !threads.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(threads) { ThreadView(thread: $0, pr: pr, model: model, showsLocation: false) }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.leading, DiffType(scale: scale).gutter + 12)
                .padding(.trailing, 16)
                .padding(.vertical, 8)
            }
        }
    }
}
