import Foundation

public struct EPUBImporter: SourceImporting {
    public let format: SourceFormat = .epub

    public init() {}

    public func canImport(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "epub"
    }

    public func extract(from url: URL) async throws -> ExtractedDocument {
        let zipData = try Data(contentsOf: url)
        let zip = try ZipReader(data: zipData)

        guard let containerEntry = zip.entry(named: "META-INF/container.xml") else {
            // §19.3: a malformed EPUB must fall back, not throw.
            return ExtractedDocument(
                sections: [],
                title: url.deletingPathExtension().lastPathComponent,
                warnings: [ImportWarning(kind: .emptySection, message: "Not a valid EPUB: missing META-INF/container.xml")]
            )
        }
        let containerXML = try zip.read(containerEntry)

        guard let opfPath = try? parseOPFPath(from: containerXML),
              let opfEntry = zip.entry(named: opfPath) else {
            return ExtractedDocument(
                sections: [],
                title: url.deletingPathExtension().lastPathComponent,
                warnings: [ImportWarning(kind: .emptySection, message: "Not a valid EPUB: missing or unreadable package document")]
            )
        }
        let opfXML = try zip.read(opfEntry)
        let opfDir = (opfPath as NSString).deletingLastPathComponent

        let opf = try parseOPF(opfXML)
        var warnings: [ImportWarning] = []
        var allSections: [ExtractedSection] = []
        var plainTextParts: [String] = []

        for item in opf.spine {
            let href = resolveHREF(item.1, relativeTo: opfDir)

            guard let xhtmlEntry = zip.entry(named: href),
                  let xhtmlData = try? zip.read(xhtmlEntry),
                  let xhtmlString = String(data: xhtmlData, encoding: .utf8) else {
                continue
            }

            let parsed = parseXHTML(xhtmlString)
            if parsed.blocks.isEmpty {
                warnings.append(ImportWarning(kind: .emptySection, message: "Empty section: \(href)"))
                continue
            }

            let sectionPlain = parsed.blocks.map(\.text).joined(separator: "\n\n")
            let sourceStart = plainTextParts.map(\.count).reduce(0, +) + max(0, plainTextParts.count) * 2

            allSections.append(ExtractedSection(
                heading: parsed.heading,
                blocks: parsed.blocks.map { block in
                    let start = plainTextParts.map(\.count).reduce(0, +) + max(0, plainTextParts.count) * 2
                    return ExtractedBlock(
                        kind: block.kind, text: block.text,
                        sourceRange: start..<(start + block.text.count),
                        headingLevel: block.headingLevel
                    )
                },
                sourceStart: sourceStart
            ))
            plainTextParts.append(sectionPlain)
            warnings.append(contentsOf: parsed.warnings)
        }

        return ExtractedDocument(
            sections: allSections,
            title: opf.title,
            author: opf.author,
            language: opf.language,
            warnings: warnings,
            plainText: plainTextParts.joined(separator: "\n\n")
        )
    }

    // MARK: - XML helpers

    private func parseOPFPath(from containerXML: Data) throws -> String {
        let xml = String(data: containerXML, encoding: .utf8) ?? ""
        guard let match = xml.range(of: #"full-path="([^"]+)""#, options: .regularExpression) else {
            throw ImportError.malformedXML("container.xml missing rootfile full-path")
        }
        let matched = String(xml[match])
        // Strip `full-path="` (11 chars: the `=` and the opening quote) and
        // the trailing quote that the regex includes.
        return String(matched.dropFirst(11).dropLast())
    }

    private struct OPFInfo {
        var title: String?; var author: String?; var language: String?
        var spine: [(String, String)]
    }

    private func parseOPF(_ xmlData: Data) throws -> OPFInfo {
        let xml = String(data: xmlData, encoding: .utf8) ?? ""
        var info = OPFInfo(spine: [])

        if let r = xml.range(of: #"<dc:title[^>]*>([^<]+)</dc:title>"#, options: .regularExpression) {
            info.title = String(xml[r]).replacingOccurrences(of: "</?dc:title[^>]*>", with: "", options: .regularExpression)
        }
        if let r = xml.range(of: #"<dc:creator[^>]*>([^<]+)</dc:creator>"#, options: .regularExpression) {
            info.author = String(xml[r]).replacingOccurrences(of: "</?dc:creator[^>]*>", with: "", options: .regularExpression)
        }
        if let r = xml.range(of: #"<dc:language[^>]*>([^<]+)</dc:language>"#, options: .regularExpression) {
            info.language = String(xml[r]).replacingOccurrences(of: "</?dc:language[^>]*>", with: "", options: .regularExpression)
        }

        let manifestItems = matchesWithThree(of: #"<item[^>]*id="([^"]+)"[^>]*href="([^"]+)"[^>]*media-type="([^"]+)"[^>]*/?>"#, in: xml)
        var manifestHrefs: [String: String] = [:]
        for item in manifestItems {
            if item.2.contains("xhtml") || item.2.contains("xml") {
                manifestHrefs[item.1] = item.0  // id → href
            }
        }

        let spineRefs = matchesSingleCapture(of: #"<itemref[^>]*idref="([^"]+)"#, in: xml)
        for ref in spineRefs {
            if let href = manifestHrefs[ref] {
                info.spine.append((ref, href))
            } else {
                info.spine.append((ref, ref + ".xhtml"))
            }
        }

        return info
    }

    private func matchesWithTwo(of pattern: String, in text: String) -> [(String, String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var results: [(String, String)] = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match, let r1 = Range(match.range(at: 1), in: text),
                  let r2 = Range(match.range(at: 2), in: text) else { return }
            results.append((String(text[r1]), String(text[r2])))
        }
        return results
    }

    private func matchesWithThree(of pattern: String, in text: String) -> [(String, String, String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var results: [(String, String, String)] = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match, match.numberOfRanges >= 4,
                  let r1 = Range(match.range(at: 1), in: text),
                  let r2 = Range(match.range(at: 2), in: text),
                  let r3 = Range(match.range(at: 3), in: text) else { return }
            results.append((String(text[r1]), String(text[r2]), String(text[r3])))
        }
        return results
    }

    private func matchesSingleCapture(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var results: [String] = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match, match.numberOfRanges >= 2,
                  let r1 = Range(match.range(at: 1), in: text) else { return }
            results.append(String(text[r1]))
        }
        return results
    }

    private func resolveHREF(_ href: String, relativeTo dir: String) -> String {
        if href.hasPrefix("/") { return String(href.dropFirst()) }
        if dir.isEmpty { return href }
        let resolved = (dir as NSString).appendingPathComponent(href)
        return resolved.replacingOccurrences(of: "/./", with: "/")
    }

    // MARK: - XHTML parsing

    private struct ParsedXHTML {
        var heading: String?
        var blocks: [(kind: BlockKind, text: String, headingLevel: Int?)]
        var warnings: [ImportWarning]
    }

    private func parseXHTML(_ xhtml: String) -> ParsedXHTML {
        var warnings: [ImportWarning] = []
        if xhtml.contains("<img") || xhtml.contains("<svg") {
            warnings.append(ImportWarning(kind: .imageOnlyContent, message: "Image/SVG content dropped"))
        }
        if xhtml.contains("<table") {
            warnings.append(ImportWarning(kind: .skippedNonProse, message: "Table content skipped"))
        }

        // <head> holds metadata (title, styles), never prose — drop it so it
        // cannot become a phantom paragraph (§9.1).
        let body = stripHead(xhtml)

        // Find heading elements in document order; the runs between them are
        // prose paragraphs. A spine item whose first block is a heading gets
        // that heading as its chapter title (spec §9.2).
        var blocks: [(kind: BlockKind, text: String, headingLevel: Int?)] = []
        var scanIndex = body.startIndex
        var firstHeading: (level: Int, text: String)? = nil

        let headingPattern = #"<h([1-6])[^>]*>(.*?)</h\1>"#
        let headingRegex = try? NSRegularExpression(pattern: headingPattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
        let nsRange = NSRange(body.startIndex..<body.endIndex, in: body)

        headingRegex?.enumerateMatches(in: body, range: nsRange) { match, _, _ in
            guard let match = match,
                  let openRange = Range(match.range, in: body),
                  let levelStrRange = Range(match.range(at: 1), in: body),
                  let innerRange = Range(match.range(at: 2), in: body),
                  let level = Int(body[levelStrRange]) else { return }

            // Paragraph run before this heading.
            let run = String(body[scanIndex..<openRange.lowerBound])
            blocks.append(contentsOf: paragraphBlocks(from: run))

            let headingText = cleanText(body[innerRange])
            if firstHeading == nil {
                firstHeading = (level, headingText)
            }
            blocks.append((.heading, headingText, min(level, 6)))
            scanIndex = openRange.upperBound
        }

        // Trailing run after the last heading.
        if scanIndex < body.endIndex {
            blocks.append(contentsOf: paragraphBlocks(from: String(body[scanIndex...])))
        }

        return ParsedXHTML(heading: firstHeading?.text, blocks: blocks, warnings: warnings)
    }

    private func stripHead(_ xhtml: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<head[^>]*>.*?</head>"#, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return xhtml }
        let range = NSRange(xhtml.startIndex..<xhtml.endIndex, in: xhtml)
        return regex.stringByReplacingMatches(in: xhtml, range: range, withTemplate: "")
    }

    private func paragraphBlocks(from fragment: String) -> [(kind: BlockKind, text: String, headingLevel: Int?)] {
        let stripped = stripTags(fragment)
        let lines = stripped.components(separatedBy: "\n")
        var result: [(kind: BlockKind, text: String, headingLevel: Int?)] = []
        var currentBlock: [String] = []

        func flush() {
            if !currentBlock.isEmpty {
                result.append((.paragraph, currentBlock.joined(separator: " "), nil))
                currentBlock = []
            }
        }

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty {
                flush()
            } else {
                currentBlock.append(trimmedLine)
            }
        }
        flush()
        return result
    }

    private func cleanText(_ s: Substring) -> String {
        let stripped = String(s).replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return decodeEntities(stripped)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&rsquo;", with: "'")
            .replacingOccurrences(of: "&lsquo;", with: "'")
            .replacingOccurrences(of: "&rdquo;", with: "\"")
            .replacingOccurrences(of: "&ldquo;", with: "\"")
            .replacingOccurrences(of: "&mdash;", with: "-")
            .replacingOccurrences(of: "&ndash;", with: "-")
            .replacingOccurrences(of: "&hellip;", with: "...")
            .replacingOccurrences(of: "&eacute;", with: "é")
            .replacingOccurrences(of: "&egrave;", with: "è")
            .replacingOccurrences(of: "&auml;", with: "ä")
            .replacingOccurrences(of: "&ouml;", with: "ö")
            .replacingOccurrences(of: "&uuml;", with: "ü")
            .replacingOccurrences(of: "&Auml;", with: "Ä")
            .replacingOccurrences(of: "&Ouml;", with: "Ö")
            .replacingOccurrences(of: "&Uuml;", with: "Ü")
            .replacingOccurrences(of: "&szlig;", with: "ß")
            .replacingOccurrences(of: "&agrave;", with: "à")
            .replacingOccurrences(of: "&acirc;", with: "â")
            .replacingOccurrences(of: "&ocirc;", with: "ô")
            .replacingOccurrences(of: "&icirc;", with: "î")
            .replacingOccurrences(of: "&ucirc;", with: "û")
            .replacingOccurrences(of: "&ccedil;", with: "ç")
            .replacingOccurrences(of: "&Ccedil;", with: "Ç")
    }

    private func stripTags(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else { return html }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var result = regex.stringByReplacingMatches(in: html, range: range, withTemplate: "\n")
        result = result.replacingOccurrences(of: "\n\n+", with: "\n", options: .regularExpression)
        return decodeEntities(result)
    }
}

enum ImportError: Error {
    case missingContainer
    case missingOPF(String)
    case malformedXML(String)
}
