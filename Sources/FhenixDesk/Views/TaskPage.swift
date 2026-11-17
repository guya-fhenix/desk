import AppKit
import DeskCore
import SwiftUI

extension AppTextStyle {
    /// A page's title under its breadcrumb: a task's, a PR's.
    static let taskPageTitle = AppTextStyle(size: 18, weight: .semibold)
}

/// A PR's page over the Tasks list: a header bar with the breadcrumb, the title and the page's presses; the main column
/// scrolling under it; the details column on the right. ← goes back and M shows the master, once the page has the focus,
/// which it takes as it opens.
struct TaskPageFrame<Crumb: View, Title: View, Actions: View, Main: View, Details: View>: View {
    var model: AppModel
    /// The screen it opened over, the breadcrumb's first word.
    var back: String
    var onBack: () -> Void
    /// False where the main column scrolls itself, as a diff does: its lazy stack of thousands of rows is then its scroll
    /// view's own content, as the review's diff has it, rather than inside the page's stack.
    var mainScrolls = true
    /// After "Tasks /": what the page is.
    @ViewBuilder var crumb: Crumb
    @ViewBuilder var title: Title
    @ViewBuilder var actions: Actions
    @ViewBuilder var main: Main
    @ViewBuilder var details: Details
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 0) {
                            Button(action: onBack) { Text(back) }.buttonStyle(.plain).handCursor().help("Back to \(back) (←)")
                            Text(" / ")
                            crumb
                        }
                        .scaled(.secondary)
                        .foregroundStyle(Theme.quiet)
                        .lineLimit(1)
                        title
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 8) { actions }.fixedSize()
                }
                .padding(EdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24))
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
                if mainScrolls {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) { main }
                            .padding(EdgeInsets(top: 18, leading: 24, bottom: 20, trailing: 24))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .deskScrollBar()
                } else {
                    VStack(alignment: .leading, spacing: 24) { main }
                        .padding(EdgeInsets(top: 18, leading: 24, bottom: 0, trailing: 24))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) { details }
                    .padding(EdgeInsets(top: 18, leading: 22, bottom: 16, trailing: 22))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scaledFrame(width: 360)
            .frame(maxHeight: .infinity)
            .background(Theme.surface)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.rule).frame(width: 1) }
        }
        .background(Theme.ground)
        .environment(\.focusPage, { [focus = $focused] in focus.wrappedValue = true })
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        // A turn of the run loop later: asked for while the page is still being put on screen, in place of the list that
        // had focus, the focus is dropped, and ← does nothing until a click.
        .task {
            await Task.yield()
            focused = true
        }
        // Not while a field is being typed in, such as the title being renamed: there the keys are the field's.
        .onKeyPress(.leftArrow) { typing ? .ignored : run(onBack) }
        .onKeyPress("m") { typing ? .ignored : run(model.openMaster) }
    }

    private var typing: Bool { NSApp.keyWindow?.firstResponder is NSText }

    private func run(_ action: () -> Void) -> KeyPress.Result {
        action()
        return .handled
    }
}

/// What the task screens say about a task in words, worked out from its PRs and sessions: nothing of it is stored.
enum TaskText {
    /// The ticket's TL;DR, or its first line of text: "Pick how the nodes jointly sign…", with "TL;DR" as its label.
    static func firstLine(_ ticket: Ticket) -> (label: String?, text: String)? {
        let lines = ticket.description.split(whereSeparator: \.isNewline)
            .map { $0.replacing(/[*_`]+/, with: "").replacing(/^#+\s*/, with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let index = lines.firstIndex(where: { $0.lowercased().hasPrefix("tl;dr") }) {
            let rest = lines[index].dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
            if !rest.isEmpty { return ("TL;DR", rest) }
            if index + 1 < lines.count { return ("TL;DR", lines[index + 1]) }
        }
        return lines.first.map { (nil, $0) }
    }

    /// "today 17:28", "Sun 15:02", or "9 Nov" further back.
    static func when(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDateInToday(date) { return "today \(date.clock)" }
        if now.timeIntervalSince(date) < 6 * 86_400 { return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(date.clock)" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
