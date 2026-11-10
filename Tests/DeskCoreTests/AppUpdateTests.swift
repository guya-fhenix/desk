import DeskCore
import Foundation
import Testing

@Suite struct AppUpdateTests {
    /// The sidebar suggests updating only to a later release, compared number by number rather than as text.
    @Test func aLaterReleaseIsSuggestedNumberByNumber() {
        #expect(AppUpdate.available(latest: "1.1.7", current: "1.1.6") == AppUpdate.Available(current: "1.1.6", latest: "1.1.7"))
        #expect(AppUpdate.available(latest: "1.1.10", current: "1.1.9") != nil, "10 after 9, not before it as text")
        #expect(AppUpdate.available(latest: "1.2", current: "1.1.9") != nil)
        #expect(AppUpdate.available(latest: "1.1.6", current: "1.1.6") == nil)
        #expect(AppUpdate.available(latest: "1.2", current: "1.2.0") == nil)
        #expect(AppUpdate.available(latest: "1.1.5", current: "1.1.6") == nil, "a build ahead of the release is not told to go back")
    }

    /// The latest release's tag, without its v; nothing when gh cannot say, which is asked again later.
    @Test func theLatestVersionIsReadOffTheReleaseTag() async {
        let tag: ShellRun = { _, arguments, _, _, _, _ in
            #expect(arguments == ["api", "repos/guya-fhenix/desk/releases/latest", "--jq", ".tag_name"])
            return ShellResult(status: 0, stdout: Data("v1.1.7\n".utf8))
        }
        #expect(await AppUpdate.latest(gh: "/gh", run: tag) == "1.1.7")
        let refused: ShellRun = { _, _, _, _, _, _ in ShellResult(status: 1, stdout: Data(), stderr: "HTTP 404: Not Found") }
        #expect(await AppUpdate.latest(gh: "/gh", run: refused) == nil)
    }
}
