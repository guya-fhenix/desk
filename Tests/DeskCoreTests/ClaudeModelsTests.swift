import DeskCore
import Foundation
import Testing

@Suite struct ClaudeModelsTests {
    /// The shape Claude Code caches for `/model`, trimmed to what the picker reads.
    @Test func theCatalogListsEachModelWithItsEffortsAndDefaults() throws {
        let json = #"""
            {"version": 2, "catalog": {
              "config": {"models": [
                {"id": "claude-opus-5-5", "name": "Opus 5.5", "section": "main",
                 "thinking": {"type": "effort", "effort_options": [{"id": "low"}, {"id": "medium"}, {"id": "high"}, {"id": "xhigh"}, {"id": "max"}]}},
                {"id": "claude-fable-5-1", "name": "Fable 5.1", "section": "main",
                 "thinking": {"type": "effort", "effort_options": [{"id": "low"}, {"id": "high"}]}},
                {"id": "claude-haiku-4-5-20251001", "name": "Haiku 4.5", "section": "overflow", "thinking": {"type": "none"}}
              ]},
              "state": {"model": "claude-opus-5-5", "thinking_by_model": [
                {"id": "claude-fable-5-1", "thinking": {"type": "effort", "effort": "high"}},
                {"id": "claude-opus-5-5", "thinking": {"type": "effort", "effort": "medium"}}
              ]}
            }}
            """#
        let catalog = try #require(ClaudeModelCatalog.parse(Data(json.utf8)))
        #expect(catalog.defaultModel == "claude-opus-5-5")
        #expect(catalog.models.map(\.name) == ["Opus 5.5", "Fable 5.1", "Haiku 4.5"])
        #expect(catalog.models.map(\.isMain) == [true, true, false])
        #expect(catalog.model("claude-fable-5-1")?.efforts == ["low", "high"])
        #expect(catalog.model("claude-fable-5-1")?.defaultEffort == "high")
        #expect(catalog.model("claude-haiku-4-5-20251001")?.efforts == [])
        #expect(ClaudeModelCatalog.parse(Data(#"{"catalog": {}}"#.utf8)) == nil)
    }
}
