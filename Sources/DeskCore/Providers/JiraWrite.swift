import Foundation

/// The app's writes to Jira. They live in their own file so that fact stays auditable in one place —
/// everything in `JiraProvider.swift` reads. A move happens when you plan a ticket, and when you press Move on
/// a ticket of yours that has fallen behind its pull requests; an edit only when you save one.
extension JiraProvider {
    /// Moves a work item to a status, through `via` first when the workflow has no transition straight there
    /// from where it stands: a workflow that wants work started before it is ready for review has no way from
    /// To Do to Review Ready, only to In Progress and on from there. Only that refusal steps through `via` — it
    /// says nothing happened — so a workflow that allows the move makes the one transition it always did, and
    /// any other failure is reported as it is.
    public func transition(key: String, to status: String, via: String?) async throws {
        do {
            try await transition(key: key, to: status)
        } catch JiraError.transitionRefused(_, _, let detail)
            where JiraDecoding.isNoTransition(detail) && via.map({ !$0.isEmpty && $0 != status }) == true {
            try await transition(key: key, to: via!)
            do {
                try await transition(key: key, to: status)
            } catch {
                throw JiraError.transitionRefused(key: key, status: status, detail: "moved to “\(via!)”, but then: \(error)")
            }
        }
    }

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
                timeout: 60, run: run
            )
        } catch {
            throw Self.mapAcliError(error) { JiraError.transitionRefused(key: key, status: status, detail: $0) }
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
            text = try await Shell.output(acliPath, arguments, timeout: 60, run: run)
        } catch {
            throw Self.mapAcliError(error) { JiraError.editRefused(key: key, detail: $0) }
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

    /// Whether a refused transition was refused for want of a way there from the ticket's status — acli's own words for
    /// it — which, unlike an unconfirmed one, says the ticket did not move.
    public static func isNoTransition(_ detail: String) -> Bool {
        detail.localizedCaseInsensitiveContains("No allowed transitions")
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
