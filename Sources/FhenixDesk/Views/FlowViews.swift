import DeskCore
import SwiftUI

/// Your open PR's next step, read-only: what it waits on and whose move that is, read off GitHub and the session on each
/// refresh. Where the move is the master's or its worker's, the press that shows the master's pane, to tell it there; the
/// presses that change the PR itself are in the page's ⋯. A conflict, red CI or a base to rebase onto shows here at any
/// stage, and so does a question the session is asking you.
struct NextStepCard: View {
    var pr: PullRequest
    /// The background session carrying the PR, when it has one.
    var session: ClaudeJob?
    var model: AppModel

    var body: some View {
        let step = self.step
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Next step")
            Text(step.text).fixedSize(horizontal: false, vertical: true)
            if let session, session.isAsking {
                // Its question is often the last line of a long report, easy to read past in the pane; so it is said here.
                note(session.question.map { "The session asks: “\($0)”" } ?? "The session is asking you something.", Theme.warn)
            } else if let session, session.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(session.detail ?? "Its session is working, on this PR or something else.").scaled(.secondary).foregroundStyle(Theme.quiet).lineLimit(2)
                }
            }
            if pr.checks.isRed, RowState.of(pr) != .ciFailed { note("CI failed.", Theme.warn) }
            if let reason = model.state.rebaseReason(pr) { note("Needs a rebase: \(reason.text).", Theme.warn) }
            if let error = model.flowErrors[pr.url] { note(error, Theme.danger).textSelection(.enabled) }
            if step.master {
                Button { model.openMaster() } label: { HStack(spacing: 8) { Text("Master in iTerm"); ButtonKey(key: "M") } }
                    .buttonStyle(.desk(.primary, .regular, wide: true))
                    .help("Show the master's pane in iTerm, to tell it there")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10))
    }

    private func note(_ text: String, _ color: Color) -> some View {
        Text(text).scaled(.secondary).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    /// The sentence, and whether the move is one to tell the master: a draft's self-review, threads to answer, CI or a
    /// conflict to fix. A merge is yours, in ⋯; a wait on reviewers is nobody's here.
    private var step: (text: String, master: Bool) {
        let threads = pr.unresolvedThreads == 1 ? "1 open thread" : "\(pr.unresolvedThreads) open threads"
        switch RowState.of(pr) {
        case .conflicts:
            return ("It conflicts with \(pr.baseRef). Tell the master to have its worker rebase it.", true)
        case .ciFailed:
            return ("CI failed. Tell the master to have its worker fix it.", true)
        case .changesRequested:
            let requesters = pr.changesRequestedBy
            let who = names(requesters, or: "the reviewer")
            let reasked = requesters.filter(pr.requestedReviewers.contains)
            if pr.unresolvedThreads > 0 {
                return ("\(names(requesters, or: "A reviewer")) requested changes; \(threads) wait on an answer. Tell the master to have its worker answer them.", true)
            }
            return reasked.isEmpty || reasked.count < requesters.count
                ? ("The threads are resolved. Ask \(who) for a re-review, or tell the master to in its pane.", true)
                : ("The threads are resolved, and \(names(reasked, or: "")) \(reasked.count == 1 ? "is" : "are") asked for a re-review. Nothing to do until they answer.", false)
        case .openThreads:
            return ("\(threads) wait on an answer. Tell the master to have its worker answer them.", true)
        case .readyToMerge:
            return ("\(readiness). Squash and merge is in ⋯.", false)
        case .draft(.notRun):
            return ("A draft, not self-reviewed yet. Tell the master to have its worker run the self-review.", true)
        case .draft(.passed):
            return ("Self-reviewed. Mark it ready for review in ⋯, or tell the master to.", true)
        case .waitingOnReview:
            let asked = names(pr.requestedReviewers, or: "")
            return (asked.isEmpty ? "Waiting on review. Nothing to do until a reviewer answers." : "Waiting on a review from \(asked).", false)
        }
    }

    private func names(_ names: [String], or fallback: String) -> String {
        names.isEmpty ? fallback : ListFormatter.localizedString(byJoining: names)
    }

    /// What makes it ready, as GitHub's merge box would say it: "Approved by noa-r · checks passed · no conflicts with
    /// main". Ready to merge already rules out red CI and conflicts.
    private var readiness: String {
        let approvers = pr.reviewerStatuses.filter { $0.state == .approved }.map(\.name)
        let checks = pr.checks == .success ? "checks passed" : pr.checks.isPending ? "checks running" : "no checks"
        return [approvers.isEmpty ? "Approvals met" : "Approved by \(approvers.joined(separator: ", "))", checks, "no conflicts with \(pr.baseRef)"]
            .joined(separator: " · ")
    }
}

/// A PR page's checks: their tally in the label, the worst few as rows, each opening its log, and the rest behind a
/// press. Fetched when the page shows the PR, again when its head or overall state moves, and every 20 s while a job is
/// still running, since one finishing leaves the overall state pending until the last.
struct TaskChecks: View {
    var pr: PullRequest
    var model: AppModel
    /// The PR these were fetched for: the page keeps this view as it moves to another PR.
    @State private var loaded: (url: String, checks: [PullRequestCheck])?
    @State private var error: String?
    @State private var expanded = false

    var body: some View {
        let checks = (loaded.flatMap { $0.url == pr.url ? $0.checks : nil } ?? [])
            .sorted { ($0.outcome, $0.workflow ?? "", $0.name) < ($1.outcome, $1.workflow ?? "", $1.name) }
        let shown = expanded ? checks : Array(checks.prefix(4))
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(checks.isEmpty ? "Checks" : "Checks · \(Self.tally(checks))").padding(.bottom, 6)
            if loaded?.url != pr.url {
                if let error {
                    Text(error).scaled(.secondary).foregroundStyle(Theme.danger).textSelection(.enabled)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else if checks.isEmpty {
                Text("No checks on the latest commit.").foregroundStyle(Theme.quiet)
            }
            ForEach(shown) { check in
                Button { model.open(check.url) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Self.mark(check.outcome).frame(width: 18)
                            Text("\(check.name) · \(check.outcome.word)").lineLimit(1)
                        }
                        if let step = check.failedStep {
                            Text("Failed at “\(step)”").scaled(.secondary).foregroundStyle(Theme.danger).padding(.leading, 26)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(check.url == nil)
                .help([check.workflow, check.name].compactMap { $0 }.joined(separator: " / ") + (check.url == nil ? "" : ": open its log on GitHub"))
                .overlay(alignment: .top) { Rectangle().fill(Theme.ruleSoft).frame(height: 1) }
            }
            if !shown.isEmpty { Rectangle().fill(Theme.ruleSoft).frame(height: 1) }
            if checks.count > 4 {
                Button(expanded ? "Show fewer" : "\(checks.count - 4) more, \(Self.tally(Array(checks.dropFirst(4))))") { expanded.toggle() }
                    .buttonStyle(.plain).scaled(.secondary).foregroundStyle(Theme.quiet).handCursor()
                    .padding(.top, 8)
            }
        }
        .task(id: "\(pr.url) \(pr.headSha) \(pr.checks.rawValue)") {
            error = nil
            while !Task.isCancelled {
                do {
                    loaded = (pr.url, try await model.checks(for: pr))
                } catch {
                    if !Task.isCancelled { self.error = "Couldn't load the checks: \(error)" }
                    return
                }
                guard loaded?.checks.contains(where: { $0.outcome == .running }) == true else { return }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    /// "11 passed", or "2 failed, 9 passed"; "all passed" for a run of one outcome after the first rows.
    static func tally(_ checks: [PullRequestCheck]) -> String {
        Dictionary(grouping: checks, by: \.outcome).sorted { $0.key < $1.key }
            .map { "\($0.value.count) \($0.key.word)" }.joined(separator: ", ")
    }

    @ViewBuilder static func mark(_ outcome: PullRequestCheck.Outcome) -> some View {
        switch outcome {
        case .passed: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ok)
        case .failed: Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.danger)
        case .running: Image(systemName: "clock").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.warn)
        case .cancelled, .neutral, .skipped: Image(systemName: "minus").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.quiet)
        }
    }
}

/// The facts of a PR, as label and value rows under "About": its open threads by who started them, with the way to them
/// on GitHub; who reviewed it and where each stands, then who is asked and has not answered; its labels; when it was
/// opened and last updated, the exact times on hover; and the stack it sits in. An ended PR's threads and stack are
/// over, so it leaves those out.
struct AboutCard: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        let open = pr.state == .open
        let parent = open ? model.state.stackParent(of: pr) : nil
        let children = open ? (model.state.github?.allOpen ?? []).filter { model.state.stackParents[$0.url] == pr.url } : []
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("About")
            FieldRows(labelWidth: 72) {
                if open { FieldRow(label: "Threads") { threads } }
                FieldRow(label: "Reviewers") { reviewers }
                FieldRow(label: "Labels") {
                    if pr.labels.isEmpty {
                        Text("None").foregroundStyle(Theme.quiet)
                    } else {
                        Flow(spacing: 4) { ForEach(pr.labels.sorted(), id: \.self) { StageChip2(text: $0) } }
                    }
                }
                FieldRow("Opened", "\(Format.age(pr.createdAt)) ago · updated \(Format.age(pr.updatedAt)) ago")
                if let parent { FieldRow(label: "Stacked on") { stackLink(parent) } }
                ForEach(children, id: \.url) { child in FieldRow(label: "Under it") { stackLink(child) } }
            }
            .help("Opened \(Format.date(pr.createdAt)) · updated \(Format.date(pr.updatedAt))")
        }
    }

    /// They are read and answered in the page's conversation too.
    @ViewBuilder private var threads: some View {
        if pr.unresolvedThreads == 0 {
            Text("None open").foregroundStyle(Theme.quiet)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(pr.unresolvedThreads) unresolved").foregroundStyle(Theme.warn)
                Text(pr.threads.byWho.map { "\($0.who) \($0.count)" }.joined(separator: " · "))
                    .scaled(.secondary).foregroundStyle(Theme.quiet)
                Button("Read them on GitHub") { model.open(pr.url + "/files") }
                    .buttonStyle(.plain).underline().scaled(.secondary).foregroundStyle(Theme.quiet).handCursor()
            }
        }
    }

    @ViewBuilder private var reviewers: some View {
        let reviewers = pr.reviewerStatuses
        if reviewers.isEmpty {
            Text("None yet").foregroundStyle(Theme.quiet)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(reviewers) { reviewer in
                    let (word, symbol, color) = Self.look(reviewer.state)
                    HStack(spacing: 6) {
                        Avatar(login: reviewer.name, size: 16)
                        Text(reviewer.name).lineLimit(1)
                        Image(systemName: symbol).foregroundStyle(color)
                    }
                    .help("\(reviewer.name): \(word)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(reviewer.name), \(word)")
                }
            }
        }
    }

    private static func look(_ state: ReviewerStatus.State) -> (word: String, symbol: String, color: Color) {
        switch state {
        case .approved: return ("approved", "checkmark.circle.fill", Theme.ok)
        case .changesRequested: return ("changes requested", "xmark.circle.fill", Theme.danger)
        case .commented: return ("commented", "text.bubble.fill", Theme.warn)
        case .dismissed: return ("dismissed", "minus.circle", Theme.quiet)
        case .pending: return ("pending", "clock", Theme.quiet)
        }
    }

    private func stackLink(_ other: PullRequest) -> some View {
        Button { model.open(other.url) } label: { Text(verbatim: "#\(other.number) \(other.title)").lineLimit(1) }
            .buttonStyle(.plain).underline().handCursor()
            .help("Open #\(other.number) on GitHub")
    }
}

/// Beside a PR row's pill, what its session is doing: a spinner while it works, a bubble while it asks you something, or a
/// red mark when the last press on it failed.
struct SessionMarks: View {
    var pr: PullRequest
    var model: AppModel

    var body: some View {
        if let session = model.state.session(for: pr) {
            if session.isRunning {
                ProgressView().controlSize(.mini).help("The session is working")
            } else if session.isAsking {
                Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(Theme.warn)
                    .help(session.asking)
            } else if let error = model.flowErrors[pr.url] {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger).help(error)
            }
        }
    }
}
