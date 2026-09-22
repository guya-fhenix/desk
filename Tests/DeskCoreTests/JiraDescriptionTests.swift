import DeskCore
import Foundation
import Testing

/// Jira's description is somebody else's tree in somebody else's format, so what matters is that every
/// shape it arrives in comes out as text a person can read — and that an unfamiliar one loses its
/// wrapping rather than its words.
@Suite struct JiraDescriptionTests {
    func markdown(_ json: String) -> String {
        guard let node = try? JSONDecoder().decode(ADFNode.self, from: Data(json.utf8)) else {
            Issue.record("ADF did not decode")
            return ""
        }
        return JiraDescription.markdown(node)
    }

    @Test func paragraphsBecomeBlocks() {
        let text = markdown("""
        {"type":"doc","content":[
          {"type":"paragraph","content":[{"type":"text","text":"First."}]},
          {"type":"paragraph","content":[{"type":"text","text":"Second."}]}
        ]}
        """)
        #expect(text == "First.\n\nSecond.")
    }

    @Test func marksBecomeTheirMarkdown() {
        let text = markdown("""
        {"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"text","text":"is_done","marks":[{"type":"code"}]},
          {"type":"text","text":" is "},
          {"type":"text","text":"false","marks":[{"type":"strong"}]},
          {"type":"text","text":" — see ","marks":[]},
          {"type":"text","text":"the PR","marks":[{"type":"link","attrs":{"url":"https://example.com/1"}}]}
        ]}]}
        """)
        #expect(text == "`is_done` is **false** — see [the PR](https://example.com/1)")
    }

    @Test func aHardBreakStaysInsideItsParagraph() {
        let text = markdown("""
        {"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"text","text":"One"},{"type":"hardBreak"},{"type":"text","text":"Two"}
        ]}]}
        """)
        #expect(text == "One\nTwo")
    }

    /// One block, not one per bullet: the renderer reads separated lines as separate paragraphs, and the
    /// list would stop looking like a list.
    @Test func aBulletListIsOneBlock() {
        let text = markdown("""
        {"type":"doc","content":[{"type":"bulletList","content":[
          {"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"Alpha"}]}]},
          {"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"Beta"}]}]}
        ]}]}
        """)
        #expect(text == "- Alpha\n- Beta")
        #expect(Markdown.blocks(text).count == 2)
    }

    @Test func anOrderedListIsNumberedFromOne() {
        let text = markdown("""
        {"type":"doc","content":[{"type":"orderedList","content":[
          {"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"Find them"}]}]},
          {"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"Clear them"}]}]}
        ]}]}
        """)
        #expect(text == "1. Find them\n2. Clear them")
    }

    @Test func headingsCarryTheirLevel() {
        let text = markdown("""
        {"type":"doc","content":[{"type":"heading","attrs":{"level":3},"content":[{"type":"text","text":"The fix"}]}]}
        """)
        #expect(text == "### The fix")
    }

    @Test func aCodeBlockIsFenced() {
        let text = markdown("""
        {"type":"doc","content":[{"type":"codeBlock","attrs":{"language":"sql"},
          "content":[{"type":"text","text":"select 1"}]}]}
        """)
        #expect(text == "```sql\nselect 1\n```")
    }

    /// `Markdown` draws no tables, so a row has to survive as its cells rather than vanish.
    @Test func tableRowsKeepTheirCells() {
        let text = markdown("""
        {"type":"doc","content":[{"type":"table","content":[
          {"type":"tableRow","content":[
            {"type":"tableHeader","content":[{"type":"paragraph","content":[{"type":"text","text":"Policy"}]}]},
            {"type":"tableCell","content":[{"type":"paragraph","content":[{"type":"text","text":"Condition"}]}]}
          ]}
        ]}]}
        """)
        #expect(text == "Policy · Condition")
    }

    @Test func anInlineCardBecomesItsLink() {
        let text = markdown("""
        {"type":"doc","content":[{"type":"paragraph","content":[
          {"type":"inlineCard","attrs":{"url":"https://example.com/2"}}]}]}
        """)
        #expect(text == "https://example.com/2")
    }

    /// A node type nobody here has seen must still surrender its words.
    @Test func anUnknownNodeKeepsItsText() {
        let text = markdown("""
        {"type":"doc","content":[{"type":"panel","content":[
          {"type":"paragraph","content":[{"type":"text","text":"Careful."}]}]}]}
        """)
        #expect(text == "Careful.")
    }

    @Test func nothingIsEmptyRatherThanACrash() {
        #expect(JiraDescription.markdown(nil).isEmpty)
        #expect(markdown(#"{"type":"doc"}"#).isEmpty)
        #expect(markdown(#"{"type":"doc","content":[{"type":"paragraph"}]}"#).isEmpty)
    }
}
