import Foundation

/// Whether a newer Desk is out: the latest release of the repo `scripts/release.sh` publishes to, read through gh, against
/// the version this app is. The sidebar suggests updating; nothing is downloaded or installed here.
public enum AppUpdate {
    /// A newer release than this app: the version you have and the one that is out.
    public struct Available: Sendable, Equatable {
        public var current: String
        public var latest: String

        public init(current: String, latest: String) {
            self.current = current
            self.latest = latest
        }
    }

    public static let repo = "guya-fhenix/desk"
    public static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!

    /// The latest release's version, "1.1.7" off its tag "v1.1.7"; nil when gh cannot say: not signed in, no access to
    /// the repo, offline. Asking again later is the whole of the error handling.
    public static func latest(gh: String, run: ShellRun = Shell.run) async -> String? {
        guard let tag = try? await Shell.output(gh, ["api", "repos/\(repo)/releases/latest", "--jq", ".tag_name"], timeout: 30, run: run)
        else { return nil }
        let version = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : String(version.trimmingPrefix("v"))
    }

    /// The update to suggest, when `latest` comes after `current` number by number: 1.1.10 is after 1.1.9, and 1.2
    /// equals 1.2.0. Nil when this app is that version or later.
    public static func available(latest: String, current: String) -> Available? {
        let parts = { (version: String) in version.split(separator: ".").map { Int($0) ?? 0 } }
        let (new, old) = (parts(latest), parts(current))
        let count = max(new.count, old.count)
        let padded = { (numbers: [Int]) in numbers + Array(repeating: 0, count: count - numbers.count) }
        return padded(old).lexicographicallyPrecedes(padded(new)) ? Available(current: current, latest: latest) : nil
    }
}
