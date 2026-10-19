import Foundation

/// One model Claude Code offers, as its `/model` menu lists it.
public struct ClaudeModel: Sendable, Hashable, Identifiable {
    /// What `--model` takes: "claude-fable-5-1".
    public var id: String
    /// "Fable 5.1".
    public var name: String
    /// In the group `/model` shows first; the rest sit under its "More models".
    public var isMain: Bool
    /// The effort levels it takes, lowest first; empty for a model that takes none.
    public var efforts: [String]
    /// The effort Claude Code runs it at when none is set.
    public var defaultEffort: String?

    public init(id: String, name: String, isMain: Bool, efforts: [String], defaultEffort: String? = nil) {
        self.id = id
        self.name = name
        self.isMain = isMain
        self.efforts = efforts
        self.defaultEffort = defaultEffort
    }
}

/// The models Claude Code offers this account, read from the catalog it caches for `/model`, so the review's model
/// picker lists exactly those, versions and all. The file is Claude Code's and undocumented, so every field is optional
/// and a file that will not read is no catalog: the picker then offers Claude Code's default alone.
public struct ClaudeModelCatalog: Sendable, Hashable {
    public var models: [ClaudeModel]
    /// The model Claude Code runs when none is named.
    public var defaultModel: String?

    public init(models: [ClaudeModel], defaultModel: String?) {
        self.models = models
        self.defaultModel = defaultModel
    }

    public static let directory = ClaudeJobs.home + "/cache/model-catalog"

    public func model(_ id: String) -> ClaudeModel? { models.first { $0.id == id } }

    /// The newest of Claude Code's own catalogs, `*-cc.json`; the others there are other apps'.
    public static func read(directory: String = directory) -> ClaudeModelCatalog? {
        let folder = URL(fileURLWithPath: directory)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = files.filter { $0.lastPathComponent.hasSuffix("-cc.json") }.max { modified($0) < modified($1) }
        guard let newest, let data = try? Data(contentsOf: newest) else { return nil }
        return parse(data)
    }

    public static func parse(_ data: Data) -> ClaudeModelCatalog? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let file = try? decoder.decode(File.self, from: data), let entries = file.catalog?.config?.models, !entries.isEmpty else { return nil }
        let defaults = Dictionary((file.catalog?.state?.thinkingByModel ?? []).map { ($0.id, $0.thinking?.effort) }, uniquingKeysWith: { first, _ in first })
        let models = entries.map { entry in
            ClaudeModel(
                id: entry.id, name: entry.name ?? entry.id, isMain: entry.section == "main",
                efforts: (entry.thinking?.effortOptions ?? []).map(\.id), defaultEffort: defaults[entry.id] ?? nil
            )
        }
        return ClaudeModelCatalog(models: models, defaultModel: file.catalog?.state?.model)
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private struct File: Decodable {
        struct Catalog: Decodable {
            var config: Config?
            var state: State?
        }

        struct Config: Decodable { var models: [Model]? }

        struct Model: Decodable {
            var id: String
            var name: String?
            var section: String?
            var thinking: Thinking?
        }

        struct Thinking: Decodable {
            struct Option: Decodable { var id: String }

            var effortOptions: [Option]?
            var effort: String?
        }

        struct State: Decodable {
            struct ByModel: Decodable {
                var id: String
                var thinking: Thinking?
            }

            var model: String?
            var thinkingByModel: [ByModel]?
        }

        var catalog: Catalog?
    }
}
