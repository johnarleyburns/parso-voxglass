import Foundation
import Testing

@Suite struct AccessibilitySourceTests {
    @Test func sharedPhoneSemanticsStayWired() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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

    @Test func watchControlsHaveLabelsAndIdentifiers() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = try FileManager.default.enumerator(at: root.appendingPathComponent("VoxglassWatch"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        let source = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        #expect(source.contains("Previous chapter"))
        #expect(source.contains("Next chapter"))
        #expect(source.contains("watch.book.play"))
        #expect(source.contains("accessibilityLabel"))
    }
}
