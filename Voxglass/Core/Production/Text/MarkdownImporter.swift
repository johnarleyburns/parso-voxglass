import Foundation

public struct MarkdownImporter: SourceImporting {
    public let format: SourceFormat = .markdown

    public init() {}

    public func canImport(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown" || ext == "mkdn" || ext == "mdown"
    }

    public func extract(from url: URL) async throws -> ExtractedDocument {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let (title, author, language, metadataEndIndex) = parseFrontMatter(raw)
        let bodyText = String(raw[raw.index(raw.startIndex, offsetBy: metadataEndIndex)...])

        let sections = parseSections(bodyText)
        let plainText = sections.flatMap { $0.blocks }.map(\.text).joined(separator: "\n\n")
        let warnings = collectWarnings(sections, input: bodyText)

        return ExtractedDocument(
            sections: sections,
            title: title ?? url.deletingPathExtension().lastPathComponent,
            author: author,
            language: language,
            warnings: warnings,
            plainText: plainText
        )
    }

    // MARK: - Front matter

    private func parseFrontMatter(_ raw: String) -> (title: String?, author: String?, language: String?, offset: Int) {
        let lines = raw.components(separatedBy: "\n")
        guard let firstLine = lines.first, firstLine.trimmingCharacters(in: .whitespaces) == "---" else {
            return (nil, nil, nil, 0)
        }

        var title: String? = nil
        var author: String? = nil
        var language: String? = nil
        var endIndex = 0

        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                var count = 0
                for j in 0...i { count += lines[j].count + 1 }
                endIndex = min(count, raw.count)
                break
            }
            let parts = lines[i].split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                switch parts[0].lowercased() {
                case "title": title = parts[1]
                case "author": author = parts[1]
                case "language": language = parts[1]
                default: break
                }
            }
        }

        return (title, author, language, endIndex)
    }

    // MARK: - Parsing

    private func parseSections(_ text: String) -> [ExtractedSection] {
        let lines = text.components(separatedBy: "\n")
        let lineBlocks = groupIntoLineBlocks(lines)
        let classified: [(kind: BlockKind?, headingLevel: Int?, text: String)] = lineBlocks.map { classifyBlock($0, lines: lines) }

        var sections: [ExtractedSection] = []
        var currentBlocks: [ExtractedBlock] = []
        var currentHeading: String? = nil
        var sourceStart = 0
        var offset = 0

        for block in classified {
            let striped = stripInlineMarkup(block.text)
            let blockRange = offset..<(offset + block.text.count)
            offset += block.text.count + 2

            if block.kind == .heading && (block.headingLevel == 1 || block.headingLevel == 2) {
                if !currentBlocks.isEmpty {
                    sections.append(ExtractedSection(heading: currentHeading, blocks: currentBlocks, sourceStart: sourceStart))
                    currentBlocks = []
                }
                currentHeading = striped
                sourceStart = blockRange.lowerBound
                currentBlocks.append(ExtractedBlock(
                    kind: .heading, text: striped,
                    sourceRange: blockRange,
                    headingLevel: block.headingLevel
                ))
                continue
            }

            let kind = block.kind ?? .paragraph
            if kind == .sceneBreak {
                currentBlocks.append(ExtractedBlock(kind: .sceneBreak, text: "", sourceRange: blockRange))
            } else {
                currentBlocks.append(ExtractedBlock(
                    kind: kind, text: striped,
                    sourceRange: blockRange,
                    headingLevel: block.headingLevel
                ))
            }
        }

        if !currentBlocks.isEmpty {
            sections.append(ExtractedSection(heading: currentHeading, blocks: currentBlocks, sourceStart: sourceStart))
        }

        return sections.isEmpty ? [ExtractedSection(blocks: [], sourceStart: 0)] : sections
    }

    private func groupIntoLineBlocks(_ lines: [String]) -> [[String]] {
        var blocks: [[String]] = []
        var currentBlock: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !currentBlock.isEmpty {
                    blocks.append(currentBlock)
                    currentBlock = []
                }
            } else {
                currentBlock.append(line)
            }
        }
        if !currentBlock.isEmpty {
            blocks.append(currentBlock)
        }
        return blocks
    }

    private func classifyBlock(_ lines: [String], lines allLines: [String]) -> (kind: BlockKind?, headingLevel: Int?, text: String) {
        let joined = lines.joined(separator: "\n")
        let trimmed = joined.trimmingCharacters(in: .whitespaces)

        if let h = atxHeading(trimmed) {
            return (.heading, h.level, h.text)
        }

        if let h = setextHeading(joined, followingLines: Array(allLines.dropFirst(allLines.firstIndex(of: lines[0]) ?? 0 + lines.count))) {
            return (.heading, h.level, h.text)
        }

        let lineOne = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        if lineOne == "***" || lineOne == "---" || lineOne == "___" || lineOne == "* * *" {
            return (.sceneBreak, nil, "")
        }

        if lineOne.hasPrefix("```") || lineOne.hasPrefix("~~~") {
            return (nil, nil, "")
        }

        if lineOne.hasPrefix(">") {
            let text = lines.map { $0.hasPrefix(">") ? String($0.dropFirst()).trimmingCharacters(in: .whitespaces) : $0 }.joined(separator: " ")
            return (.blockquote, nil, text)
        }

        if lineOne.hasPrefix("- ") || lineOne.hasPrefix("* ") || lineOne.hasPrefix("+ ") {
            let text = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return (.listItem, nil, text)
        }

        if let match = lineOne.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            let text = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return (.listItem, nil, text)
        }

        return (.paragraph, nil, trimmed)
    }

    private func atxHeading(_ line: String) -> (level: Int, text: String)? {
        guard let match = line.range(of: #"^#{1,6}\s"#, options: .regularExpression) else { return nil }
        let headingText = line[match.upperBound...].trimmingCharacters(in: .whitespaces)
        let level = line.distance(from: line.startIndex, to: line.firstIndex(of: " ") ?? line.startIndex)
        return (min(level, 6), headingText)
    }

    private func setextHeading(_ line: String, followingLines: [String]) -> (level: Int, text: String)? {
        guard let next = followingLines.first else { return nil }
        let trimmed = next.trimmingCharacters(in: .whitespaces)
        if trimmed.allSatisfy({ $0 == "=" }) && !trimmed.isEmpty {
            return (1, line.trimmingCharacters(in: .whitespaces))
        }
        if trimmed.allSatisfy({ $0 == "-" }) && !trimmed.isEmpty && trimmed.count >= 2 {
            return (2, line.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private func stripInlineMarkup(_ s: String) -> String {
        var result = s
        result = result.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\b__(.+?)__\\b", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\*(.+?)\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\b_(.+?)_\\b", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\[(.+?)\\]\\(.+?\\)", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "!\\[(.+?)\\]\\(.+?\\)", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "~~~?[\\s\\S]*?~~~?", with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }

    private func collectWarnings(_ sections: [ExtractedSection], input: String) -> [ImportWarning] {
        var warnings: [ImportWarning] = []
        var idx = 0
        for section in sections {
            for block in section.blocks {
                if block.kind == .sceneBreak {
                    warnings.append(ImportWarning(kind: .skippedNonProse, message: "Thematic break", paragraphIndex: idx))
                }
                if block.kind == .paragraph && block.text.isEmpty {
                    warnings.append(ImportWarning(kind: .imageOnlyContent, message: "Image dropped", paragraphIndex: idx))
                }
                idx += 1
            }
        }
        return warnings
    }
}
