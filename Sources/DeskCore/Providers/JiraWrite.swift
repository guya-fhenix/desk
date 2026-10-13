import Foundation

/// The app's writes to Jira. They live in their own file so that fact stays auditable in one place —
/// everything in `JiraProvider.swift` reads. A move happens when you plan a ticket, and on its own when a
/// ticket of yours has fallen behind its pull requests; an edit only when you save one.
extension JiraProvider {
    /// Moves a work item to a status by name. acli works out which transition that is, and refuses when
    /// the workflow has no way there from where the ticket stands.
    ///
    /// Deliberately no retry, for the same reason `postDraft` has none: a failure reported after the
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

extension JiraProvider {
    /// Saves a new summary, or a new description from the markdown the edit box holds, converted to the ADF Jira
    /// stores. The description goes through a file: an ADF document is too long and too quoted for an argument.
    /// Like a transition, acli exits 0 whether or not the edit landed, so its answer is read, not its exit code.
    public func edit(key: String, summary: String? = nil, description markdown: String? = nil) async throws {
        var arguments = ["jira", "workitem", "edit", "--key", key, "--yes", "--json"]
        if let summary { arguments += ["--summary", summary] }
        var file: URL?
        if let markdown {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("desk-\(key)-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: JiraDescription.adf(fromMarkdown: markdown)).write(to: url)
            file = url
            arguments += ["--description-file", url.path]
        }
        defer { if let file { try? FileManager.default.removeItem(at: file) } }
        let text: String
        do {
            text = try await Shell.output(acliPath, arguments, timeout: 60)
        } catch let error as ShellError {
            switch error {
            case .executableNotFound: throw JiraError.acliNotFound
            case .failed(_, _, let stderr):
                if stderr.lowercased().contains("unauthorized") { throw JiraError.notAuthenticated }
                throw JiraError.editRefused(key: key, detail: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            case .timedOut: throw error
            }
        }
        if let detail = JiraDecoding.writeFailure(in: text, unconfirmed: "acli did not confirm the edit") {
            throw JiraError.editRefused(key: key, detail: detail)
        }
    }
}

extension JiraDecoding {
    /// Why a transition did not happen, or nil when acli confirmed one. Nothing short of a positive
    /// confirmation counts: output this cannot read is a transition nobody can vouch for, and saying so
    /// costs a needless error message, while assuming success costs a ticket that never moved.
    public static func transitionFailure(in text: String) -> String? {
        writeFailure(in: text, unconfirmed: "acli did not confirm the transition")
    }

    /// The same reading of acli's answer for any write to work items — a transition, an edit.
    public static func writeFailure(in text: String, unconfirmed: String) -> String? {
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
