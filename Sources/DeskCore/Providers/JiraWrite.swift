import Foundation

/// The app's only write to Jira. It lives in its own file so that fact stays auditable in one place —
/// everything in `JiraProvider.swift` reads. It happens on a press, never on a poll.
extension JiraProvider {
    /// Moves a work item to a status by name. acli works out which transition that is, and refuses when
    /// the workflow has no way there from where the ticket stands.
    ///
    /// Deliberately no retry, for the same reason `submitReview` has none: a failure reported after the
    /// transition landed would fire the workflow's side effects twice.
    public func transition(key: String, to status: String) async throws {
        let text: String
        do {
            text = try await Shell.output(
                acliPath, ["jira", "workitem", "transition", "--key", key, "--status", status, "--yes", "--json"],
                timeout: 60
            )
        } catch let error as ShellError {
            switch error {
            case .executableNotFound: throw JiraError.acliNotFound
            case .failed(_, _, let stderr):
                if stderr.lowercased().contains("unauthorized") { throw JiraError.notAuthenticated }
                throw JiraError.transitionRefused(
                    key: key, status: status, detail: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            case .timedOut: throw error
            }
        }
        // acli exits 0 whether or not the transition happened — a refused one is reported in the body and
        // nowhere else. Trusting the exit code here is what would make this button lie.
        if let detail = JiraDecoding.transitionFailure(in: text) {
            throw JiraError.transitionRefused(key: key, status: status, detail: detail)
        }
    }
}

extension JiraDecoding {
    /// Why a transition did not happen, or nil when acli confirmed one. Nothing short of a positive
    /// confirmation counts: output this cannot read is a transition nobody can vouch for, and saying so
    /// costs a needless error message, while assuming success costs a ticket that never moved.
    public static func transitionFailure(in text: String) -> String? {
        let unconfirmed = "acli did not confirm the transition"
        guard let result = try? JSONDecoder().decode(TransitionResult.self, from: Data(text.utf8)) else {
            // Not JSON at all: acli's own "✗ Failure: …" line says it better than anything here could.
            let printed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return printed.isEmpty ? unconfirmed : printed
        }
        if (result.successCount ?? 0) > 0 { return nil }
        let entries = result.results ?? []
        if entries.contains(where: { $0.status?.uppercased() == "SUCCESS" }) { return nil }
        let messages = entries.compactMap(\.message).filter { !$0.isEmpty }
        return messages.isEmpty ? unconfirmed : messages.joined(separator: "; ")
    }

    /// acli's shape for every bulk work item command. Every field is optional: this is read to find out
    /// whether a write landed, so a missing key must not be the thing that decides it did.
    public struct TransitionResult: Decodable {
        public var results: [Entry]?
        public var successCount: Int?

        public struct Entry: Decodable {
            public var id: String?
            public var status: String?
            public var message: String?
        }
    }
}
