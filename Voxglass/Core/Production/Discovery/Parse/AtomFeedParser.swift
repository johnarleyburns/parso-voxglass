import Foundation

/// Dependency-free Atom feed parser (NARRATION_NEEDS_SPEC §3.5) over the
/// Foundation `XMLParser`. Used for LibriVox forum feeds (`feed.php?f=28/19`).
public struct AtomFeedParser: Sendable {
    public struct Entry: Sendable, Equatable {
        public var title: String
        public var link: URL?
        public var updated: Date?
        public var content: String

        public init(title: String, link: URL? = nil, updated: Date? = nil, content: String = "") {
            self.title = title
            self.link = link
            self.updated = updated
            self.content = content
        }
    }

    public init() {}

    public func parse(_ data: Data) -> [Entry] {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), !delegate.didFail else { return [] }
        return delegate.entries
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate, @unchecked Sendable {
        var entries: [Entry] = []
        var didFail = false

        private var currentEntry: Entry?
        private var currentElement = ""
        private var textBuffer = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let name = localName(elementName)
            currentElement = name
            textBuffer = ""
            if name == "entry" {
                currentEntry = Entry(title: "")
            } else if name == "link", currentEntry != nil, attributeDict["rel"] == "alternate" || attributeDict["rel"] == nil {
                if let href = attributeDict["href"], let url = URL(string: href) {
                    if currentEntry?.link == nil { currentEntry?.link = url }
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            textBuffer += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let name = localName(elementName)
            let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "entry":
                if var entry = currentEntry, !entry.title.isEmpty {
                    entries.append(entry)
                }
                currentEntry = nil
            case "title":
                if currentEntry != nil, currentEntry?.title.isEmpty == true {
                    currentEntry?.title = text
                }
            case "link":
                break
            case "updated":
                if currentEntry != nil, let date = NeedsJSONCoding.isoDate(text) {
                    currentEntry?.updated = date
                }
            case "content", "summary":
                if currentEntry != nil, currentEntry?.content.isEmpty == true {
                    currentEntry?.content = text
                }
            default:
                break
            }
            textBuffer = ""
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            didFail = true
        }

        func parser(_ parser: XMLParser, validationErrorOccurred validationError: Error) {
            didFail = true
        }

        private func localName(_ elementName: String) -> String {
            elementName.components(separatedBy: ":").last ?? elementName
        }
    }
}
