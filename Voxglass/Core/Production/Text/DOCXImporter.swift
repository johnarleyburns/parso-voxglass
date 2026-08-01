import Foundation

public struct DOCXImporter: SourceImporting {
    public let format: SourceFormat = .docx

    public init() {}

    public func canImport(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "docx"
    }

    public func extract(from url: URL) async throws -> ExtractedDocument {
        let zipData = try Data(contentsOf: url)
        let zip = try ZipReader(data: zipData)

        guard let docEntry = zip.entry(named: "word/document.xml") else {
            throw ImportError.missingContainer
        }
        let docXML = try zip.read(docEntry)
        guard let xmlString = String(data: docXML, encoding: .utf8) else {
            throw ImportError.malformedXML("document.xml not valid UTF-8")
        }

        let parsed = parseDocumentXML(xmlString)
        let blocks = parsed.blocks
        let plainText = blocks.map(\.text).joined(separator: "\n\n")

        var charOffset = 0
        let extractedBlocks: [ExtractedBlock] = blocks.map { b in
            let r = charOffset..<(charOffset + b.text.count)
            charOffset += b.text.count + 2
            return ExtractedBlock(kind: b.kind, text: b.text, sourceRange: r, headingLevel: b.headingLevel)
        }

        return ExtractedDocument(
            sections: [ExtractedSection(blocks: extractedBlocks, sourceStart: 0)],
            title: url.deletingPathExtension().lastPathComponent,
            warnings: parsed.warnings,
            plainText: plainText
        )
    }

    private struct ParsedDoc {
        var blocks: [(kind: BlockKind, text: String, headingLevel: Int?)]
        var warnings: [ImportWarning]
    }

    private func parseDocumentXML(_ xml: String) -> ParsedDoc {
        var blocks: [(kind: BlockKind, text: String, headingLevel: Int?)] = []
        var currentRuns: [String] = []
        var currentStyle: String? = nil
        var warnings: [ImportWarning] = []

        func flushBlock() {
            let text = currentRuns.joined(separator: " ")
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                let (kind, level) = classifyStyle(currentStyle)
                blocks.append((kind, text.trimmingCharacters(in: .whitespaces), level))
            }
            currentRuns = []
            currentStyle = nil
        }

        if let pStyleRegex = try? NSRegularExpression(pattern: #"<w:p[^>]*>(.*?)</w:p>"#, options: [.dotMatchesLineSeparators]) {
            let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
            pStyleRegex.enumerateMatches(in: xml, range: range) { match, _, _ in
                guard let match = match, let pRange = Range(match.range(at: 1), in: xml) else { return }
                let pContent = String(xml[pRange])

                var style: String? = nil
                if let styleMatch = pContent.range(of: #"<w:pStyle w:val="([^"]+)""#, options: .regularExpression) {
                    style = String(pContent[styleMatch]).replacingOccurrences(of: "<w:pStyle w:val=\"", with: "")
                        .replacingOccurrences(of: "\"/>", with: "").replacingOccurrences(of: "\"/>", with: "")
                        .replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "/>", with: "")
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\" />"))
                }

                if let tableMatch = pContent.range(of: "<w:tbl", options: .caseInsensitive) {
                    warnings.append(ImportWarning(kind: .skippedNonProse, message: "Table skipped"))
                    return
                }

                let tRegex = try! NSRegularExpression(pattern: #"<w:t[^>]*>([^<]*)</w:t>"#)
                let tRange = NSRange(pContent.startIndex..<pContent.endIndex, in: pContent)
                var runs: [String] = []
                tRegex.enumerateMatches(in: pContent, range: tRange) { tMatch, _, _ in
                    guard let tMatch = tMatch, let r = Range(tMatch.range(at: 1), in: pContent) else { return }
                    runs.append(String(pContent[r]))
                }

                if !runs.isEmpty {
                    let text = runs.joined(separator: " ")
                    let (kind, level) = classifyStyle(style)
                    blocks.append((kind, text.trimmingCharacters(in: .whitespaces), level))
                }
            }
        }

        return ParsedDoc(blocks: blocks, warnings: warnings)
    }

    private func classifyStyle(_ style: String?) -> (BlockKind, Int?) {
        guard let style = style else { return (.paragraph, nil) }
        let lower = style.lowercased()
        if lower.contains("heading") || lower == "title" {
            let digits = lower.compactMap { $0.isNumber ? Int(String($0)) : nil }
            if let level = digits.first {
                return (.heading, min(max(level, 1), 6))
            }
            return (.heading, 1)
        }
        if lower.contains("list") || lower.contains("bullet") { return (.listItem, nil) }
        if lower.contains("quote") { return (.blockquote, nil) }
        return (.paragraph, nil)
    }
}
