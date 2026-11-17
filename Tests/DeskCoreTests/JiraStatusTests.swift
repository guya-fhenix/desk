import DeskCore
import Foundation
import Testing

struct JiraStatusTests {
    /// PRO's statuses, as Jira files them.
    private let pro = [
        JiraStatus(name: "To Do", category: .todo), JiraStatus(name: "👀 Review Ready", category: .inProgress),
        JiraStatus(name: "Done", category: .done), JiraStatus(name: "⛔ Blocked", category: .todo),
        JiraStatus(name: "In Progress", category: .inProgress), JiraStatus(name: "✋ Stuck", category: .todo),
    ]

    @Test func suggestsFromNamesAndCategories() {
        #expect(JiraStatus.suggested(.inProgress, in: pro) == "In Progress")
        #expect(JiraStatus.suggested(.review, in: pro) == "👀 Review Ready")
        #expect(JiraStatus.suggested(.done, in: pro) == "Done")
        // Nothing named for review: you pick. Work under another name still counts as in progress.
        let plain = [JiraStatus(name: "Doing", category: .inProgress), JiraStatus(name: "Shipped", category: .done)]
        #expect(JiraStatus.suggested(.review, in: plain) == nil)
        #expect(JiraStatus.suggested(.inProgress, in: plain) == "Doing")
        #expect(JiraStatus.suggested(.done, in: plain) == "Shipped")
    }

    @Test func orderedByCategoryThenAsFound() {
        #expect(JiraStatus.ordered(pro).map(\.name) == ["To Do", "⛔ Blocked", "✋ Stuck", "👀 Review Ready", "In Progress", "Done"])
    }

    @Test func readsTheFirstItemsStatus() throws {
        let item = Data(#"[{"key":"PRO-1","fields":{"status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}}}}]"#.utf8)
        #expect(try JiraDecoding.firstStatus(from: item) == JiraStatus(name: "In Progress", category: .inProgress))
        #expect(try JiraDecoding.firstStatus(from: Data("[]".utf8)) == nil)
        #expect(try JiraDecoding.firstStatus(from: Data("\n".utf8)) == nil)
        #expect(JiraDecoding.quoted(#"say "hi" \ bye"#) == #""say \"hi\" \\ bye""#)
    }

    /// One search per status, each leaving out the ones found, until none is left; then ordered.
    @Test func findsAProjectsStatusesOneSearchAtATime() async throws {
        let all = pro
        let searches = Searches()
        let jira = JiraProvider(acliPath: "/acli") { _, arguments, _, _, _, _ in
            let jql = arguments[arguments.firstIndex(of: "--jql")! + 1]
            await searches.add(jql)
            let next = all.first { !jql.contains(JiraDecoding.quoted($0.name)) }
            let json = next.map { status in
                let key = status.category == .done ? "done" : status.category == .inProgress ? "indeterminate" : "new"
                return #"[{"key":"PRO-1","fields":{"status":{"name":"\#(status.name)","statusCategory":{"key":"\#(key)"}}}}]"#
            } ?? ""
            return ShellResult(status: 0, stdout: Data(json.utf8))
        }
        let found = try await jira.statuses(project: "PRO")
        #expect(found == JiraStatus.ordered(pro))
        let jqls = await searches.all
        #expect(jqls.count == pro.count + 1)
        #expect(jqls.first == #"project = "PRO""#)
        #expect(jqls.last?.hasPrefix(#"project = "PRO" AND status not in ("To Do", "👀 Review Ready""#) == true)
    }
}

private actor Searches {
    var all: [String] = []
    func add(_ jql: String) { all.append(jql) }
}
