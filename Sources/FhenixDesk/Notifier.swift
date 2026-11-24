import AppKit
import DeskCore
import Foundation
import UserNotifications

/// Posts one macOS notification per new nudge and remembers what it already sent.
@MainActor
final class Notifier {
    private static let deliveredFile = "notified.json"
    /// The category every nudge is posted in, and its one action: a click opens the item in Desk, this opens GitHub.
    // Plain constants, read by the delegate off the main actor.
    nonisolated fileprivate static let category = "nudge"
    nonisolated fileprivate static let openOnGitHub = "openOnGitHub"
    /// What a click on a notification does with its url: the model opens it on its screen in the window.
    static var onShow: ((String) -> Void)?
    private static let retention: TimeInterval = 30 * 86_400
    private static let notifiedKinds: Set<NudgeKind> = [.ciFailed, .changesRequested, .newThreads, .readyToMerge, .needsRebase, .reviewRequested]

    private let support: AppSupport
    private var delivered: [String: Date]
    private let center: UNUserNotificationCenter?
    private let delegate = OpenURLDelegate()

    init(support: AppSupport) {
        self.support = support
        delivered = (try? support.load([String: Date].self, from: Self.deliveredFile)) ?? [:]
        // UNUserNotificationCenter needs an app bundle. `swift run` has none.
        center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
        center?.delegate = delegate
        center?.setNotificationCategories([UNNotificationCategory(
            identifier: Self.category,
            actions: [UNNotificationAction(identifier: Self.openOnGitHub, title: "Open on GitHub")],
            intentIdentifiers: []
        )])
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// What the review learning banner carries in place of a PR's url: a click opens Desk on Focus.
    nonisolated static let focusURL = "desk:focus"

    /// One banner each time the review learning pass becomes due: keyed by the last finished run, so the next one is
    /// news again after the next finished run. Call it only once every source has answered: a pass that became due
    /// while Desk was closed is still said once, at launch.
    func deliverReviewLearningDue(lastFinished: Date?, post: Bool) {
        guard let center else { return }
        let id = "review-learning:\(lastFinished?.timeIntervalSince1970 ?? 0)"
        guard delivered[id] == nil else { return }
        delivered[id] = Date()
        try? support.save(delivered, to: Self.deliveredFile)
        guard post else { return }
        let content = UNMutableNotificationContent()
        content.title = lastFinished == nil ? "Weekly review learning has not run yet" : "Weekly review learning is due"
        content.body = "cofhe · " + (lastFinished.map { "last finished \($0.formatted(.dateTime.day().month(.abbreviated)))" } ?? "never run") + ". Click to open Desk."
        // No category: its one action, Open on GitHub, has nothing to open here.
        content.userInfo["url"] = Self.focusURL
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Marks every current nudge as seen. Posts a notification only when `post` is true, so
    /// nudges that exist before all sources report once never fire. Returns the ones it posted, which go to the master
    /// as events too.
    @discardableResult
    func deliver(_ nudges: [Nudge], post: Bool) -> [Nudge] {
        // A run without a bundle posts nothing, and must not mark nudges seen in the file the installed app reads.
        guard let center else { return [] }
        let now = Date()
        let fresh = nudges.filter { delivered[$0.id] == nil && Self.notifiedKinds.contains($0.kind) && ($0.severity >= .warning || $0.kind == .readyToMerge) }
        for nudge in fresh {
            delivered[nudge.id] = now
            guard post else { continue }
            let content = UNMutableNotificationContent()
            content.title = nudge.title
            content.body = nudge.detail
            content.sound = nudge.severity == .urgent ? .default : nil
            content.categoryIdentifier = Self.category
            if let url = nudge.url { content.userInfo["url"] = url }
            center.add(UNNotificationRequest(identifier: nudge.id, content: content, trigger: nil))
        }
        let cutoff = now.addingTimeInterval(-Self.retention)
        delivered = delivered.filter { $0.value > cutoff }
        try? support.save(delivered, to: Self.deliveredFile)
        return post ? fresh : []
    }
}

private final class OpenURLDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// A click opens the item in Desk, where its buttons are; the notification's action goes to GitHub as before.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let url = response.notification.request.content.userInfo["url"] as? String, let parsed = URL(string: url) else { return }
        if response.actionIdentifier == Notifier.openOnGitHub {
            NSWorkspace.shared.open(parsed)
        } else {
            await MainActor.run { Notifier.onShow?(url) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
