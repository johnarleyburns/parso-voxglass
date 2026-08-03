import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct AtomFeedParserTests {

    let parser = AtomFeedParser()

    @Test func parsesAtomEntries() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>LibriVox Forum Feed</title>
          <entry>
            <title>[WEEKLY POETRY] - Hope is the thing with feathers by Emily Dickinson</title>
            <link rel="alternate" href="https://forum.librivox.org/viewtopic.php?t=12345"/>
            <updated>2026-08-01T18:30:00Z</updated>
            <content>Some first-post text here.</content>
          </entry>
          <entry>
            <title>[OPEN] - The Time Machine by H. G. Wells</title>
            <link href="https://forum.librivox.org/viewtopic.php?t=12346"/>
            <updated>2026-08-02T10:00:00Z</updated>
          </entry>
        </feed>
        """
        let entries = parser.parse(Data(xml.utf8))
        #expect(entries.count == 2)
        #expect(entries[0].title.contains("[WEEKLY POETRY]"))
        #expect(entries[0].link?.absoluteString.contains("viewtopic.php?t=12345") == true)
        #expect(entries[0].updated != nil)
        #expect(entries[0].content.contains("first-post"))
        #expect(entries[1].title.contains("[OPEN]"))
    }

    @Test func malformedXMLYieldsNothing() {
        let entries = parser.parse(Data("<feed><entry><title>unclosed".utf8))
        #expect(entries.isEmpty)
    }

    @Test func nonFeedDocumentYieldsNothing() {
        let entries = parser.parse(Data("<html><body>hello</body></html>".utf8))
        #expect(entries.isEmpty)
    }
}
