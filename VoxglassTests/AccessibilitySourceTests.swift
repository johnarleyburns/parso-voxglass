import Foundation
import Testing

@Suite struct AccessibilitySourceTests {
    private struct SourceFile {
        let path: String
        let text: String
    }

    @Test func sharedPhoneSemanticsStayWired() throws {
        let root = repositoryRoot()
        let requiredSnippets = [
            ("Voxglass/DesignSystem/VoxglassComponents.swift", ".accessibilityAddTraits(.isHeader)"),
            ("Voxglass/App/RootView.swift", ".accessibilityAction(.magicTap)"),
            ("Voxglass/Features/Chrome/MiniPlayerAccessory.swift", ".accessibilityElement(children: .combine)"),
            ("Voxglass/Features/Player/BookPageActionRow.swift", ".accessibilityAdjustableAction"),
            ("Voxglass/Features/Player/ScrubberView.swift", ".accessibilityAdjustableAction")
        ]
        for (file, snippet) in requiredSnippets {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            #expect(source.contains(snippet), "Missing accessibility contract \(snippet) in \(file)")
        }
    }

    @Test func iconOnlyButtonsHaveAccessibilityLabels() throws {
        let directories = [
            repositoryRoot().appendingPathComponent("Voxglass/Features"),
            repositoryRoot().appendingPathComponent("Voxglass/DesignSystem"),
            repositoryRoot().appendingPathComponent("VoxglassWatch")
        ]
        let violations = directories.flatMap { sourceFiles(in: $0) }.flatMap(iconOnlyButtonViolations)
        #expect(violations.isEmpty, "Icon-only buttons without accessibility labels: \(violations)")
    }

    @Test func watchControlsHaveLabelsAndIdentifiers() throws {
        let source = sourceFiles(in: repositoryRoot().appendingPathComponent("VoxglassWatch"))
            .map(\.text)
            .joined(separator: "\n")
        #expect(source.contains("Previous chapter"))
        #expect(source.contains("Next chapter"))
        #expect(source.contains("watch.book.play"))
        #expect(source.contains("accessibilityLabel"))
        #expect(source.contains("accessibilityAdjustableAction"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceFiles(in directory: URL) -> [SourceFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return SourceFile(path: url.path, text: text)
        }
    }

    private func iconOnlyButtonViolations(_ file: SourceFile) -> [String] {
        var violations: [String] = []
        var searchStart = file.text.startIndex
        while let match = file.text.range(of: "Button", range: searchStart..<file.text.endIndex) {
            let before = match.lowerBound > file.text.startIndex ? file.text[file.text.index(before: match.lowerBound)] : " "
            let after = match.upperBound < file.text.endIndex ? file.text[match.upperBound] : " "
            guard !before.isLetter && !after.isLetter else {
                searchStart = match.upperBound
                continue
            }

            let opening = labelOpening(in: file.text, after: match.upperBound)
            guard let opening, let closing = matchingBrace(in: file.text, opening: opening) else {
                searchStart = match.upperBound
                continue
            }
            let body = String(file.text[file.text.index(after: opening)..<closing])
            if body.contains("Image(systemName:") && !body.contains("Text(") && !body.contains("Label(") {
                let lineStart = file.text[..<match.lowerBound].lastIndex(of: "\n").map { file.text.index(after: $0) } ?? file.text.startIndex
                let lineEnd = file.text[match.upperBound...].firstIndex(of: "\n") ?? file.text.endIndex
                let declarationLine = String(file.text[lineStart..<lineEnd])
                if !declarationLine.contains("a11y-exempt:") {
                    let afterBody = String(file.text[closing...])
                    let firstLines = afterBody.split(separator: "\n", omittingEmptySubsequences: false).prefix(16).joined(separator: "\n")
                    if !firstLines.contains(".accessibilityLabel(") {
                        let line = file.text[..<match.lowerBound].reduce(into: 1) { count, character in
                            if character == "\n" { count += 1 }
                        }
                        violations.append("\(file.path):\(line)")
                    }
                }
            }
            searchStart = closing
        }
        return violations
    }

    private func labelOpening(in source: String, after buttonEnd: String.Index) -> String.Index? {
        let distance = source.distance(from: buttonEnd, to: source.endIndex)
        let lookaheadEnd = source.index(buttonEnd, offsetBy: min(600, distance))
        let lookahead = source[buttonEnd..<lookaheadEnd]
        if let label = lookahead.range(of: "label:"),
           let brace = source[label.upperBound..<lookaheadEnd].firstIndex(of: "{") {
            return brace
        }
        return source[buttonEnd..<lookaheadEnd].firstIndex(of: "{")
    }

    private func matchingBrace(in source: String, opening: String.Index) -> String.Index? {
        var depth = 0
        var index = opening
        var inString = false
        var escaped = false
        while index < source.endIndex {
            let character = source[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
