import Foundation

public struct TXTImporter: SourceImporting {
    public let format: SourceFormat = .txt

    public init() {}

    public func canImport(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "txt" || ext == "text"
    }

    public func extract(from url: URL) async throws -> ExtractedDocument {
        let rawData = try Data(contentsOf: url)
        let (text, encodingWarnings) = decodeText(rawData)

        let normalizedText = normalizeLineEndings(text)
        let (sections, segmentWarnings) = segment(text: normalizedText)

        let allWarnings = encodingWarnings + segmentWarnings

        return ExtractedDocument(
            sections: sections,
            title: url.deletingPathExtension().lastPathComponent,
            warnings: allWarnings,
            plainText: plainText(from: sections)
        )
    }

    // MARK: - Private

    private func plainText(from sections: [ExtractedSection]) -> String {
        sections.flatMap(\.blocks).map(\.text).joined(separator: "\n\n")
    }

    private func decodeText(_ data: Data) -> (String, [ImportWarning]) {
        if let text = String(data: data, encoding: .utf8) {
            return (text, [])
        }

        let bom16BE: [UInt8] = [0xFE, 0xFF]
        let bom16LE: [UInt8] = [0xFF, 0xFE]
        var warnings: [ImportWarning] = []

        if data.count >= 2 {
            let prefix = [data[0], data[1]]
            if prefix == bom16BE {
                if let text = String(data: data, encoding: .utf16BigEndian) {
                    warnings.append(ImportWarning(kind: .encodingFallback, message: "File decoded as UTF-16 BE; not UTF-8"))
                    return (text, warnings)
                }
            } else if prefix == bom16LE {
                if let text = String(data: data, encoding: .utf16LittleEndian) {
                    warnings.append(ImportWarning(kind: .encodingFallback, message: "File decoded as UTF-16 LE; not UTF-8"))
                    return (text, warnings)
                }
            }
        }

        if let text = String(data: data, encoding: .windowsCP1252) {
            warnings.append(ImportWarning(kind: .encodingFallback, message: "File decoded as Windows-1252; not UTF-8"))
            return (text, warnings)
        }

        if let text = String(data: data, encoding: .isoLatin1) {
            warnings.append(ImportWarning(kind: .encodingFallback, message: "File decoded as ISO-8859-1; not UTF-8"))
            return (text, warnings)
        }

        warnings.append(ImportWarning(kind: .encodingFallback, message: "Failed to detect encoding; using lossy UTF-8"))
        return (String(decoding: data, as: UTF8.self), warnings)
    }

    private func normalizeLineEndings(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private func segment(text: String) -> (sections: [ExtractedSection], warnings: [ImportWarning]) {
        let (blocks, isVerse) = splitIntoBlocks(text: text)
        let (classifiedBlocks, blockWarnings) = classifyBlocks(blocks, isVerse: isVerse)

        let section = ExtractedSection(blocks: classifiedBlocks, sourceStart: 0)
        return ([section], blockWarnings)
    }

    private func splitIntoBlocks(text: String) -> (blocks: [String], isVerse: Bool) {
        let paragraphs = text.components(separatedBy: "\n")
        let isVerse = detectVerse(paragraphs)

        var blocks: [String] = []
        var currentBlock: [String] = []

        for line in paragraphs {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !currentBlock.isEmpty {
                    if isVerse {
                        blocks.append(contentsOf: currentBlock)
                    } else {
                        blocks.append(currentBlock.joined(separator: " "))
                    }
                    currentBlock = []
                }
            } else {
                currentBlock.append(line)
            }
        }
        if !currentBlock.isEmpty {
            if isVerse {
                blocks.append(contentsOf: currentBlock)
            } else {
                blocks.append(currentBlock.joined(separator: " "))
            }
        }

        return (blocks, isVerse)
    }

    private func detectVerse(_ paragraphs: [String]) -> Bool {
        let nonEmpty = paragraphs.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard nonEmpty.count > 10 else { return false }
        let shortLines = nonEmpty.filter { $0.count < 60 }
        guard Double(shortLines.count) / Double(nonEmpty.count) > 0.30 else { return false }

        var consecutiveCount = 0
        var maxConsecutive = 0
        for line in paragraphs {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                consecutiveCount = 0
            } else {
                consecutiveCount += 1
                maxConsecutive = max(maxConsecutive, consecutiveCount)
            }
        }
        return maxConsecutive <= 2
    }

    private func classifyBlocks(_ blocks: [String], isVerse: Bool) -> ([ExtractedBlock], [ImportWarning]) {
        var warnings: [ImportWarning] = []
        var extracted: [ExtractedBlock] = []

        let headingPattern = #"^\s*(CHAPTER|BOOK|PART|SECTION|PROLOGUE|EPILOGUE|ACT|SCENE|CANTO)\b"#
        let sceneBreakPattern = #"^\s*([*#•~—-]\s*){3,}\s*$"#

        var offset = 0
        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespaces)
            let range = offset..<(offset + block.count)
            offset += block.count + 2

            if trimmed.range(of: sceneBreakPattern, options: .regularExpression) != nil {
                extracted.append(ExtractedBlock(kind: .sceneBreak, text: "", sourceRange: range))
                warnings.append(ImportWarning(kind: .possibleSceneBreak, message: "Scene break detected: \(trimmed)", paragraphIndex: extracted.count))
                continue
            }

            // §9.1: heading requires ≤ 80 characters, no terminal ./?/!,
            // and a CHAPTER/BOOK/… prefix.
            let hasTerminalPunctuation = trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!")
            if trimmed.count <= 80, !hasTerminalPunctuation,
               trimmed.range(of: headingPattern, options: [.regularExpression, .caseInsensitive]) != nil {
                extracted.append(ExtractedBlock(
                    kind: .heading, text: trimmed,
                    sourceRange: range, headingLevel: 1
                ))
                continue
            }

            // All-uppercase short line without terminal punctuation (spec §9.1).
            if isAllUppercase(trimmed) && trimmed.count > 2 && trimmed.count <= 80 && !hasTerminalPunctuation {
                extracted.append(ExtractedBlock(
                    kind: .heading, text: trimmed,
                    sourceRange: range, headingLevel: 1
                ))
                continue
            }

            extracted.append(ExtractedBlock(
                kind: isVerse ? .verse : .paragraph,
                text: trimmed,
                sourceRange: range
            ))
        }

        return (extracted, warnings)
    }

    private func isAllUppercase(_ s: String) -> Bool {
        let letters = s.filter { $0.isLetter }
        guard !letters.isEmpty else { return false }
        return letters.allSatisfy { $0.isUppercase }
    }

    private func range(of needle: String, in haystack: String) -> Range<Int> {
        guard let r = haystack.range(of: needle) else {
            return 0..<0
        }
        let start = haystack.distance(from: haystack.startIndex, to: r.lowerBound)
        let end = haystack.distance(from: haystack.startIndex, to: r.upperBound)
        return start..<end
    }
}
