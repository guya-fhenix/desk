import DeskCore
import SwiftUI

extension ReviewLearning.Status {
    private static func day(_ date: Date) -> String { date.formatted(.dateTime.day().month(.abbreviated)) }
    /// "today 14:02", or "12 Nov 14:02" for another day.
    private static func moment(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? "today \(date.clock)" : "\(day(date)) \(date.clock)"
    }

    /// The pass in a line, for the Focus card's title, the menu bar and the banner.
    var title: String {
        switch self {
        case .due(nil, _): return "Weekly review learning has not run yet"
        case .due: return "Weekly review learning is due"
        case .running: return "Weekly review learning: started, not finished"
        case .upToDate: return "Weekly review learning is finished"
        }
    }

    /// The pass in a few words, under its name in the sidebar and under its title in the menu bar: whether a run is
    /// due, started or finished, never what its session is doing.
    var words: String {
        switch self {
        case .due(_, .some): return "Due · last start didn't finish"
        case .due(nil, _): return "Never run"
        case .due(let last?, _): return "Due · last \(Self.day(last))"
        case .running: return "Not finished yet"
        case .upToDate(_, let next, _): return "Done · next \(Self.day(next))"
        }
    }

    /// The Focus card's line of detail: the repo, the run that did not finish, the last one that did, and the days a
    /// run started now covers, the script's last 7 whole days in UTC.
    func detail(now: Date = Date()) -> String {
        let repo = ReviewLearning.repo.split(separator: "/").last.map(String.init) ?? ReviewLearning.repo
        let style = Date.FormatStyle(timeZone: .gmt).day().month(.abbreviated)
        let covers = "a run now covers \(now.addingTimeInterval(-ReviewLearning.interval).formatted(style)) to \(now.addingTimeInterval(-86_400).formatted(style))"
        switch self {
        case .due(let last, let unfinished):
            let parts: [String?] = [
                repo, unfinished.map { "the run started \(Self.moment($0)) did not finish" },
                last.map { "last finished \(Self.day($0)), \(Format.ago($0, now: now))" }, covers,
            ]
            return parts.compactMap { $0 }.joined(separator: " · ")
        case .running(let started, _): return "\(repo) · started \(Self.moment(started))"
        case .upToDate(let finished, let next, _): return "\(repo) · finished \(Self.day(finished)) · next \(Self.day(next))"
        }
    }

    /// A run is due, rather than started and not finished.
    var isDue: Bool {
        if case .due = self { return true }
        return false
    }

    /// Since when the pass has been due: 7 days after the last finished run. Nil before the first.
    var dueSince: Date? {
        if case .due(let last?, _) = self { return last.addingTimeInterval(ReviewLearning.interval) }
        return nil
    }
}

/// The review learning pass's mark, before its name.
struct ReviewLearningIcon: View {
    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.accentInk)
            .accessibilityHidden(true)
    }
}

/// The pass on the Focus page, while it waits on you: a large card under Now while a run is due, with Start, and a
/// medium one under Next while a run is started and not finished, with Open and Start again. Desk sets its level, not
/// the master's ranking, and nothing dismisses it: it goes when a run has finished.
// ponytail: not a FocusItem, so J and K walk past it; one more subject there when the keys should reach it.
struct ReviewLearningCard: View {
    var status: ReviewLearning.Status
    var model: AppModel
    /// Start again was pressed while a session is still there, and waits for your yes: it stops and removes it.
    @State private var confirmingRestart = false

    var body: some View {
        Group {
            if status.isDue { due } else { started }
        }
        .confirmationDialog("Stop this run and start a new one?", isPresented: $confirmingRestart) {
            Button("Stop it and start again", role: .destructive) { model.startReviewLearning() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The run's session is stopped and removed. What it has written so far stays in the run's folder.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private var due: some View {
        VStack(alignment: .leading, spacing: 9) {
            head("Review learning due")
            Text(status.title).scaled(.heading).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text(status.detail()).scaled(.secondary).foregroundStyle(Theme.quiet).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            failure
            Button(startTitle) { model.startReviewLearning() }
                .buttonStyle(.desk(.primary, .regular)).disabled(model.startingReviewLearning).padding(.top, 2)
                .help("Starts a Claude session on the pass in your cofhe clone and shows it in iTerm")
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.warn, lineWidth: 1.5))
    }

    private var started: some View {
        VStack(alignment: .leading, spacing: 5) {
            head("Review learning, not finished")
            Text(status.title).scaled(.body.weight(.semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            failure
            HStack(spacing: 8) {
                Text(status.detail()).scaled(.secondary).foregroundStyle(Theme.quiet).lineLimit(1)
                Spacer(minLength: 4)
                Button(startTitle) { confirmingRestart = true }
                    .buttonStyle(.desk(.quiet, .small)).disabled(model.startingReviewLearning)
                    .help("Stops and removes this run's session and starts a new run")
                Button("Open") { model.openReviewLearning() }.buttonStyle(.desk(.secondary, .small))
                    .help("The run's session in iTerm")
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.rule))
    }

    private var startTitle: String {
        if model.startingReviewLearning { return "Starting…" }
        switch status {
        case .due(_, .some), .running: return "Start again"
        default: return "Start"
        }
    }

    private func head(_ chip: String) -> some View {
        HStack(spacing: 6) {
            ReviewLearningIcon()
            Text("cofhe").scaled(.code).foregroundStyle(Theme.quiet).lineLimit(1).fixedSize()
            StageChip2(text: chip, color: Theme.warn)
            Spacer(minLength: 4)
            if let since = status.dueSince {
                Text("waiting \(Format.age(since))").scaled(.caption).foregroundStyle(Theme.quiet).fixedSize()
                    .help("Due since \(Format.date(since))")
            }
        }
    }

    @ViewBuilder private var failure: some View {
        if let error = model.reviewLearningError {
            Text(error).scaled(.secondary).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Over the master in the sidebar, there while the pass's repo is tracked: the pass in a few words, and its one press: Start while a run is due,
/// Open while one is started and not finished, Report once one has finished.
struct ReviewLearningSidebarCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.reviewLearning
        let failed = model.reviewLearningError != nil
        // Not there at all while the pass's repo is not one Desk tracks; there, reading, until the first scan says.
        if model.state.gitScan == nil || model.reviewLearningClone != nil { card(status, failed: failed) }
    }

    private func card(_ status: ReviewLearning.Status?, failed: Bool) -> some View {
        Button(action: press) {
            HStack(spacing: 6) {
                ReviewLearningIcon()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Review learning").scaled(.body.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.8)
                    HStack(spacing: 5) {
                        if model.startingReviewLearning || status == nil {
                            ProgressView().controlSize(.mini)
                        } else {
                            Circle().fill(status?.needsYou == true ? Theme.warn : Theme.ok).frame(width: 6, height: 6)
                        }
                        Text(failed ? "Couldn't start" : model.startingReviewLearning ? "Starting…" : status?.words ?? "Reading…")
                            .lineLimit(1).minimumScaleFactor(0.85)
                    }
                    .scaled(.secondary)
                    .foregroundStyle(failed ? Theme.danger : Theme.quiet)
                }
                .layoutPriority(1)
                Spacer(minLength: 2)
                if let pill {
                    Text(pill).scaled(.secondary.weight(.medium)).foregroundStyle(Theme.accentInk).fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.tint, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.ruleStrong))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .handCursor()
        .disabled(model.startingReviewLearning || status == nil)
        .help(model.reviewLearningError ?? "The weekly review learning pass for cofhe: \(status?.detail() ?? "due 7 days after the last finished run")")
    }

    private var pill: String? {
        switch model.reviewLearning {
        case .due: return "Start"
        case .running: return "Open"
        case .upToDate: return "Report"
        case nil: return nil
        }
    }

    private func press() {
        switch model.reviewLearning {
        case .due: model.startReviewLearning()
        case .running: model.openReviewLearning()
        case .upToDate: model.openReviewLearningReport()
        case nil: break
        }
    }
}
