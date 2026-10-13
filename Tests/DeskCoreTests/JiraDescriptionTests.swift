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

    func node(_ json: String) -> ADFNode? { try? JSONDecoder().decode(ADFNode.self, from: Data(json.utf8)) }

    /// An edit saves the markdown back as ADF; read again, it says the same as before, for every node that converts.
    @Test func aDescriptionGoesBackAsItCameIn() throws {
        let original = """
        {"type":"doc","content":[
          {"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"Problem"}]},
          {"type":"paragraph","content":[
            {"type":"text","text":"Run "},{"type":"text","text":"make test","marks":[{"type":"code"}]},
            {"type":"text","text":", then "},{"type":"text","text":"check","marks":[{"type":"strong"}]},
            {"type":"text","text":" the "},{"type":"text","text":"logs","marks":[{"type":"em"}]},{"type":"text","text":" "},
            {"type":"text","text":"here","marks":[{"type":"link","attrs":{"href":"https://example.com/a"}}]},
            {"type":"hardBreak"},{"type":"text","text":"Glob: deployments/** and a*b*c"}
          ]},
          {"type":"bulletList","content":[
            {"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"one"}]},
              {"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"nested"}]}]}]}]},
            {"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"two"}]}]}
          ]},
          {"type":"orderedList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"first"}]}]}]},
          {"type":"codeBlock","attrs":{"language":"swift"},"content":[{"type":"text","text":"let x = 1"}]},
          {"type":"blockquote","content":[{"type":"paragraph","content":[{"type":"text","text":"quoted"}]}]},
          {"type":"rule"},
          {"type":"table","content":[
            {"type":"tableRow","content":[{"type":"tableHeader","content":[{"type":"paragraph","content":[{"type":"text","text":"A"}]}]}]},
            {"type":"tableRow","content":[{"type":"tableCell","content":[{"type":"paragraph","content":[{"type":"text","text":"1"}]}]}]}
          ]}
        ]}
        """
        let first = try #require(node(original))
        #expect(JiraDescription.roundTrips(first))
        let markdown = JiraDescription.markdown(first)
        #expect(markdown.contains("[here](https://example.com/a)"))
        // Literal asterisks are escaped, so they do not come back as emphasis.
        #expect(markdown.contains("deployments/\\*\\* and a\\*b\\*c"))
        let written = try JSONSerialization.data(withJSONObject: JiraDescription.adf(fromMarkdown: markdown))
        let second = try JSONDecoder().decode(ADFNode.self, from: written)
        #expect(JiraDescription.markdown(second) == markdown)
        #expect(String(decoding: written, as: UTF8.self).contains(#""text":"Glob: deployments\/** and a*b*c""#))
    }

    /// What the markdown cannot carry makes the description one to edit in Jira instead.
    @Test func aDescriptionWithAMentionOrAnImageIsNotEditableHere() {
        let mention = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"mention","attrs":{"id":"1"}}]}]}"#
        let underline = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"u","marks":[{"type":"underline"}]}]}]}"#
        let image = #"{"type":"doc","content":[{"type":"mediaSingle","content":[{"type":"media"}]}]}"#
        for json in [mention, underline, image] { #expect(JiraDescription.roundTrips(node(json)) == false, "\(json)") }
        #expect(JiraDescription.roundTrips(nil))
    }

    /// A bare address becomes a link, as the inline card it was read from was one.
    @Test func aBareAddressGoesBackAsALink() throws {
        let adf = JiraDescription.adf(fromMarkdown: "See https://github.com/o/r/pull/1 now")
        let text = String(decoding: try JSONSerialization.data(withJSONObject: adf), as: UTF8.self)
        #expect(text.contains(#""href":"https:\/\/github.com\/o\/r\/pull\/1""#))
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
        #expect(text == "One\\\nTwo")
        #expect(Markdown.blocks(text) == [.paragraph("One\nTwo")])
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

    /// A table stays a table: header cells become the header row, and a pipe or break inside a cell
    /// cannot split its row.
    @Test func aTableBecomesAPipeTable() {
        let text = markdown("""
        {"type":"doc","content":[{"type":"table","content":[
          {"type":"tableRow","content":[
            {"type":"tableHeader","content":[{"type":"paragraph","content":[{"type":"text","text":"Policy"}]}]},
            {"type":"tableHeader","content":[{"type":"paragraph","content":[{"type":"text","text":"Condition"}]}]}
          ]},
          {"type":"tableRow","content":[
            {"type":"tableCell","content":[{"type":"paragraph","content":[{"type":"text","text":"a|b"}]}]},
            {"type":"tableCell","content":[{"type":"paragraph","content":[
              {"type":"text","text":"one"},{"type":"hardBreak"},{"type":"text","text":"two"}
            ]}]}
          ]}
        ]}]}
        """)
        #expect(text == "| Policy | Condition |\n| --- | --- |\n| a\\|b | one two |")
        #expect(Markdown.blocks(text) == [.table(header: ["Policy", "Condition"], rows: [["a|b", "one two"]])])
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
