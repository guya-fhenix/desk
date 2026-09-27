import DeskCore
import Foundation

/// Prints every data source as text. Run with `FhenixDesk --doctor`.
enum Doctor {
    static func run() async {
        let support = AppSupport()
        let config = DeskService.loadConfig(support: support)
        let service = DeskService(config: config, support: support)
        var state = DeskState(config: config)
        let now = Date()

        section("Config")
        print("roots: \(config.expandedRepoRoots.joined(separator: ", "))  org: \(config.githubOrg)  gh: \(config.resolvedGhPath ?? "not found")")
        print("tracked repos: \(config.trackedRepos.isEmpty ? "none — nothing is watched until you pick some in Settings" : config.trackedRepos.joined(separator: ", "))")
        let jira = await service.jiraAccount()
        print("jira: acli \(config.resolvedAcliPath ?? "not found")  \(jira.map { "signed in to \($0.site) as \($0.email ?? "?")" } ?? "not signed in")")

        section("Git")
        let scan = await service.refreshGit()
        state.gitScan = scan
        print("\(scan.repos.count) repos, \(scan.worktrees.count) worktrees")
        for worktree in scan.worktrees {
            let flags = [worktree.isMain ? "main" : "wt", worktree.isPrunable ? "prunable" : nil, worktree.dirtyFiles > 0 ? "dirty:\(worktree.dirtyFiles)" : nil,
                         worktree.ahead > 0 ? "ahead:\(worktree.ahead)" : nil, worktree.behind > 0 ? "behind:\(worktree.behind)" : nil,
                         worktree.hasUpstream ? nil : "no-upstream", worktree.behindDefault > 0 ? "behindDefault:\(worktree.behindDefault)" : nil].compactMap { $0 }
            print("  \(pad(worktree.repoName, 18)) \(pad(worktree.branch ?? "(detached)", 44)) \(flags.joined(separator: " "))")
        }
        for error in scan.errors { print("  error: \(error)") }

        section("GitHub")
        do {
            let github = try await service.refreshGitHub(now: now)
            state.github = github
            print("login \(github.login): \(github.mine.count) open PRs, \(github.reviewRequests.count) review requests, \(github.mergedRecent.count) merged recently, \(github.reviewedByMe.count) reviewed by me")
            print("review queue: \(state.reviewQueue(.onMe).count) on me, \(state.openForReview.count) open and unreviewed by me (of \(github.openForReview.count) open by others)")
            for pr in github.mine {
                let threads = pr.unresolvedThreads > 0 ? "threads:\(pr.unresolvedThreads)" : ""
                print("  \(pad("\(pr.repoName)#\(pr.number)", 22)) \(pad(pr.checks.rawValue, 8)) \(pad(pr.reviewDecision.rawValue, 16)) \(pad(pr.mergeState.rawValue, 9)) \(pad(threads, 10)) \(pr.title.prefix(60))")
            }
        } catch {
            print("  error: \(error)")
        }

        section("Jira")
        do {
            state.tickets = try await service.refreshJira(referencedKeys: state.referencedTicketKeys)
            print("\(state.tickets.count) tickets")
            for ticket in state.tickets { print("  \(pad(ticket.key, 9)) \(pad(ticket.status, 12)) \(ticket.summary.prefix(70))") }
        } catch {
            print("  \(error)")
        }

        section("Reviews")
        state.reviews = await service.reviews()
        print("\(state.reviews.count) reviews  root: \(config.expandedReviewRoot)  claude: \(config.resolvedClaudePath ?? "not found")")
        for record in state.reviews.values.sorted(by: { $0.lastRunAt > $1.lastRunAt }) {
            let status = state.reviewStatus(for: record, pr: state.pullRequest(for: record))
            let flags = [
                status.headMoved ? "new commits" : nil, status.reRequested ? "re-requested" : nil,
            ].compactMap { $0 }.joined(separator: " ")
            print("  \(pad(record.label, 22)) \(pad(status.phase.label, 10)) \(pad(draftText(record, status.draft), 20)) runs:\(record.runs) \(pad(Format.usd(status.costUSD), 8)) \(pad(flags, 26)) \(record.worktreePath)")
        }

        section("Background sessions")
        state.claudeJobs = await service.claudeJobs()
        if state.claudeJobs.isEmpty { print("  no background Claude session mentions a pull request") }
        for job in state.claudeJobs {
            print("  \(pad(job.id, 10)) \(pad(job.state, 8)) \(pad(job.prKeys.sorted().joined(separator: " "), 34)) \(job.name.prefix(40))")
        }

        state.recompute(now: now)

        section("Ready to run (\(state.reviewsToRun.count))")
        if state.reviewsToRun.isEmpty { print("  nothing waiting; reviews only ever start from a press") }
        for pr in state.reviewsToRun {
            let need = state.reviewNeed(for: pr)?.title ?? ""
            print("  \(pad("\(pr.repoName)#\(pr.number)", 22)) \(pad(need, 16)) \(pr.title)")
        }

        section("Stacks")
        for pr in state.mine {
            if let parent = state.stackParent(of: pr) { print("  \(pr.repoName)#\(pr.number) ← #\(parent.number)") }
            if let reason = state.rebaseReason(pr) { print("  \(pr.repoName)#\(pr.number) needs rebase: \(reason.text)") }
        }

        section("Cycle time (\(state.cycles.count) merged PRs)")
        for week in state.weekly {
            print("  \(week.weekStart.formatted(.iso8601.year().month().day()))  merged:\(week.merged)  first review:\(Format.duration(week.medianToFirstReview))  approval:\(Format.duration(week.medianToApproval))  merge:\(Format.duration(week.medianToMerge))  total:\(Format.duration(week.medianTotal))")
        }
        print("  my review latency median: \(Format.duration(CycleTime.median(state.reviewLatencies.map(\.latency)))) over \(state.reviewLatencies.count) reviews")

        section("Ticket sync (\(state.ticketDrifts.count))")
        print("review: \(config.jiraReviewStatus.isEmpty ? "off" : config.jiraReviewStatus)  done: \(config.jiraDoneStatus.isEmpty ? "off" : config.jiraDoneStatus)")
        if state.ticketDrifts.isEmpty { print("  every ticket agrees with its pull requests") }
        for drift in state.ticketDrifts {
            let prs = drift.pullRequests.map { "\($0.repoName)#\($0.number)" }.joined(separator: " ")
            print("  \(pad(drift.ticket.key, 9)) \(pad(drift.ticket.status, 16)) -> \(pad(drift.target, 16)) \(prs)")
        }

        section("Nudges (\(state.nudges.count))")
        for nudge in state.nudges { print("  [\(nudge.severity)] \(nudge.title) — \(nudge.detail)") }
    }

    /// Starts or continues the Claude review of one PR and prints the resulting record.
    static func review(url: String) async {
        let support = AppSupport()
        let config = DeskService.loadConfig(support: support)
        let service = DeskService(config: config, support: support)
        var state = DeskState(config: config)
        do {
            state.gitScan = await service.refreshGit()
            state.github = try await service.refreshGitHub()
            guard let pr = (state.github?.allOpen ?? []).first(where: { $0.url == url }) else {
                print("not an open PR of mine or waiting on me: \(url)")
                return
            }
            print("reviewing \(pr.repoName)#\(pr.number) \(pr.title) @ \(pr.headSha.prefix(12)) into \(pr.baseRef)")
            print("this runs claude -p and waits; it can take several minutes")
            await service.review(pr: pr, gitScan: state.gitScan!)
            state.reviews = await service.reviews()
            guard let record = state.reviews[url] else {
                print("no record written")
                return
            }
            print("phase: \(record.phase.label)  runs: \(record.runs)  cost: \(Format.usd(record.costUSD))")
            print("worktree: \(record.worktreePath) @ \(record.headSha.prefix(12))")
            if let error = record.error { print("error: \(error)") }
            print("added \(record.lastPosted) comments to your draft review, skipped \(record.lastSkipped)")
            if record.draft != nil { print("read and submit it at \(record.filesURL)") }
        } catch {
            print("error: \(error)")
        }
    }

    private static func draftText(_ record: ReviewRecord, _ status: DraftStatus?) -> String {
        switch status {
        case .pending(let comments): return "draft: \(comments) comments"
        case .submitted(let state): return "submitted: \(state.lowercased())"
        case .discarded: return "draft discarded"
        case nil: return record.draft == nil ? "no draft" : "draft (not in poll)"
        }
    }

    private static func section(_ title: String) {
        print("\n== \(title) ==")
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? String(text.prefix(width)) : text + String(repeating: " ", count: width - text.count)
    }
}
