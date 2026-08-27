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
        print("jira: \(config.jiraSite) \(config.jiraEmail.isEmpty ? "(no email)" : config.jiraEmail)  token: \(await service.hasJiraToken() ? "yes" : "no")")

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

        section("Claude")
        do {
            let claude = try await service.refreshClaude(gitScan: scan)
            state.liveSessions = claude.live
            state.claudeScan = claude.scan
            print("\(claude.live.count) live sessions (\(claude.live.filter(\.isAlive).count) alive), \(claude.scan.summaries.count) transcripts scanned")
            for live in claude.live {
                print("  \(pad(live.status.rawValue, 8)) \(pad(live.kind.rawValue, 12)) \(pad(live.name, 40)) \(live.cwd)\(live.isAlive ? "" : "  (dead)")")
            }
            for session in claude.scan.sessions.prefix(8) {
                let cost = session.costUSD.map { String(format: "$%.0f", $0) } ?? "-"
                print("  \(pad(session.displayName, 40)) \(pad(session.branches.first ?? "-", 36)) prompts:\(session.humanPrompts) prs:\(session.prLinks.count) \(cost)")
            }
        } catch {
            print("  error: \(error)")
        }

        section("GitHub")
        do {
            let github = try await service.refreshGitHub(now: now)
            state.github = github
            print("login \(github.login): \(github.mine.count) open PRs, \(github.reviewRequests.count) review requests, \(github.mergedRecent.count) merged recently, \(github.reviewedByMe.count) reviewed by me")
            for pr in github.mine {
                print("  \(pad("\(pr.repoName)#\(pr.number)", 22)) \(pad(pr.checks.rawValue, 8)) \(pad(pr.reviewDecision.rawValue, 16)) \(pad(pr.mergeState.rawValue, 9)) \(pr.title.prefix(60))")
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

        state.recompute(now: now)

        section("Work items (\(state.workItems.count))")
        for item in state.workItems.prefix(15) {
            let live = item.liveSessions.isEmpty ? "" : " live:\(item.liveSessions.count)"
            print("  \(pad(item.ticketKey ?? "-", 9)) prs:\(item.pullRequests.count) wt:\(item.worktrees.count) sessions:\(item.sessions.count)\(live)  \(item.title.prefix(70))")
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

        section("Nudges (\(state.nudges.count))")
        for nudge in state.nudges { print("  [\(nudge.severity)] \(nudge.title) — \(nudge.detail)") }
    }

    private static func section(_ title: String) {
        print("\n== \(title) ==")
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? String(text.prefix(width)) : text + String(repeating: " ", count: width - text.count)
    }
}
