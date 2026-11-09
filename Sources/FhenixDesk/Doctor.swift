import DeskCore
import Foundation

/// Prints every data source as text. Run with `FhenixDesk --doctor`.
enum Doctor {
    static func run() async {
        let support = AppSupport()
        let (config, configError) = DeskService.loadConfig(support: support)
        let service = DeskService(config: config, support: support)
        var state = DeskState(config: config)
        let now = Date()

        section("Config")
        if let configError { print(configError) }
        print("roots: \(config.expandedRepoRoots.joined(separator: ", "))  org: \(config.githubOrg)  gh: \(config.resolvedGhPath ?? "not found")")
        print("tracked repos: \(config.trackedRepos.isEmpty ? "none — nothing is watched until you pick some in Settings" : config.trackedRepos.joined(separator: ", "))")
        let jira = await service.jiraAccount()
        print("jira: acli \(config.resolvedAcliPath ?? "not found")  \(jira.map { "signed in to \($0.site) as \($0.email ?? "?")" } ?? "not signed in")")

        section("Setup")
        for kind in SetupCheck.Kind.allCases {
            let check = await Setup.check(kind, config: config)
            print("  \(check.ok ? "ok  " : "MISS") \(pad(kind.title, 26)) \(check.detail)")
        }

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
        state.reviewSkills = await service.reviewSkills(repos: scan.repos)
        for repo in scan.repos { print("  \(pad(repo.name, 18)) skills: \(state.reviewSkills[repo.root]?.text ?? "?")") }

        section("GitHub")
        do {
            let github = try await service.refreshGitHub(now: now)
            state.github = github
            print("login \(github.login): \(github.mine.count) open PRs, \(github.reviewRequests.count) review requests, \(github.mergedRecent.count) merged recently")
            print("review queue: \(state.reviewQueue(.onMe).count) on me, \(state.openForReview.count) open and unreviewed by me, \(state.reviewedByYou.count) reviewed by me and waiting on the author (of \(github.openForReview.count) open by others)")
            for pr in state.reviewedByYou { print("  reviewed: \(pr.repoName)#\(pr.number) \(pr.title)") }
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
        // Read off GitHub: the queue PRs you have a draft on, or have reviewed.
        let reviewed = state.reviewQueue(.all).filter { state.reviewStatus(for: $0).draft != nil }
        print("\(reviewed.count) reviewed or drafted  claude: \(config.resolvedClaudePath ?? "not found")")
        for pr in reviewed {
            let status = state.reviewStatus(for: pr)
            let flags = [
                status.headMoved ? "new commits" : nil, status.reRequested ? "re-requested" : nil,
            ].compactMap { $0 }.joined(separator: " ")
            print("  \(pad("\(pr.repoName)#\(pr.number)", 22)) \(pad(draftText(status.draft), 28)) \(flags)")
        }

        section("Background sessions")
        state.claudeJobs = await service.claudeJobs()
        if state.claudeJobs.isEmpty { print("  no background Claude session mentions a pull request or a ticket") }
        for job in state.claudeJobs {
            let about = job.prKeys.isEmpty ? job.ticketKey ?? "" : job.prKeys.sorted().joined(separator: " ")
            print("  \(pad(job.id, 10)) \(pad(job.state, 8)) \(pad(about, 34)) \(job.name.prefix(40))")
        }

        state.recompute(now: now)

        // Worked out here as the app does on every refresh: nothing of it is saved.
        section("Flow")
        for pr in state.mine {
            guard let stage = state.stage(for: pr) else { continue }
            print("  \(pad("\(pr.repoName)#\(pr.number)", 22)) \(pad(stage.title, 18)) \(pr.approvalStatus ?? "no review gate")")
        }

        section("Waiting on your review (\(state.reviewsToDo.count))")
        if state.reviewsToDo.isEmpty { print("  nothing asked of you") }
        for pr in state.reviewsToDo {
            let need = state.reviewNeed(for: pr)?.title ?? ""
            print("  \(pad("\(pr.repoName)#\(pr.number)", 22)) \(pad(need, 16)) \(pr.title)")
        }

        section("Stacks")
        for pr in state.mine {
            if let parent = state.stackParent(of: pr) { print("  \(pr.repoName)#\(pr.number) ← #\(parent.number)") }
            if let reason = state.rebaseReason(pr) { print("  \(pr.repoName)#\(pr.number) needs rebase: \(reason.text)") }
        }

        section("Suggested Jira moves (\(state.ticketDrifts.count))")
        print("review: \(config.jiraReviewStatus.isEmpty ? "off" : config.jiraReviewStatus)  done: \(config.jiraDoneStatus.isEmpty ? "off" : config.jiraDoneStatus)")
        if state.ticketDrifts.isEmpty { print("  every ticket agrees with its pull requests") }
        for drift in state.ticketDrifts {
            let prs = drift.pullRequests.map { "\($0.repoName)#\($0.number)" }.joined(separator: " ")
            print("  \(pad(drift.ticket.key, 9)) \(pad(drift.ticket.status, 16)) -> \(pad(drift.target, 16)) \(prs)")
        }

        section("Nudges (\(state.nudges.count))")
        for nudge in state.nudges { print("  [\(nudge.severity)] \(nudge.title) — \(nudge.detail)") }
    }

    private static func draftText(_ status: DraftStatus?) -> String {
        switch status {
        case .pending(let comments): return "draft: \(comments) comments"
        case .submitted(let state): return "submitted: \(state.lowercased())"
        case nil: return "not reviewed"
        }
    }

    private static func section(_ title: String) {
        print("\n== \(title) ==")
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? String(text.prefix(width)) : text + String(repeating: " ", count: width - text.count)
    }
}
