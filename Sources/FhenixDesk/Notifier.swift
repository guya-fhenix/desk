import AppKit
import DeskCore
import Foundation
import UserNotifications

/// Posts one macOS notification per new nudge and remembers what it already sent.
@MainActor
final class Notifier {
    private static let deliveredFile = "notified.json"
    private static let retention: TimeInterval = 30 * 86_400
    private static let notifiedKinds: Set<NudgeKind> = [.ciFailed, .changesRequested, .readyToMerge, .needsRebase, .reviewRequested, .reviewReady]

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
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Marks every current nudge as seen. Posts a notification only when `post` is true, so
    /// nudges that exist before all sources report once never fire.
    func deliver(_ nudges: [Nudge], post: Bool) {
        let now = Date()
        let fresh = nudges.filter { delivered[$0.id] == nil && Self.notifiedKinds.contains($0.kind) && ($0.severity >= .warning || $0.kind == .readyToMerge || $0.kind == .reviewReady) }
        for nudge in fresh {
            delivered[nudge.id] = now
            guard post, let center else { continue }
            let content = UNMutableNotificationContent()
            content.title = nudge.title
            content.body = nudge.detail
            content.sound = nudge.severity == .urgent ? .default : nil
            if let url = nudge.url { content.userInfo["url"] = url }
            center.add(UNNotificationRequest(identifier: nudge.id, content: content, trigger: nil))
        }
        let cutoff = now.addingTimeInterval(-Self.retention)
        delivered = delivered.filter { $0.value > cutoff }
        try? support.save(delivered, to: Self.deliveredFile)
    }
}

private final class OpenURLDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let url = response.notification.request.content.userInfo["url"] as? String, let parsed = URL(string: url) else { return }
        NSWorkspace.shared.open(parsed)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
